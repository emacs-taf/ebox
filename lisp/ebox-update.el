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
(require 'ebox-elastic)
(require 'ebox-update-selector)

(cl-defstruct (ebox-update--member (:constructor ebox-update--make-member))
  group properties offsets variants input ref)

(defconst ebox-update--structural-state-keys
  '(:root-node :logical-candidate-p :layout-snapshots :layout-snapshots-complete-p
    :layout-snapshot-detail-generation :retained-allocation-certificates
    :display-signature :render-cache :layout-fragments :layout-fragments-reuse-p
    :detached-identity-history :render-signature-cache :flex-content-min-widths
    :viewport-height-dependent-subtree-cache :viewport-dependent-node-ids-ready
    :viewport-dependent-node-ids :viewport-dependent-node-id-axes :reflow-prewarm-scratch
    :scroll-region-ids :node-table :parent-table :region-id-set :region-node-table
    :region-box-count-table :region-box-table :range-ref-table :source-index
    :selector-id-table :selector-class-table :selector-type-table
    :runtime-type-count-table :selector-index-stale-p :native-node-postorder
    :native-node-postorder-ids)
  "State keys a prepared structural member replaces with its candidate values.")

(cl-defstruct (ebox-update--group (:constructor ebox-update--make-group))
  "One Host's prebound members.  DIRTY marks any changed member; REPAINT
marks a changed raster value, the only change that re-renders BOUNDARY."
  node properties variants first-member slots values geometry-program x-factor
  boundary style-p restyle resized repaint crop class-slot hover-cell hover-old hover-owners dirty staged dx dy z
  structural)

(cl-defstruct (ebox-update--boundary (:constructor ebox-update--make-boundary))
  "Nearest retained composition primitive owning a group's pixels.
NODE is rendered in HOST's content context with the ordinary renderer.  Its
pieces replace NODE's primitive records in ROUTE's program.  A flow child
must keep exactly the same source rows and pixel intervals; an absolute
panel does not participate in flow, so its complete footprint may change.
WIDTH and HEIGHT hold NODE's own size before the current application when
a member changed it; PAINT marks any other changed raster value."
  node host route dirty width height paint scroll-nodes scroll-sensitive elastic-scroll-safe)

(cl-defstruct (ebox-update--cohort (:constructor ebox-update--make-cohort))
  buffer state scene members groups boundaries marks epoch snapshots
  signatures viewport-nodes viewport-subtrees css-viewport-subtrees viewport-heights stage rollback after-commit report old-report old-revision old-stale
  old-report-revision old-report-publication old-report-kinds staged paint-changed
  structural structural-state)

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

(defun ebox-update--scene (buffer state nodes &optional resize-node fixed-portals-p admit)
  "Return BUFFER's shared scene admitting NODES, preferring RESIZE-NODE.
A requested fixed-content size binding prepares the crop primitive before
input; ordinary layout keeps its existing publication route.
FIXED-PORTALS-P records the content cohort's independent-portal proof.
ADMIT validates routes and crop before a cold scene allocates publication
storage, and also validates additional members of a reused scene."
  (or (with-current-buffer buffer
        ;; Try every live canvas before building one.  One mounted surface can
        ;; keep several disjoint retained panels; alternating between them must
        ;; not invalidate the other panels' prepared bindings.  A candidate
        ;; that cannot admit the members declines locally and the next one is
        ;; tried.
        (catch 'ebox-scene-admitted
          (dolist (candidate (ebox-geometry--valid-sessions))
            (when (catch 'unsupported
                    (when admit
                      (funcall admit (ebox-geometry--operation-routes candidate)
                               (ebox-geometry--operation-crop candidate)))
                    t)
              (setq ebox-geometry--session candidate)
              (throw 'ebox-scene-admitted candidate)))))
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
            (when-let* ((operation (ebox-geometry--prepare
                                   buffer reference
                                   (if resize-node [:left :top :width :height]
                                     [:left :top :z-index])
                                   nil nil nil fixed-portals-p admit)))
              (ebox-geometry--operation-session operation)))))))

(defun ebox-update--fixed-portal-protection (state)
  "Return the protected node IDs of STATE's fixed root portals.
Return `unsupported' when anchors or missing retained portal records prevent
proof.  Every portal, its descendants and its logical ancestors is protected;
only content in an independent branch may use the existing fixed canvas."
  (let* ((root (plist-get state :root-node))
         (parents (plist-get state :parent-table))
         (cache (plist-get state :layer-composition-cache))
         (entry (and (hash-table-p cache)
                     (gethash (cons (plist-get root :node-id) 'final) cache)))
         (protected (make-hash-table :test #'equal))
         (recorded (make-hash-table :test #'equal))
         visible-portals anchored)
    (dolist (record (plist-get entry :records))
      (puthash (plist-get (plist-get record :node) :node-id) t recorded))
    (cl-labels
        ((visit
          (node inside-portal visible)
          (let* ((id (plist-get node :node-id))
                 (portal (eq (plist-get node :layer) 'root))
                 (visible (and visible (not (eq (plist-get node :visibility) 'hidden)))))
            (when (plist-get node :anchor) (setq anchored t))
            (when (or inside-portal portal) (puthash id t protected))
            (when portal
              (when visible (push id visible-portals))
              (let ((ancestor (ebox-runtime-index-get id parents)))
                (while ancestor
                  (puthash ancestor t protected)
                  (setq ancestor (ebox-runtime-index-get ancestor parents)))))
            (dolist (child (ebox-tree-node-children node))
              (visit child (or inside-portal portal) visible)))))
      (visit root nil t))
    (if (or anchored (not (vectorp (plist-get entry :rows)))
            (cl-some (lambda (id) (not (gethash id recorded))) visible-portals))
        'unsupported
      protected)))

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
(defun ebox-update--scroll-nodes (node)
  "Collect NODE's potential scroll owners at the cold boundary.
Underfilled owners are included: a resize or content change may create their
first scroll state, and rendering may clamp their retained offset."
  (let (result)
    (cl-labels ((visit (node)
                  (when (eq (ebox-get node :overflow) 'scroll) (push node result))
                  (ebox-tree-for-each-direct-child node #'visit)))
      (visit node))
    result))

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
                        (let ((scroll-nodes (ebox-update--scroll-nodes node)))
                          (puthash node
                                   (ebox-update--make-boundary
                                    :node node :route index :scroll-nodes scroll-nodes
                                    :scroll-sensitive
                                    (and (cl-some (lambda (owner)
                                                    (gethash (plist-get owner :region-id)
                                                             (plist-get state :scroll-state-table)))
                                                  scroll-nodes)
                                         t)
                                    :host (ebox-runtime-index-get
                                           (plist-get (ebox-geometry--route-wrapper route) :node-id)
                                           nodes))
                                   table))))))
          (setq index (1+ index)))
        (unless found
          (setq node (ebox-runtime-index-get (ebox-runtime-index-get id parents) nodes)))))
    (and found (ebox-update--boundary-host found) found)))

(cl-defstruct (ebox-update--binding (:constructor ebox-update--make-binding))
  "Opaque cold capability for mounted state and its measurement environment."
  public-token buffer state stylesheet stylesheet-epoch font-epoch environment window width height
  portal-protection)

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
their declared variant configuration changes.  A fixed-canvas rejection can
also include :detail with :phase, :reason and bounded scalar facts about the
failed proof; it contains no retained objects or rendered text.  A stale
report requests a control-plane refresh and never authorizes the old operation."
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

(defun ebox-update--decline (reason &optional stale detail)
  "Reject cold preparation with REASON, optional STALE status and scalar DETAIL."
  (when (buffer-live-p ebox-update--preparing-buffer)
    (with-current-buffer ebox-update--preparing-buffer
      (setq ebox-update--prepare-report
            (list :status (if stale 'stale 'unsupported) :reason reason
                  :binding-token (and ebox-update--binding-token
                                      (ebox-update--binding-public-token ebox-update--binding-token))
                  :member ebox-update--preparing-member :property ebox-update--preparing-property))
      (when detail
        (setq ebox-update--prepare-report
              (plist-put ebox-update--prepare-report :detail detail)))))
  (throw 'unsupported nil))

;;;###autoload
(defun ebox-update-prepare (buffer-or-name specifications &optional stage rollback after-commit)
  "Compile BUFFER-OR-NAME's fixed SPECIFICATIONS into one primitive cohort.
A member is [HOST-REF PROPERTY-VECTOR] or [HOST-REF PROPERTY-VECTOR VARIANTS].
VARIANTS, when present, aligns with the properties; a class slot contains a
nonempty vector of finite canonical class token/list values.  Other slots use
nil.  Duplicate Hosts may declare disjoint properties.  A structural member
is [HOST-REF :children CANONICAL-INPUT].  It replaces that Host's subtree while
retaining every node and region identity, and applying it re-renders the
owner's composition boundary.  A replacement whose node or region identity set
differs from the published one is declined before any state changes.  STAGE
and ROLLBACK are paired zero-argument callbacks.  AFTER-COMMIT runs once after
acceptance.
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

(defun ebox-update--admit-groups (state members groups routes crop portal-protection)
  "Prove MEMBERS and GROUPS against STATE's ROUTES before scene allocation.
CROP is the selected fixed-content size primitive; PORTAL-PROTECTION guards
independent content.  Return the shared raster-boundary table.  Only local
group and proof records change; source, scene and publication stay untouched."
  (let ((boundaries (make-hash-table :test #'eq)))
    (dotimes (index (length groups))
      (let* ((group (aref groups index))
             (node (ebox-update--group-node group))
             (keys (vconcat (ebox-update--group-properties group)))
             (variants (vconcat (ebox-update--group-variants group)))
             (values (make-vector (length keys) nil))
             geometry raster)
        (when (and crop (eq node (aref crop 0)))
          (setf (ebox-update--group-crop group) crop))
        (setq ebox-update--preparing-member (ebox-update--group-first-member group)
              ebox-update--preparing-property nil)
        (when (ebox-update--group-structural group)
          (setq raster t))
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
            (when (and portal-protection
                       (gethash (plist-get (ebox-update--boundary-node boundary) :node-id)
                                portal-protection))
              (ebox-update--decline 'fixed-canvas nil '(:phase route :reason root-portals)))
            (setf (ebox-update--group-boundary group) boundary
                  (ebox-update--group-repaint group) t)))))
    boundaries))

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
           (members (make-vector (length specifications) nil))
           (portal-protection
            (and (plist-get state :root-portals-p)
                 (or (ebox-update--binding-portal-protection ebox-update--binding-token)
                     (setf (ebox-update--binding-portal-protection ebox-update--binding-token)
                           (ebox-update--fixed-portal-protection state)))))
           groups nodes scene admitted-boundaries structural-members structural-snapshots)
      (unless state (ebox-update--decline 'unmounted t))
      (when (eq portal-protection 'unsupported)
        (ebox-update--decline 'fixed-canvas nil '(:phase route :reason root-portals)))
      (unless (equal (plist-get state :display-signature)
                     (append (ebox-geometry--operation-display-snapshot
                              (ebox-update--binding-environment ebox-update--binding-token)) nil))
        (ebox-update--decline 'display-context t))
      (dotimes (index (length specifications))
        (setq ebox-update--preparing-member index ebox-update--preparing-property nil)
        (let* ((spec (aref specifications index))
               (children-p (and (vectorp spec) (= (length spec) 3)
                                (eq (aref spec 1) :children))))
          (if children-p
              (let* ((ref (aref spec 0))
                     (input (aref spec 2))
                     (node (ebox-update--node buffer ref)))
                (unless (ebox-canonical-input-p input)
                  (user-error "Prepared Ebox children members require a canonical input"))
                (unless node (ebox-update--decline 'missing-host t))
                (when (gethash node groups-table)
                  (user-error "Prepared Ebox cohort members overlap for one Host"))
                (let ((group (ebox-update--make-group :node node :first-member index
                                                      :properties '(:children)
                                                      :structural t)))
                  (puthash node group groups-table)
                  (push group groups) (push node nodes)
                  (aset members index (ebox-update--make-member
                                       :group group :properties [:children]
                                       :input input :ref ref))
                  (push (aref members index) structural-members)))
            (let* ((node (and (vectorp spec) (memq (length spec) '(2 3))
                              (ebox-update--node buffer (aref spec 0))))
                   (keys (and (vectorp spec) (memq (length spec) '(2 3)) (aref spec 1)))
                   (variants (and (vectorp spec) (= (length spec) 3) (aref spec 2))))
          (unless (and (vectorp keys) (> (length keys) 0))
            (user-error "Prepared Ebox members require a Host and property vector"))
          (unless (or (null variants) (and (vectorp variants) (= (length variants) (length keys))))
            (user-error "Prepared member variants must align with its property vector"))
          (unless node (ebox-update--decline 'missing-host t))
          (setq keys (vconcat (mapcar (lambda (key) (if (eq key :bgcolor) :background-color key)) (append keys nil))))
          (when (and portal-protection
                     (or (not (equal keys [:content]))
                         (gethash (plist-get node :node-id) portal-protection)))
            (ebox-update--decline 'fixed-canvas nil '(:phase route :reason root-portals)))
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
            (aset members index (ebox-update--make-member :group group :properties (copy-sequence keys) :variants (and variants (copy-tree variants t)))))))))
      (setq ebox-update--preparing-member nil ebox-update--preparing-property nil)
      (when structural-members
        (setq structural-members (nreverse structural-members))
        (let* ((candidate (ebox-incremental-candidate-begin buffer))
               (prepared-input
                (progn
                  (dolist (member structural-members)
                    (let* ((input (ebox-update--member-input member))
                           (ebox-incremental--source-base-index
                            (ebox-canonical-input--source-index input)))
                      (ebox-incremental-candidate-replace-host-ref
                       candidate (ebox-update--member-ref member)
                       (ebox-canonical-input--single-root
                        input "ebox-update-children"))))
                  (ebox-incremental--prepare-logical-candidate
                   buffer state candidate)))
               (candidate-state
                (ebox-incremental--candidate-state
                 state (plist-get prepared-input :root)
                 (plist-get prepared-input :index) prepared-input)))
          ;; The prepared publication reuses the published object and mount
          ;; context, so the replacement must retain every node and region
          ;; identity.  A new region has no retained mount object and belongs
          ;; to the ordinary projection path instead.
          (unless (and (ebox-incremental--hash-key-set-equal-p
                        (plist-get state :node-table)
                        (plist-get candidate-state :node-table))
                       (ebox-incremental--hash-key-set-equal-p
                        (plist-get state :region-id-set)
                        (plist-get candidate-state :region-id-set)))
            (ebox-update--decline 'structural-topology))
          (setq structural-snapshots candidate-state)))
      (let ((ebox-geometry--admission-detail (list nil)))
        (setq groups (vconcat (nreverse groups))
              scene (ebox-update--scene
                     buffer state nodes
                     (cl-loop for group across groups
                              when (and (cl-intersection (ebox-update--group-properties group)
                                                         '(:width :height))
                                        (ebox-geometry--crop-candidate-p (ebox-update--group-node group)))
                              return (ebox-update--group-node group))
                     (and portal-protection t)
                     (lambda (routes crop)
                       (setq admitted-boundaries
                             (ebox-update--admit-groups
                              state members groups routes crop portal-protection))
                       ;; Later scene failures belong to the canvas, rather
                       ;; than the last member whose proof succeeded.
                       (setq ebox-update--preparing-member nil
                             ebox-update--preparing-property nil))))
        (unless scene
          (ebox-update--decline 'fixed-canvas nil
                                (or (car ebox-geometry--admission-detail)
                                    '(:phase geometry :reason positioned-host)))))
      (let ((boundaries admitted-boundaries))
        ;; All output proofs precede the equivalent private source rebinding.
        (dotimes (index (length groups))
          (let* ((group (aref groups index))
                 (node (ebox-update--group-node group)))
            (unless (ebox-update--group-structural group)
              (let ((_diagnostic (ebox-update--locate-member members group))
                    (slots (ebox-source--update-slots-prepare
                            (plist-get state :source-index) node
                            (ebox-update--group-properties group))))
                (unless slots (ebox-update--decline 'source-binding))
                (setf (ebox-update--group-slots group) slots)
                (plist-put node :ebox-source-handle (ebox-source--update-slots-handle slots))
                (plist-put state :source-index (ebox-source--update-slots-index slots))))))
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
        (let* ((memos
                (or (ebox-geometry--operation-render-memos scene)
                    (setf (ebox-geometry--operation-render-memos scene)
                          (vector (make-hash-table :test #'eq)
                                  (make-hash-table :test #'eq)
                                  (make-hash-table :test #'eq)
                                  (make-hash-table :test #'eq)
                                  (make-hash-table :test #'eq)))))
               (operation
               (ebox-update--make-cohort
                :buffer buffer :state state :scene scene :members members :groups groups
                :boundaries (let (all)
                              (maphash (lambda (_node boundary) (push boundary all)) boundaries)
                              (vconcat all))
                :marks (make-vector (length members) 0) :epoch 0
                :structural-state structural-snapshots
                ;; These facts describe shared scene nodes.  Independent
                ;; invocation cohorts must observe each other's invalidations.
                :signatures (aref memos 0)
                :viewport-nodes (aref memos 1)
                :viewport-subtrees (aref memos 2)
                :css-viewport-subtrees (aref memos 3)
                :viewport-heights (aref memos 4)
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
             (unless (or (ebox-update--group-structural group)
                         (ebox-source--update-slots-current-p
                          (ebox-update--group-slots group) index))
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
     ((eq property :children) nil)
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
  "Drop shared render facts along OPERATION's changed ancestor paths."
  (let* ((scene (ebox-update--cohort-scene operation))
         (groups (ebox-update--cohort-groups operation))
         (changed (mapcar #'car (ebox-update--cohort-snapshots operation))))
    (dotimes (index (length groups))
      (when (ebox-update--group-dirty (aref groups index))
        (push (ebox-update--group-node (aref groups index)) changed)))
    (dolist (node changed)
      (ebox-geometry--forget-render-memos scene node))))

(defun ebox-update--render-boundary (operation boundary &optional probe)
  "Render BOUNDARY's node in its host context from OPERATION's current nodes.
PROBE renders with private caches so a trial size leaves no memoized facts."
  (let* ((state (ebox-update--cohort-state operation))
         (scene (ebox-update--cohort-scene operation))
         (ebox-viewport-width (plist-get state :viewport-width))
         (ebox-viewport-height (plist-get state :viewport-height))
         (ebox--render-display-signature (plist-get state :display-signature))
         (ebox--render-source-index (plist-get state :source-index))
         (ebox--region-box-table (ebox-geometry--operation-region-table scene))
         (ebox--scroll-global-state
          (if probe
              (let ((table (make-hash-table :test #'equal)))
                (maphash (lambda (region scroll) (puthash region (copy-sequence scroll) table))
                         (ebox-geometry--operation-scroll-table scene))
                table)
            (ebox-geometry--operation-scroll-table scene)))
         (scroll-snapshots (and probe
                                (mapcar (lambda (owner) (cons owner (copy-sequence owner)))
                                        (ebox-update--boundary-scroll-nodes boundary))))
         (ebox--scroll-idle-prefetch-timers (ebox-geometry--operation-scroll-timers scene))
         (ebox--render-runtime-revision (plist-get state :runtime-revision))
         (ebox--render-cache-table (if probe (make-hash-table :test #'equal)
                                     (plist-get state :render-cache)))
         (ebox--render-cache-allow-viewport-dependent t)
         (ebox--render-cache-signature-cache (if probe (make-hash-table :test #'eq)
                                               (ebox-update--cohort-signatures operation)))
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
    (unwind-protect
        (unless (eq (plist-get node :visibility) 'hidden)
          (prog1
              (cl-letf (((symbol-function 'ebox--scroll-schedule-idle-prefetch) #'ignore))
                (ebox--call-with-box-content-context
                 (ebox-update--boundary-host boundary)
                 (lambda () (ebox--render-with-cache node))))
            (when (cl-some (lambda (owner)
                             (gethash (plist-get owner :region-id) ebox--scroll-global-state))
                           (ebox-update--boundary-scroll-nodes boundary))
              (setf (ebox-update--boundary-scroll-sensitive boundary) t
                    (ebox-update--boundary-elastic-scroll-safe boundary) nil))))
      (dolist (entry scroll-snapshots)
        (ebox-update--restore-node (car entry) (cdr entry))))))

(defun ebox-update--elastic-change (boundary)
  "Return (OLD-WIDTH OLD-HEIGHT WIDTH HEIGHT) when BOUNDARY only changed size.
Sizes are the node's pixel width and row height.  Return nil when another
raster value changed, the node is not an absolute panel or its size is not
expressed in whole pixels and rows."
  (let* ((node (ebox-update--boundary-node boundary))
         (width (ebox-get node :width)) (height (ebox-get node :height))
         (old-width (or (ebox-update--boundary-width boundary) (car-safe (cdr-safe width))))
         (old-height (or (ebox-update--boundary-height boundary) (car-safe (cdr-safe height)))))
    (and (not (ebox-update--boundary-paint boundary))
         ;; Active scroll viewport metadata requires ordinary rendering.
         (not (ebox-update--boundary-scroll-sensitive boundary))
         (eq (plist-get node :position) 'absolute)
         (eq (car-safe width) 'px) (eq (car-safe height) 'lh)
         (integerp (car-safe (cdr-safe width))) (integerp (car-safe (cdr-safe height)))
         (integerp old-width) (integerp old-height)
         (or (/= old-width (cadr width)) (/= old-height (cadr height)))
         (list old-width old-height (cadr width) (cadr height)))))

(defun ebox-update--boundary-rows (records target)
  "Return the rows RECORDS retain for TARGET in source order, or nil.
Every row from the first to the last must have a placed primitive."
  (let (rows)
    (dotimes (position (length target))
      (let ((record (aref records (aref target position))))
        (when (>= (plist-get record :y) 0)
          (let ((row (plist-get record :source-row)))
            (unless (assq row rows) (push (cons row (plist-get record :text)) rows))))))
    (setq rows (sort rows (lambda (a b) (< (car a) (car b)))))
    (and rows (= (car (car rows)) 0)
         (cl-loop for (row . _) in rows for index from 0 always (= row index))
         (mapcar #'cdr rows))))

(defun ebox-update--elastic-lines (operation boundary change rows)
  "Return BOUNDARY's rows after size CHANGE replayed from the learned model.
ROWS are the currently retained rows.  Return nil when no verified model
covers the change."
  (pcase-let* ((`(,old-width ,old-height ,width ,height) change)
               (node (ebox-update--boundary-node boundary))
               (model (ebox-elastic--model
                       node (plist-get (ebox-update--cohort-state operation) :display-signature))))
    (and model
         (or (null (ebox-update--boundary-scroll-nodes boundary))
             (ebox-update--boundary-elastic-scroll-safe boundary))
         (ebox-elastic--in-range-p model width height)
         (ebox-elastic--matches-p model rows old-width old-height)
         (ebox-elastic--synthesize model rows old-height width height))))

