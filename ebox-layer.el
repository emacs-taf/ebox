;;; ebox-layer.el --- Retained box placement and text composition -*- lexical-binding: t; -*-

;;; Commentary:
;; Compose visible pieces without changing the logical tree.  Horizontal
;; coordinates are pixels; vertical coordinates share the host's text rows.
;; This module never writes a buffer or owns application state.

;;; Code:

(require 'cl-lib)
(require 'ebox-tree)
(require 'ebox-composite)

(declare-function ebox-get "ebox" (box property))
(declare-function ebox--ensure-region-id "ebox" (box))
(declare-function ebox--substring-pixel-width "ebox-measure" (string start end))
(declare-function ebox--string-pixel-width "ebox-measure" (string))
(declare-function ebox-string-lines "ebox" (string))
(declare-function ebox-lines-join "ebox" (lines))
(declare-function ebox--render-with-cache "ebox" (node &optional width probe))
(declare-function ebox--call-with-box-content-context "ebox-layout" (box function))
(declare-function ebox--wrapper-content-viewport-pixel "ebox-layout" (box))
(declare-function ebox--content-height "ebox-layout" (box height &optional rendered))
(declare-function ebox--size-pixels "ebox-layout" (value &optional box axis percent-base))
(declare-function ebox--size-line-height "ebox-layout" (&optional box))
(declare-function ebox--record-rendered-uniform-width "ebox-layout" (rendered width))
(declare-function ebox--record-rendered-intrinsic-size "ebox-layout" (rendered width height))
(declare-function ebox-pixel-space "ebox" (pixels))
(defvar ebox-region-types)
(defvar ebox--intrinsic-layout-measurement)
(defvar ebox--render-source-index)

(defvar ebox-layer--render-root nil
  "Root of this spatial materialization, never a live buffer root.")
(defvar ebox-layer--portals nil
  "Candidate-local absolute nodes awaiting root composition.")

(defvar ebox-layer--active-p 'unknown
  "Whether the current candidate contains layered layout.
Retained publication supplies a known boolean; isolated rendering resolves
the fact once for its spatial root.")

(defun ebox-layer-active-p (&optional node)
  "Return the current candidate's layer capability without repeated scans."
  (if (eq ebox-layer--active-p 'unknown)
      (if ebox-layer--render-root
          (setq ebox-layer--active-p
                (ebox-layer-subtree-p ebox-layer--render-root))
        (ebox-layer-subtree-p node))
    ebox-layer--active-p))

(defun ebox-layer-positioned-p (node)
  "Return non-nil when NODE opts into positioned box painting."
  (memq (plist-get node :position) '(relative absolute)))

(defun ebox-layer-host-p (node)
  "Return non-nil when NODE composes positioned direct children."
  (and (eq (plist-get node :ebox-kind) 'box)
       (cl-some #'ebox-layer-positioned-p
                (ebox-tree-layout-children node))))

(defun ebox-layer-subtree-p (node)
  "Return non-nil when NODE's logical subtree contains positioned painting."
  (and (listp node)
       (or (ebox-layer-host-p node)
           (ebox-layer-positioned-p node)
           (cl-some #'ebox-layer-subtree-p (ebox-tree-node-children node)))))

(defun ebox-layer-portals-p (node)
  "Return non-nil when NODE's subtree projects content to its render root."
  (and (listp node)
       (or (eq (plist-get node :layer) 'root)
           (cl-some #'ebox-layer-portals-p (ebox-tree-node-children node)))))

(defun ebox-layer--owned-p (line position region)
  "Whether LINE at POSITION visibly belongs to REGION, excluding margins."
  (and (not (cl-some (lambda (role)
                       (equal region (get-text-property position role line)))
                     '(ebox-ml ebox-mr ebox-mt ebox-mb)))
       (or (member region (get-text-property position 'ebox-content-owners line))
           (equal region (get-text-property position 'ebox-content-owner line))
           (cl-some (lambda (role)
                      (equal region (get-text-property position (cdr role) line)))
                    ebox-region-types))))

(defun ebox-layer--pieces (lines node)
  "Return NODE's visible source intervals in LINES, before positioning."
  (let ((region (ebox--ensure-region-id node)) pieces)
    (cl-loop for line in lines for row from 0 do
             (let ((start 0) (limit (length line)))
               (while (< start limit)
                 (let ((end (next-property-change start line limit)))
                   (when (ebox-layer--owned-p line start region)
                     (let ((x (ebox--substring-pixel-width line 0 start))
                           (right (ebox--substring-pixel-width line 0 end)))
                       (when (> right x)
                         ;; Keep the full row as source so shaping and shared
                         ;; display objects are measured in their own context.
                         (push (list :line line :start x :end right :y row)
                               pieces))))
                   (setq start end)))))
    ;; Property boundaries must not become artificial glyph clipping edges.
    (let (merged)
      (dolist (piece (nreverse pieces))
        (let ((last (car merged)))
          (if (and last (= (plist-get last :y) (plist-get piece :y))
                   (= (plist-get last :end) (plist-get piece :start)))
              (plist-put last :end (plist-get piece :end))
            (push piece merged))))
      (nreverse merged))))

(defun ebox-layer--bounds (pieces)
  "Return (X Y WIDTH HEIGHT) covering nonempty PIECES, or nil."
  (when pieces
    (let ((left (apply #'min (mapcar (lambda (p) (plist-get p :start)) pieces)))
          (right (apply #'max (mapcar (lambda (p) (plist-get p :end)) pieces)))
          (top (apply #'min (mapcar (lambda (p) (plist-get p :y)) pieces)))
          (bottom (apply #'max (mapcar (lambda (p) (plist-get p :y)) pieces))))
      (list left top (- right left) (1+ (- bottom top))))))

(defun ebox-layer--offset (node property host extent)
  "Resolve NODE's PROPERTY against HOST and containing axis EXTENT."
  (let* ((vertical (eq property :top))
         (value (or (plist-get node property) (if vertical '(lh 0) '(px 0))))
         (pixels (ebox--size-pixels value host (if vertical 'height 'width)
                                   (if vertical
                                       (* extent (ebox--size-line-height host))
                                     extent))))
    (unless (numberp pixels)
      (error "Ebox layer offset has no definite containing size: %S" value))
    (if vertical (floor (/ pixels (float (ebox--size-line-height host)))) pixels)))

(defun ebox-layer--validate-child (node host)
  "Check text backend placement contracts for NODE inside HOST."
  (ebox-layer-validate-node node)
  (when (ebox-layer-positioned-p node)
    (cl-labels ((check (child)
                  (unless (= (ebox--size-line-height child)
                             (ebox--size-line-height host))
                    (error "Ebox positioned boxes must share their host's line height"))
                  (mapc #'check (ebox-tree-node-children child))))
      (check node))))

(defun ebox-layer-validate-node (node)
  "Validate NODE's placement combinations independently of visibility."
  (when (and (or (plist-get node :anchor)
                 (eq (plist-get node :layer) 'root))
             (not (eq (plist-get node :position) 'absolute)))
    (error "Ebox :anchor and :layer root require :position absolute")))

(defun ebox-layer--ordered-records (host records)
  "Sort candidate RECORDS by layer and HOST logical document order."
  (let ((order (make-hash-table :test #'eq)) (index 0))
    (cl-labels ((visit (node)
                  (puthash node (cl-incf index) order)
                  (mapc #'visit (ebox-tree-node-children node))))
      (visit host))
    (cl-stable-sort
     (copy-sequence records)
     (lambda (a b)
       (let* ((an (plist-get a :node)) (bn (plist-get b :node))
              (az (or (plist-get an :z-index) 0))
              (bz (or (plist-get bn :z-index) 0)))
         (cond
          ((/= az bz) (< az bz))
          ((not (eq (and (ebox-layer-positioned-p an) t)
                    (and (ebox-layer-positioned-p bn) t)))
           (not (ebox-layer-positioned-p an)))
          (t (< (gethash an order 0) (gethash bn order 0)))))))))

(defun ebox-layer--compose-rows (host records width height)
  "Compose HOST's visible RECORDS in a WIDTH by HEIGHT content canvas."
  (let ((rows (make-vector height nil)))
    (dolist (record (ebox-layer--ordered-records host records))
      (let ((row (plist-get record :y)))
        (when (and (>= row 0) (< row height))
          (push record (aref rows row)))))
    (cl-loop for row across rows collect
             (ebox-composite-line "" (nreverse row) width))))

(defun ebox-layer--anchor-node (host id)
  "Find one logical anchor ID under HOST, rejecting ambiguous IDs."
  (let ((name (format "%s" id)) matches)
    (cl-labels ((visit (node)
                  (when (equal name (ebox-tree-node-id ebox--render-source-index node))
                    (push node matches))
                  (mapc #'visit (ebox-tree-node-children node))))
      (visit host))
    (when (cdr matches) (error "Ebox layer anchor is ambiguous: %s" name))
    (car matches)))

(defun ebox-layer--absolute-origin (node host bounds width height layer-width layer-height)
  "Resolve NODE's origin in HOST, or nil for an invisible anchor.
BOUNDS is the already resolved anchor rectangle, or nil.
WIDTH and HEIGHT bound the host; LAYER-WIDTH and LAYER-HEIGHT bound the panel."
  (let ((x (ebox-layer--offset node :left host width))
        (y (ebox-layer--offset node :top host height))
        (anchor (plist-get node :anchor)))
    (if (not anchor) (list x y)
      (when bounds
          (let* ((placement (or (plist-get node :placement) 'bottom-start))
                 (above (memq placement '(top-start top-end)))
                 (left (+ (car bounds) x
                          (if (memq placement '(bottom-end top-end))
                              (- (nth 2 bounds) layer-width) 0)))
                 (top (+ y (nth 1 bounds)
                         (if above (- layer-height) (nth 3 bounds))))
                 (other (+ y (nth 1 bounds)
                           (if above (nth 3 bounds) (- layer-height)))))
            (when (and (or (< top 0) (> (+ top layer-height) height))
                       (>= other 0) (<= (+ other layer-height) height))
              (setq top other))
            (list (max 0 (min left (max 0 (- width layer-width))))
                  (max 0 (min top (max 0 (- height layer-height))))))))))

(defun ebox-layer--visible-bounds (bounds origin width height)
  "Translate BOUNDS by ORIGIN and intersect the WIDTH by HEIGHT canvas."
  (when (and bounds origin)
    (let* ((x (+ (car bounds) (car origin)))
           (y (+ (cadr bounds) (cadr origin)))
           (left (max 0 x)) (top (max 0 y))
           (right (min width (+ x (nth 2 bounds))))
           (bottom (min height (+ y (nth 3 bounds)))))
      (when (and (> right left) (> bottom top))
        (list left top (- right left) (- bottom top))))))

(defun ebox-layer--absolute-records (host nodes base width height)
  "Resolve HOST's absolute NODES and return opaque paint records.
BASE supplies normal-flow anchor fragments.  Anchor dependencies are resolved
before painting, so source order and z order never select the geometry.
Missing or clipped anchors suppress their dependents; cycles signal before
publication.  Nested root projections join this same candidate-local pass."
  (let ((panels (make-hash-table :test #'eq))
        (parents (make-hash-table :test #'eq))
        (status (make-hash-table :test #'eq))
        (queue (copy-sequence nodes)) order records)
    (cl-labels
        ((index (node)
           (dolist (child (ebox-tree-node-children node))
             (puthash child node parents)
             (index child)))
         (panel-owner (node)
           (while (and node (not (gethash node panels)))
             (setq node (gethash node parents)))
           node)
         (resolve (node)
           (pcase (gethash node status)
             ('visiting (error "Ebox layer anchor dependency is cyclic"))
             ('done (plist-get (gethash node panels) :origin))
             (_
              (puthash node 'visiting status)
              (let* ((panel (gethash node panels))
                     (anchor (plist-get node :anchor))
                     (target (and anchor (ebox-layer--anchor-node host anchor)))
                     (provider (and target (panel-owner target)))
                     (bounds
                      (when (and target (not (eq (plist-get target :visibility) 'hidden)))
                        (if provider
                            (let ((origin (resolve provider)))
                              (ebox-layer--visible-bounds
                               (ebox-layer--bounds
                                (ebox-layer--pieces
                                 (plist-get (gethash provider panels) :lines) target))
                               origin width height))
                          (ebox-layer--bounds (ebox-layer--pieces base target)))))
                     (origin
                      (unless (eq (plist-get node :visibility) 'hidden)
                        (ebox-layer--absolute-origin
                         node host bounds width height
                         (plist-get panel :width) (length (plist-get panel :lines))))))
                (plist-put panel :origin origin)
                (puthash node 'done status)
                origin)))))
      (index host)
      (while queue
        (let ((node (pop queue)))
          (unless (gethash node panels)
            (ebox-layer--validate-child node host)
            (let* ((text
                    (unless (eq (plist-get node :visibility) 'hidden)
                      (ebox--call-with-box-content-context
                       host (lambda () (ebox--render-with-cache node)))))
                   (lines (and text (ebox-string-lines text))))
              (puthash node
                       (list :lines lines :origin nil
                             :width (if lines (apply #'max (mapcar #'ebox--string-pixel-width lines)) 0))
                       panels)
              (push node order)
              (when (eq host ebox-layer--render-root)
                (dolist (portal ebox-layer--portals)
                  (unless (or (gethash portal panels) (memq portal queue))
                    (setq queue (append queue (list portal))))))))))
      (dolist (node (nreverse order))
        (let ((origin (resolve node)))
          (when origin
            (dolist (piece (ebox-layer--pieces (plist-get (gethash node panels) :lines) node))
              (push (list :node node
                          :x (+ (car origin) (plist-get piece :start))
                          :y (+ (cadr origin) (plist-get piece :y))
                          :text (ebox-composite-slice (plist-get piece :line)
                                                      (plist-get piece :start)
                                                      (plist-get piece :end))) records))))))
    records))

(defun ebox-layer-render-children (host children renderer)
  "Compose HOST's CHILDREN using ordinary flow RENDERER.
RENDERER accepts a child list.  Logical nodes are never reordered or removed.
Only candidate-local lists of visible paint records are sorted."
  (let* ((flow (cl-remove-if (lambda (child)
                               (eq (plist-get child :position) 'absolute)) children))
         (base (funcall renderer flow)))
    (if ebox--intrinsic-layout-measurement base
      (let* ((lines (ebox-string-lines base))
             (width (or (ebox--wrapper-content-viewport-pixel host)
                        (if lines (apply #'max (mapcar #'ebox--string-pixel-width lines)) 0)))
             (flow-height (length lines))
             (height (max flow-height (ceiling (ebox--content-height host flow-height base))))
             (absolute (cl-remove-if-not (lambda (child)
                                          (eq (plist-get child :position) 'absolute)) children))
             records)
        (dolist (child children) (ebox-layer--validate-child child host))
        ;; Normal children preserve their layout slots.  Relative children use
        ;; the same source intervals and shift only their paint coordinates.
        (dolist (child flow)
          (unless (eq (plist-get child :visibility) 'hidden)
          (let ((dx (if (eq (plist-get child :position) 'relative)
                        (ebox-layer--offset child :left host width) 0))
                (dy (if (eq (plist-get child :position) 'relative)
                        (ebox-layer--offset child :top host height) 0)))
            (dolist (piece (ebox-layer--pieces lines child))
              (push (list :node child :y (+ dy (plist-get piece :y))
                          :x (+ dx (plist-get piece :start))
                          :text (ebox-composite-slice (plist-get piece :line)
                                                      (plist-get piece :start)
                                                      (plist-get piece :end))) records)))))
        (unless (eq host ebox-layer--render-root)
          (dolist (child absolute)
            (when (eq (plist-get child :layer) 'root)
              (cl-pushnew child ebox-layer--portals :test #'eq)))
          (setq absolute (cl-remove-if (lambda (child)
                                        (eq (plist-get child :layer) 'root)) absolute)))
        (when (eq host ebox-layer--render-root)
          (setq absolute (append absolute (reverse ebox-layer--portals))))
        (when (cl-some (lambda (child) (plist-get child :anchor)) absolute)
          ;; Anchor geometry follows relative movement and visible clipping,
          ;; not the original flow slot.  This extra composition is needed
          ;; only by anchored panels.
          (setq lines (ebox-layer--compose-rows host records width height)))
        (setq records (nconc (ebox-layer--absolute-records host absolute lines width height)
                             records))
        (ebox--record-rendered-intrinsic-size
         (ebox--record-rendered-uniform-width
          (ebox-lines-join (ebox-layer--compose-rows host records width height)) width)
         width flow-height)))))

(provide 'ebox-layer)

;;; ebox-layer.el ends here