(defun ebox-update--elastic-probe (operation boundary width height)
  "Render BOUNDARY's node at a trial WIDTH by HEIGHT and return its rows."
  (let* ((node (ebox-update--boundary-node boundary))
         (width-cell (ebox-get node :width)) (height-cell (ebox-get node :height))
         (saved-width (cadr width-cell)) (saved-height (cadr height-cell)))
    (unwind-protect
        (progn
          (setcar (cdr width-cell) width) (setcar (cdr height-cell) height)
          (let ((text (ebox-update--render-boundary operation boundary t)))
            (and (stringp text) (ebox-string-lines text))))
      (setcar (cdr width-cell) saved-width) (setcar (cdr height-cell) saved-height))))

(defun ebox-update--elastic-verified-p (operation boundary model rows height trial-width trial-height)
  "Whether MODEL predicts the render of BOUNDARY at TRIAL-WIDTH by TRIAL-HEIGHT.
ROWS are HEIGHT rows that MODEL matches."
  (let ((expected (ebox-elastic--synthesize model rows height trial-width trial-height))
        (actual (ebox-update--elastic-probe operation boundary trial-width trial-height)))
    (and expected actual (= (length expected) (length actual))
         (cl-every #'ebox-elastic--rows-equal-p expected actual))))

(defun ebox-update--elastic-limit (node property unit fallback)
  "Return NODE's PROPERTY size in UNIT as an integer, else FALLBACK."
  (let ((value (ebox-get node property)))
    (if (and (eq (car-safe value) unit) (integerp (car-safe (cdr-safe value))))
        (cadr value)
      fallback)))

(defun ebox-update--elastic-width-bound (operation boundary model rows width height trial)
  "Return TRIAL when MODEL predicts BOUNDARY's render at TRIAL width, else WIDTH.
ROWS are the HEIGHT rows rendered at WIDTH.  A trial whose odd total first
reveals which run owns the odd pixel completes MODEL's shapes in place."
  (let ((actual (ebox-update--elastic-probe operation boundary trial height))
        (shapes (ebox-elastic--model-rows model)))
    (if (not (and actual (= (length actual) (length rows))))
        width
      (when (cl-some (lambda (shape) (and (cdr (ebox-elastic--row-runs shape))
                                          (null (ebox-elastic--row-ceil shape))))
                     shapes)
        (let ((refined (ebox-elastic--learn-width rows width actual trial)))
          (when refined
            (dotimes (index (length shapes))
              (when (and (cdr (ebox-elastic--row-runs (aref shapes index)))
                         (null (ebox-elastic--row-ceil (aref shapes index))))
                (setf (ebox-elastic--row-ceil (aref shapes index))
                      (ebox-elastic--row-ceil (aref refined index))))))))
      (let ((expected (ebox-elastic--synthesize model rows height trial height)))
        (if (and expected (cl-every #'ebox-elastic--rows-equal-p expected actual)) trial width)))))

(defun ebox-update--elastic-learn-width (operation boundary model rows-a width-a rows-b width-b height program)
  "Extend MODEL with the width response between ROWS-A and ROWS-B.
ROWS-A and ROWS-B are the renders at WIDTH-A and WIDTH-B, both HEIGHT rows
tall; MODEL may be nil.  Return the model with a verified width range, or
nil when the rows do not respond elastically."
  (let ((shapes (ebox-elastic--learn-width rows-b width-b rows-a width-a)))
    (when shapes
      (let* ((node (ebox-update--boundary-node boundary))
             ;; The old height response only describes rows it still matches.
             (reindexed (and model
                             (ebox-elastic--matches-p model rows-a width-a height)
                             (ebox-elastic--reindex model height)))
             (new (ebox-elastic--make-model
                   :rows shapes :wref width-b
                   :prefix (and reindexed (ebox-elastic--model-prefix model))
                   :suffix (and reindexed (ebox-elastic--model-suffix model))
                   :filler (and reindexed (ebox-elastic--model-filler model))
                   :shifts (and reindexed (cdr reindexed))
                   :filler-shifts (and reindexed (ebox-elastic--model-filler-shifts model))
                   :hlow (if reindexed (ebox-elastic--model-hlow model) height)
                   :hhigh (if reindexed (ebox-elastic--model-hhigh model) height)))
             (low (min width-a width-b)) (high (max width-a width-b))
             (floor (max (ebox-elastic--width-floor new)
                         (ebox-update--elastic-limit node :min-width 'px 0)))
             (ceiling (ebox-update--elastic-limit node :max-width 'px (ebox-layer--program-width program))))
        (setf (ebox-elastic--model-whigh new)
              (if (> ceiling high)
                  (max high (ebox-update--elastic-width-bound operation boundary new rows-b width-b height ceiling))
                high))
        (setf (ebox-elastic--model-wlow new)
              (if (< floor low)
                  (min low (ebox-update--elastic-width-bound operation boundary new rows-b width-b height floor))
                low))
        new))))

(defun ebox-update--elastic-learn-height (operation boundary model rows-a height-a rows-b height-b width program)
  "Extend MODEL with the height response between ROWS-A and ROWS-B.
ROWS-A and ROWS-B are the renders at HEIGHT-A and HEIGHT-B rows, both WIDTH
wide; MODEL may be nil.  Return the model with a verified height range, or
nil when the rows do not grow by repeated filler rows."
  (let ((response (ebox-elastic--learn-height rows-a rows-b)))
    (when response
      (pcase-let* ((`(,prefix ,suffix ,filler ,shifts ,filler-shifts) response)
                   (short (if (<= height-a height-b) rows-a rows-b))
                   (height (length short))
                   (node (ebox-update--boundary-node boundary))
                   (reindexed (and model (ebox-elastic--reindex model height)))
                   (widths (and reindexed
                                (ebox-elastic--matches-p
                                 (ebox-elastic--make-model :rows (car reindexed)
                                                           :wref (ebox-elastic--model-wref model))
                                 short width height)))
                   (new (ebox-elastic--make-model
                         :rows (if widths (car reindexed) (vconcat (mapcar #'ebox-elastic--fixed-row short)))
                         :wref (if widths (ebox-elastic--model-wref model) width)
                         :prefix prefix :suffix suffix :filler filler
                         :shifts shifts :filler-shifts filler-shifts
                         :wlow (if widths (ebox-elastic--model-wlow model) width)
                         :whigh (if widths (ebox-elastic--model-whigh model) width)))
                   (low (min height-a height-b)) (high (max height-a height-b))
                   (floor (max (+ prefix suffix) (ebox-update--elastic-limit node :min-height 'lh 0)))
                   (ceiling (ebox-update--elastic-limit node :max-height 'lh (ebox-layer--program-height program))))
        (setf (ebox-elastic--model-hlow new)
              (if (and (< floor low)
                       (ebox-update--elastic-verified-p operation boundary new rows-b height-b width floor))
                  floor low))
        (setf (ebox-elastic--model-hhigh new)
              (if (and (> ceiling high)
                       (ebox-update--elastic-verified-p operation boundary new rows-b height-b width ceiling))
                  ceiling high))
        new))))

(defun ebox-update--elastic-learn (operation boundary change rows lines program)
  "Learn BOUNDARY's size response from the render LINES after CHANGE.
ROWS are the rows retained before the change.  A change of one axis is
learned directly; a change of both axes is learned through the model's
replay of the already known axis."
  (pcase-let* ((`(,old-width ,old-height ,width ,height) change)
               (node (ebox-update--boundary-node boundary))
               (signature (plist-get (ebox-update--cohort-state operation) :display-signature))
               (model (and (or (null (ebox-update--boundary-scroll-nodes boundary))
                               (ebox-update--boundary-elastic-scroll-safe boundary))
                           (ebox-elastic--model node signature)))
               (result nil))
    ;; Min/max constraints, content-box decoration and clipping can make
    ;; declared heights differ from materialized rows.  The model indexes
    ;; complete rows by those heights, so neither sample proves a response
    ;; unless the declared and rendered extents agree.  Keep the ordinary
    ;; render in that case; there is no learned response to replay.
    (when (and lines (= (length rows) old-height) (= (length lines) height)
               (cl-every (lambda (line) (> (length line) 0)) lines))
      (cond
       ((= old-height height)
        (when (= (length rows) (length lines))
          (setq result (ebox-update--elastic-learn-width
                        operation boundary model rows old-width lines width height program))))
       ((= old-width width)
        (setq result (ebox-update--elastic-learn-height
                      operation boundary model rows old-height lines height width program)))
       ((and model (ebox-elastic--matches-p model rows old-width old-height))
        (let ((across (and (ebox-elastic--in-range-p model width old-height)
                           (ebox-elastic--synthesize model rows old-height width old-height)))
              (down (and (ebox-elastic--in-range-p model old-width height)
                         (ebox-elastic--synthesize model rows old-height old-width height))))
          (cond
           (across (setq result (ebox-update--elastic-learn-height
                                 operation boundary model across old-height lines height width program)))
           ((and down (= (length down) (length lines)))
            (setq result (ebox-update--elastic-learn-width
                          operation boundary model down old-width lines width height program)))))))
      (when (and result (not (ebox-update--boundary-scroll-sensitive boundary)))
        ;; All renderer trials for this learned range remained underfilled.
        ;; A previously remembered pixel model alone is not this scroll proof.
        (setf (ebox-update--boundary-elastic-scroll-safe boundary) t)
        (ebox-elastic--remember node signature result)))))

(defun ebox-update--replace-boundary (operation boundary)
  "Replace BOUNDARY's retained primitives with its ordinary render.
Rows whose pixels are unchanged keep their primitives and damage.  A pure
size change of an absolute panel whose learned size response is verified
for the new size replays that response instead of rendering, and every
ordinary render after a size change teaches the response.  Throw
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
         (change (and target (ebox-update--elastic-change boundary)))
         (rows (and change (ebox-update--boundary-rows records target)))
         (lines (or (and rows (ebox-update--elastic-lines operation boundary change rows))
                    (let ((text (ebox-update--render-boundary operation boundary)))
                      (when (stringp text)
                        (let ((lines (ebox-string-lines text)))
                          (when (and rows (not (ebox-update--boundary-scroll-sensitive boundary)))
                            (ebox-update--elastic-learn operation boundary change rows lines program))
                          lines)))))
         (pieces (and lines (ebox-layer--pieces lines node)))
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
    (ebox-geometry--scroll-stage scene)
    (plist-put state :runtime-revision (1- (plist-get publication-report :new-revision)))
    (plist-put report :revision (plist-get publication-report :new-revision))
    (plist-put report :publication publication-report)
    (plist-put report :dirty-kinds (ebox-update--dirty-kinds operation))
    (plist-put state :last-update-report report)
    (when (ebox-update--cohort-stage operation) (funcall (ebox-update--cohort-stage operation)))))

(defun ebox-update--restore-structure (operation)
  "Restore OPERATION's swapped candidate tables before an ordinary state query."
  (let ((state (ebox-update--cohort-state operation)))
    (dolist (entry (ebox-update--cohort-structural operation))
      (plist-put state (car entry) (cdr entry)))
    (setf (ebox-update--cohort-structural operation) nil)))

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
          (setf (ebox-update--group-staged group) nil))))
    (ebox-update--restore-structure operation)))

(defun ebox-update--rollback (scene _report)
  "Restore SCENE's source, runtime, interaction and paired caller authority."
  (let* ((operation (ebox-geometry--operation-active-operation scene))
         (state (ebox-update--cohort-state operation)))
    (ebox-update--restore-source operation)
    (ebox-geometry--scroll-rollback scene)
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
         (state (ebox-update--cohort-state operation))
         (scene (ebox-update--cohort-scene operation))
         (routes (ebox-geometry--operation-routes scene))
         (count (or count (and (vectorp changed-indices) (length changed-indices))))
         (epoch (1+ (ebox-update--cohort-epoch operation))) result)
    (unless (and (vectorp values) (= (length values) (length members))
                 (vectorp changed-indices) (integerp count) (<= 0 count (length changed-indices)))
      (user-error "Invalid Ebox prepared update values or member indices"))
    (when (ebox-update-valid-p operation)
      ;; Install the candidate tables for the render and roll back together
      ;; with the source slots; nothing observes them before this point.
      (when-let* ((candidate-state (ebox-update--cohort-structural-state operation)))
        (setf (ebox-update--cohort-structural operation) nil)
        (dolist (key ebox-update--structural-state-keys)
          (push (cons key (and (plist-member state key) (plist-get state key)))
                (ebox-update--cohort-structural operation))
          (plist-put state key (plist-get candidate-state key)))
        (cl-loop for group across groups do
          (when (ebox-update--group-structural group)
            (let* ((old-id (plist-get (ebox-update--group-node group) :node-id))
                   (node (ebox-runtime-index-get
                          old-id (plist-get state :node-table))))
              (unless node (throw 'unsupported nil))
              (setf (ebox-update--group-node group) node)
              (let ((boundary (ebox-update--group-boundary group)))
                (when boundary
                  (let ((boundary-node (ebox-runtime-index-get
                                        (plist-get (ebox-update--boundary-node boundary) :node-id)
                                        (plist-get state :node-table))))
                    (unless boundary-node (throw 'unsupported nil))
                    (setf (ebox-update--boundary-node boundary) boundary-node))))))))
      (setf (ebox-update--cohort-epoch operation) epoch
            (ebox-update--cohort-snapshots operation) nil
            (ebox-update--cohort-paint-changed operation) nil
            (ebox-update--cohort-staged operation) nil)
      (let ((boundaries (ebox-update--cohort-boundaries operation)))
        (dotimes (index (length boundaries))
          (let ((boundary (aref boundaries index)))
            (setf (ebox-update--boundary-dirty boundary) nil
                  (ebox-update--boundary-width boundary) nil
                  (ebox-update--boundary-height boundary) nil
                  (ebox-update--boundary-paint boundary) nil))))
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
                  (when (ebox-update--group-structural group)
                    (setf (ebox-update--group-repaint group) t))
                  ;; Only a raster value that differs from the displayed one
                  ;; re-renders the boundary; translation, crop and selector
                  ;; changes keep their retained primitives.
                  (let* ((boundary (ebox-update--group-boundary group))
                         (node (ebox-update--group-node group))
                         (own (and boundary (eq node (ebox-update--boundary-node boundary)))))
                    (dotimes (key-index (length keys))
                      (let* ((property (aref keys key-index))
                             (value (aref incoming key-index))
                             (offset (aref offsets key-index))
                             (old (ebox-update--group-current-value group offset)))
                        (when (and (memq property '(:content :hover-content :color :background-color :bgcolor
                                                    :border :font-weight :visibility))
                                   (not (equal-including-properties value old)))
                          (setf (ebox-update--group-repaint group) t)
                          (when boundary (setf (ebox-update--boundary-paint boundary) t))
                          (unless (memq property '(:content :hover-content))
                            (setf (ebox-update--cohort-paint-changed operation) t
                                  (ebox-update--group-restyle group) t)))
                        (when (and own (memq property '(:width :height)) (consp old) (consp (cdr old)))
                          (if (eq property :width)
                              (setf (ebox-update--boundary-width boundary) (cadr old))
                            (setf (ebox-update--boundary-height boundary) (cadr old))))
                        (ebox-update--capture-value group offset value)))
                    (when (ebox-update--group-resized group)
                      (setf (ebox-update--group-repaint group) t)
                      (when (and boundary (not own))
                        (setf (ebox-update--boundary-paint boundary) t)))))))
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
                (when (and (ebox-update--group-dirty group)
                           (not (ebox-update--group-structural group)))
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
              (dotimes (index (length groups))
                (let ((group (aref groups index)))
                  (when (and (ebox-update--group-dirty group) (ebox-update--group-repaint group)
                             (ebox-update--group-boundary group))
                    (setf (ebox-update--boundary-dirty (ebox-update--group-boundary group)) t))))
              (ebox-update--forget-signatures operation)
              (ebox-incremental--with-phase 'layout
                (dotimes (index (length boundaries))
                  (when (ebox-update--boundary-dirty (aref boundaries index))
                    (ebox-geometry--scroll-begin scene)
                    (dolist (node (ebox-update--boundary-scroll-nodes (aref boundaries index)))
                      (ebox-update--snapshot-node operation node))
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
        (ebox-geometry--scroll-settle scene (and result t))
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
