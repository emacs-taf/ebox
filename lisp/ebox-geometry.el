;;; ebox-geometry.el --- Prepared retained geometry execution -*- lexical-binding: t; -*-

;;; Commentary:
;; Compile stable mounted geometry to provider-owned placement primitives.
;; Application state remains with the caller; publication and recovery remain
;; with the existing Ebox surface.  Unsupported dependencies decline before
;; touching either authority.

;;; Code:

(require 'cl-lib)
(require 'ebox-runtime)
(require 'ebox-layer)

(cl-defstruct (ebox-geometry--operation
               (:constructor ebox-geometry--make-operation))
  "One mounted geometry program with cold-owned execution and undo storage."
  buffer surface state node properties units source-slots
  program target region-table scroll-table projection frame values
  viewport-cache content-cache
  routes interaction session active-operation frame-stage frame-rollback frame-accept
  interaction-stage interaction-rollback interaction-accept
  x-factor old-revision old-report report
  old-report-revision old-report-publication
  stylesheet stylesheet-epoch frame-window frame-font-frame display-snapshot
  frame-char-width frame-char-height window-width window-height
  stage rollback after-commit staged-p)

(cl-defstruct (ebox-geometry--route (:constructor ebox-geometry--make-route))
  "One fixed wrapper and its containing plane in a compiled output route."
  program target wrapper first-row lines content-offset
  saved-lines dirty prefixes suffixes properties signature transforms variants
  output-spine offsets damage damage-count domain template-key source-samples refresh-p
  metadata-tables metadata-signature face-additions surface-properties)

(defvar-local ebox-geometry--session nil
  "One shared prepared canvas and publication frame for the mounted surface.")

(defsubst ebox-geometry--interaction (operation)
  "Return OPERATION's shared current interaction capability."
  (ebox-geometry--operation-interaction
   (ebox-geometry--operation-session operation)))

(defun ebox-geometry--wrapper (node)
  "Compile NODE's fixed wrapper independently of its child layout."
  (let ((wrapper (copy-sequence node)))
    (cl-remf wrapper :children)
    (cl-remf wrapper :ebox-child-sequence)
    (plist-put wrapper :ebox-content-node nil)
    (plist-put wrapper :content "")
    (plist-put wrapper :wrap-mode 'none)
    (plist-put wrapper :ebox-content-width-exact-p t)
    (plist-put wrapper :ebox-content-layout-complete-p t)
    wrapper))

(defun ebox-geometry--inline-slots-p (state node properties)
  "Prove that NODE's mutable PROPERTIES have effective inline winners.
The cold proof uses ECSS's authoritative cascade, including important rules
and scoped declarations.  Equal current values alone cannot prove ownership."
  (let* ((source (plist-get state :source-index))
         (ebox-selector-view--current (ebox-source--index-selector-view source))
         (ebox-selector-view--topology (ebox-source--index-selector-topology source))
         (parent-id (ebox-runtime-index-get (plist-get node :node-id)
                                            (plist-get state :parent-table)))
         (parent (and parent-id (ebox-runtime-index-get parent-id
                                                        (plist-get state :node-table))))
         (style (ecss-compute-style
                 ebox-style-schemas (ebox-source--index-node-subject source node)
                 :declarations (ebox-style-node-declarations source node)
                 :stylesheet ebox-style-stylesheet
                 :parent-style (plist-get parent :ebox-computed-style)
                 :scopes (ebox-style-source-scopes source)
                 :adapter ebox-selector-view-adapter
                 :value-resolver #'ebox-resolve-value :provenance t))
         (provenance (ecss-computed-style-provenance style))
         (valid t))
    (dotimes (index (length properties))
      (let ((property (aref properties index)))
        (dolist (key (if (eq property :border)
                         '(:border-top-color :border-right-color :border-bottom-color :border-left-color)
                       (and (memq property '(:left :top :z-index :color :background-color :bgcolor :font-weight))
                            (list property))))
          (unless (plist-get (plist-get provenance (ebox-style-schema-id key)) :inline)
            (setq valid nil)))))
    valid))

(defconst ebox-geometry--pass-through-properties
  '(display ebox-content-idx ebox--paint-origin ebox--prepared-owners)
  "Primitive properties independent of a fixed enclosing wrapper.")

(defun ebox-geometry--property-signature (string position properties signature)
  "Read STRING at POSITION into fixed PROPERTIES and SIGNATURE storage."
  (dotimes (index (length properties))
    (aset signature index (get-text-property position (aref properties index) string)))
  signature)

(defun ebox-geometry--compile-wrapper (route &optional inner-domain)
  "Compile ROUTE's fixed chrome and finite content-property transformations.
The generic Box renderer is used only here, before any geometry execution.
All source property combinations and clipping paint fallbacks are admitted
up front; an unknown later combination declines the prepared operation."
  (let* ((wrapper (ebox-geometry--route-wrapper route))
         (program (ebox-geometry--route-program route))
         (height (ebox-layer--program-height program))
         (offset (ebox-geometry--route-content-offset route))
         (region (plist-get wrapper :region-id))
         (content (ebox-layer--program-render program))
         (left-count (cl-count-if (lambda (key) (> (ebox-get wrapper key) 0))
                                  '(:margin-left-pixel :border-left-pixel :padding-left-pixel)))
         (right-count (cl-count-if (lambda (key) (> (ebox-get wrapper key) 0))
                                   '(:padding-right-pixel :border-right-pixel :margin-right-pixel)))
         (top-p (and (= (floor (ebox-get wrapper :padding-top-height)) 0)
                     (> (ebox-get wrapper :border-top-pixel) 0)))
         (bottom-p (and (= (floor (ebox-get wrapper :padding-bottom-height)) 0)
                        (> (ebox-get wrapper :border-bottom-pixel) 0)))
         (color (and (ebox-style--text-paint-owner-p wrapper) (ebox-get wrapper :color)))
         (background (ebox-get wrapper :bgcolor))
         (surface-properties (ebox-interaction--node-surface-properties wrapper))
         (template-key
          (cons (list region (ebox-layer--program-width program) height offset color background
                      (plist-get wrapper :ebox-font-fact) surface-properties)
                (mapcar (lambda (key) (ebox-get wrapper key))
                        '(:text-align :vertical-align :visibility :overflow
                                      :padding-left-pixel :padding-right-pixel :padding-top-height :padding-bottom-height
                                      :margin-left-pixel :margin-right-pixel :margin-top-height :margin-bottom-height
                                      :border-left-pixel :border-right-pixel :border-top-pixel :border-bottom-pixel
                                      :border-left-color :border-right-color :border-top-color :border-bottom-color))))
         (retained (and (equal template-key (ebox-geometry--route-template-key route))
                        (ebox-geometry--route-source-samples route)))
         (old-properties (and retained (ebox-geometry--route-properties route)))
         (keys (if retained (append old-properties nil)
                 (copy-sequence '(face font-lock-face ebox-content ebox-content-owner ebox-content-owners
                                       ebox-bt ebox-bb))))
         (samples (or retained (make-hash-table :test #'equal)))
         (domain (and retained (ebox-geometry--route-domain route)))
         pending properties signature output rows)
    (unless (and (eq (ebox-get wrapper :text-align) 'left)
                 (eq (ebox-get wrapper :visibility) 'visible)
                 (= height (ebox--content-height wrapper height content)))
      (throw 'ebox-geometry-unsupported nil))
    (if retained
        (setq rows (copy-sequence (ebox-geometry--route-lines route)))
      (plist-put wrapper :content content)
      (setq output (ebox--render-layout wrapper)
            rows (vconcat (ebox-string-lines output))))
    (when (and (ebox-geometry--route-lines route)
               (/= (length rows) (length (ebox-geometry--route-lines route))))
      (throw 'ebox-geometry-unsupported nil))
    (unless (= (length rows)
               (+ height offset (floor (ebox-get wrapper :padding-bottom-height))
                  (floor (ebox-get wrapper :margin-bottom-height))))
      (throw 'ebox-geometry-unsupported nil))
    ;; Include paint-only clipping replacements and the neutral fill primitive.
    ;; A width-adjusted display space keeps all its other property values.
    (dolist (string (append inner-domain (cons " " (ebox-layer--program-strings program))))
      (let ((position 0))
        (while (< position (length string))
          (let* ((props (text-properties-at position string))
                 (paint (list 'face (plist-get props 'face)
                              'font-lock-face (plist-get props 'font-lock-face))))
            (dolist (sample (list props paint))
              (let ((copy (copy-sequence sample)))
                (dolist (property ebox-geometry--pass-through-properties)
                  (cl-remf copy property))
                (dolist (property '(face font-lock-face))
                  (unless (plist-get copy property) (cl-remf copy property)))
                (unless (gethash copy samples)
                  (puthash copy t samples)
                  (push copy pending))
                (let ((tail copy))
                  (while tail
                    (cl-pushnew (car tail) keys)
                    (setq tail (cddr tail))))))
            (setq position (next-property-change position string (length string)))))))
    (let ((tail surface-properties))
      (while tail (cl-pushnew (car tail) keys) (setq tail (cddr tail))))
    ;; Surface decoration may introduce hover signatures and inherited native
    ;; capabilities.  Discover their output keys once using the real helpers.
    (dolist (props pending)
      (let* ((probe (apply #'propertize "x" props))
             (styled (ebox--apply-surface-properties
                      (ebox--propertize-colors probe color background) surface-properties))
             (tail (text-properties-at 0 styled)))
        (while tail
          (unless (memq (car tail) ebox-geometry--pass-through-properties)
            (cl-pushnew (car tail) keys))
          (setq tail (cddr tail)))))
    (setq properties (vconcat keys) signature (make-vector (length keys) nil))
    (let* ((same-schema (and retained (equal properties old-properties)))
           (tables (if same-schema (ebox-geometry--route-transforms route) (make-vector 8 nil)))
           (prefixes (if retained (ebox-geometry--route-prefixes route) (make-vector height nil)))
           (suffixes (if retained (ebox-geometry--route-suffixes route) (make-vector height nil)))
           (variants (if retained (ebox-geometry--route-variants route) (make-vector height 0)))
           (used-variants (make-vector 8 nil))
           (metadata-tables (if same-schema (ebox-geometry--route-metadata-tables route) (make-vector 8 nil)))
           (metadata-signature (make-vector 5 nil))
           (face-additions (make-vector 8 nil)))
      (unless same-schema
        (setq pending nil domain nil)
        (maphash (lambda (props _) (push props pending)) samples))
      ;; Only variants that occur in this fixed wrapper may feed its enclosing
      ;; domain.  Inventing every top/bottom-border combination multiplies
      ;; both preparation time and the following wrapper's property domain.
      (dotimes (row height)
        (let ((variant (+ (if (and top-p (= row 0)) 2 0)
                          (if (and bottom-p (= row (1- height))) 4 0))))
          (aset variants row variant)
          (aset used-variants variant t)
          (aset used-variants (1+ variant) t)))
      (dotimes (variant 8)
        (when (aref used-variants variant)
          (unless (aref tables variant) (aset tables variant (make-hash-table :test #'equal)))
          (unless (aref metadata-tables variant) (aset metadata-tables variant (make-hash-table :test #'equal)))
          (aset face-additions variant
                (vconcat (append (and color (list (ebox-buffer--color-face color 'foreground)))
                                 (and background (list (ebox-buffer--color-face background 'background)))
                                 (and (/= 0 (logand variant 2))
                                      (list (ebox-buffer--color-face (ebox-get wrapper :border-top-color) 'overline)))
                                 (and (/= 0 (logand variant 4))
                                      (list (ebox-buffer--color-face (ebox-get wrapper :border-bottom-color) 'underline))))))
          (dolist (props pending)
            (let* ((source (apply #'propertize "x" props))
                   ;; A nonempty child-content sentinel models rows whose
                   ;; other pieces already carry content, without filling this
                   ;; piece's intentionally empty direct-content property.
                   (probe (if (= 0 (logand variant 1))
                              (concat (propertize "x" 'ebox-content 'ebox/geometry-sentinel) source)
                            source))
                   (owned (ebox--propertize-content-line probe region 0 " "))
                   (painted (ebox--propertize-colors owned color background)))
              (when (/= 0 (logand variant 2))
                (setq painted (ebox--propertize-overline painted (ebox-get wrapper :border-top-color)))
                (put-text-property 0 (length painted) 'ebox-bt region painted))
              (when (/= 0 (logand variant 4))
                (setq painted (ebox--propertize-underline painted (ebox-get wrapper :border-bottom-color)))
                (put-text-property 0 (length painted) 'ebox-bb region painted))
              (ebox--apply-surface-properties painted surface-properties)
              (let* ((position (1- (length painted)))
                     (changes nil))
                (push (substring painted position) domain)
                (dotimes (index (length properties))
                  (let ((property (aref properties index)))
                    (unless (equal (get-text-property 0 property source)
                                   (get-text-property position property painted))
                      (setq changes (cons property (cons (get-text-property position property painted) changes))))))
                (puthash (copy-sequence (ebox-geometry--property-signature source 0 properties signature))
                         (or changes 'ebox/unchanged) (aref tables variant))
                (let ((metadata-properties [ebox-content ebox-content-owner ebox-content-owners ebox-bt ebox-bb])
                      metadata-changes)
                  (dotimes (meta-index 5)
                    (let ((property (aref metadata-properties meta-index)))
                      (aset metadata-signature meta-index (get-text-property 0 property source))
                      (unless (equal (get-text-property 0 property source)
                                     (get-text-property position property painted))
                        (setq metadata-changes
                              (cons property (cons (get-text-property position property painted) metadata-changes))))))
                  (puthash (copy-sequence metadata-signature)
                           (or metadata-changes 'ebox/unchanged) (aref metadata-tables variant))))))))
      (unless retained
        (dotimes (row height)
          (let* ((line (aref rows (+ offset row)))
                 (end (- (length line) right-count)))
            (unless (<= left-count end) (throw 'ebox-geometry-unsupported nil))
            (aset prefixes row (substring line 0 left-count))
            (aset suffixes row (substring line end))
            (aset variants row (+ (if (and top-p (= row 0)) 2 0)
                                  (if (and bottom-p (= row (1- height))) 4 0))))))
      (setf (ebox-geometry--route-lines route) rows
            (ebox-geometry--route-saved-lines route) (make-vector (length rows) nil)
            (ebox-geometry--route-dirty route) (make-vector (length rows) nil)
            (ebox-geometry--route-prefixes route) prefixes
            (ebox-geometry--route-suffixes route) suffixes
            (ebox-geometry--route-properties route) properties
            (ebox-geometry--route-signature route) signature
            (ebox-geometry--route-transforms route) tables
            (ebox-geometry--route-variants route) variants
            (ebox-geometry--route-output-spine route) (make-list (length rows) nil)
            (ebox-geometry--route-offsets route) (make-vector (1+ (length rows)) 0)
            (ebox-geometry--route-damage route) (make-vector (* 4 (length rows)) 0)
            (ebox-geometry--route-domain route) domain
            (ebox-geometry--route-template-key route) template-key
            (ebox-geometry--route-source-samples route) samples
            (ebox-geometry--route-refresh-p route) nil
            (ebox-geometry--route-metadata-tables route) metadata-tables
            (ebox-geometry--route-metadata-signature route) metadata-signature
            (ebox-geometry--route-face-additions route) face-additions
            (ebox-geometry--route-surface-properties route) surface-properties)
      (when retained
        (dotimes (row height)
          (aset rows (+ offset row)
                (ebox-geometry--render-wrapper-row
                 route row (aref (ebox-layer--program-rows program) row))))))
    output))

(defun ebox-geometry--render-wrapper-row (route row source)
  "Execute ROUTE's precompiled ROW wrapper on primitive SOURCE pixels."
  (let* ((direct (not (text-property-not-all 0 (length source) 'ebox-content nil source)))
         (variant (+ (aref (ebox-geometry--route-variants route) row) (if direct 1 0)))
         (table (aref (ebox-geometry--route-transforms route) variant))
         (properties (ebox-geometry--route-properties route))
         (signature (ebox-geometry--route-signature route))
         (result (copy-sequence source))
         (position 0) (limit (length source)))
    (while (< position limit)
      (let* ((next (next-property-change position source limit))
             (changes (gethash (ebox-geometry--property-signature source position properties signature) table)))
        (if changes
            (unless (eq changes 'ebox/unchanged)
              (add-text-properties position next changes result))
          ;; Primitive repaint may change face/image/native values while
          ;; retaining the already compiled ownership topology.  Replay only
          ;; that metadata program and the wrapper's fixed paint/native layers.
          (let* ((metadata-properties [ebox-content ebox-content-owner ebox-content-owners ebox-bt ebox-bb])
                 (metadata-signature (ebox-geometry--route-metadata-signature route))
                 (metadata (gethash (ebox-geometry--property-signature source position metadata-properties metadata-signature)
                                    (aref (ebox-geometry--route-metadata-tables route) variant)))
                 (faces (aref (ebox-geometry--route-face-additions route) variant)))
            (unless metadata (throw 'ebox-geometry-unsupported nil))
            (unless (eq metadata 'ebox/unchanged) (add-text-properties position next metadata result))
            (dotimes (face-index (length faces))
              (ebox--add-render-face! result position next (aref faces face-index) t))
            (let ((tail (ebox-geometry--route-surface-properties route)))
              (while tail
                (ebox-interaction--fill-property result position next (car tail) (cadr tail))
                (setq tail (cddr tail))))
            (ebox-interaction--refresh-hover! result position next)))
        (setq position next)))
    (when direct
      (put-text-property 0 limit 'ebox-content-idx row result))
    (setq result (concat (aref (ebox-geometry--route-prefixes route) row)
                         result (aref (ebox-geometry--route-suffixes route) row)))
    result))

(defun ebox-geometry--join-route (route)
  "Join ROUTE's retained rows and record old/new dirty character intervals."
  (let ((rows (ebox-geometry--route-lines route))
        (dirty (ebox-geometry--route-dirty route))
        (offsets (ebox-geometry--route-offsets route))
        (damage (ebox-geometry--route-damage route))
        (tail (ebox-geometry--route-output-spine route))
        (position 0) (count 0))
    (dotimes (row (length rows))
      (when (aref dirty row)
        (aset damage (* 4 count) (aref offsets row))
        (aset damage (1+ (* 4 count))
              (+ (aref offsets row) (length (aref (ebox-geometry--route-saved-lines route) row))))
        (aset damage (+ 2 (* 4 count)) position)
        (aset damage (+ 3 (* 4 count)) (+ position (length (aref rows row))))
        (setq count (1+ count)))
      (setcar tail (aref rows row))
      (setq tail (cdr tail) position (+ position (length (aref rows row)) 1)))
    (setf (ebox-geometry--route-damage-count route) count)
    (ebox-lines-join (ebox-geometry--route-output-spine route))))

(defun ebox-geometry--settle-wrapper (route accepted)
  "Accept or restore ROUTE's dirty wrapper strings and row offsets."
  (let ((rows (ebox-geometry--route-lines route))
        (saved (ebox-geometry--route-saved-lines route))
        (dirty (ebox-geometry--route-dirty route))
        (offsets (ebox-geometry--route-offsets route))
        (position 0))
    (when rows
      (dotimes (row (length rows))
        (when (aref dirty row)
          (unless accepted (aset rows row (aref saved row)))
          (aset saved row nil)
          (aset dirty row nil))
        (aset offsets row position)
        (setq position (+ position (length (aref rows row)) 1)))
      (aset offsets (length rows) (max 0 (1- position))))))

(defun ebox-geometry--render (operation &optional before-route)
  "Execute OPERATION's retained plane and compiled dirty-row wrappers."
  (catch 'ebox-geometry-unsupported
    (let* ((state (ebox-geometry--operation-state operation))
           (routes (ebox-geometry--operation-routes operation))
           (ebox-viewport-width (plist-get state :viewport-width))
           (ebox-viewport-height (plist-get state :viewport-height))
           (ebox--render-display-signature (plist-get state :display-signature))
           (ebox--render-source-index (plist-get state :source-index))
           (ebox--region-box-table (ebox-geometry--operation-region-table operation))
           (ebox--scroll-global-state (ebox-geometry--operation-scroll-table operation))
           (ebox--css-viewport-dependent-subtree-cache
            (ebox-geometry--operation-viewport-cache operation))
           (ebox--box-content-render-cache (ebox-geometry--operation-content-cache operation))
           (ebox--surface-materialization-active t)
           (ebox-layer--active-p nil)
           (ebox-incremental--render-portals-p nil)
           (ebox--display-cache-validated t))
      (dotimes (index (length routes))
        (let* ((route (aref routes index))
               (program (ebox-geometry--route-program route))
               (dirty (ebox-layer--program-dirty program))
               (offset (ebox-geometry--route-content-offset route)))
          (when before-route (funcall before-route index))
          (if (or (null (ebox-geometry--route-prefixes route))
                  (ebox-geometry--route-refresh-p route))
              (progn
                (ebox-geometry--compile-wrapper
                 route (and (> index 0) (ebox-geometry--route-domain (aref routes (1- index)))))
                (when (= index (1- (length routes)))
                  ;; The accepted surface is the authority for rows outside
                  ;; future damage.  A generic wrapper probe may normalize
                  ;; unoccupied ownership differently from its layered host.
                  (setf (ebox-geometry--route-lines route)
                        (vconcat (ebox-string-lines
                                  (ebox--pub--shadow-surface-output
                                   (ebox-geometry--operation-surface operation))))))
                (ebox-geometry--settle-wrapper route t))
            (ebox-layer--program-render program t)
            (dotimes (row (length dirty))
              (when (aref dirty row)
                (let* ((output-row (+ row offset))
                       (rows (ebox-geometry--route-lines route))
                       (rendered (ebox-geometry--render-wrapper-row
                                  route row (aref (ebox-layer--program-rows program) row))))
                  (unless (aref (ebox-geometry--route-dirty route) output-row)
                    (aset (ebox-geometry--route-saved-lines route) output-row (aref rows output-row)))
                  (aset (ebox-geometry--route-dirty route) output-row t)
                  (aset rows output-row
                        (if (= index (1- (length routes)))
                            (progn
                              (remove-text-properties 0 (length rendered) '(ebox--paint-origin nil) rendered)
                              (ebox--quantize-pixel-spaces rendered))
                          rendered))))))
          (when (< (1+ index) (length routes))
            (let ((next (aref routes (1+ index))))
              (ebox-layer--program-replace-rows
               (ebox-geometry--route-program next)
               (ebox-geometry--route-target next) (ebox-geometry--route-lines route)
               (ebox-geometry--route-first-row next) dirty offset)))))
      (ebox-geometry--join-route (aref routes (1- (length routes)))))))

(defun ebox-geometry--interaction-capability (buffer state)
  "Return BUFFER's current compiled interaction capability for STATE."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((scene ebox-geometry--session))
        (and (ebox-geometry--session-valid-p scene)
             (eq state (ebox-geometry--operation-state scene))
             (ebox-geometry--operation-interaction scene))))))

(defun ebox-geometry--interaction-stage (scene report)
  "Stage SCENE's active native metadata operation with REPORT."
  (when ebox-surface--observation-context
    (setf (ebox-surface--observation-correlation-id ebox-surface--observation-context)
          (plist-get report :transaction-id)))
  (funcall (ebox-geometry--operation-interaction-stage scene)
           (ebox-geometry--operation-active-operation scene) report))

(defun ebox-geometry--interaction-rollback (scene report)
  "Roll back SCENE's active native metadata operation with REPORT."
  (funcall (ebox-geometry--operation-interaction-rollback scene)
           (ebox-geometry--operation-active-operation scene) report))

(defun ebox-geometry--interaction-accept (scene report)
  "Accept SCENE's active native metadata operation with REPORT."
  (funcall (ebox-geometry--operation-interaction-accept scene)
           (ebox-geometry--operation-active-operation scene) report))

(defun ebox-geometry--publish-interaction (buffer state operation stage rollback accept)
  "Publish OPERATION's native metadata through BUFFER's shared scene.
STATE must be the accepted runtime.  STAGE, ROLLBACK and ACCEPT receive
OPERATION and the publication report; no pixel or mount authority is replaced."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((scene ebox-geometry--session))
        (when (and (ebox-geometry--session-valid-p scene)
                   (eq state (ebox-geometry--operation-state scene)))
          (setf (ebox-geometry--operation-active-operation scene) operation
                (ebox-geometry--operation-interaction-stage scene) stage
                (ebox-geometry--operation-interaction-rollback scene) rollback
                (ebox-geometry--operation-interaction-accept scene) accept
                (ebox-geometry--operation-frame-stage scene) #'ebox-geometry--interaction-stage
                (ebox-geometry--operation-frame-rollback scene) #'ebox-geometry--interaction-rollback
                (ebox-geometry--operation-frame-accept scene) #'ebox-geometry--interaction-accept)
          (ebox--pub-frame-publish-state (ebox-geometry--operation-frame scene) state))))))

(defun ebox-geometry--dispatch-stage (session report)
  "Stage the active primitive publisher bound to SESSION with REPORT."
  (funcall (or (ebox-geometry--operation-frame-stage session) #'ebox-geometry--stage) session report))

(defun ebox-geometry--dispatch-rollback (session report)
  "Roll back the active primitive publisher bound to SESSION with REPORT."
  (funcall (or (ebox-geometry--operation-frame-rollback session) #'ebox-geometry--rollback) session report))

(defun ebox-geometry--dispatch-accept (session report)
  "Accept the active primitive publisher bound to SESSION with REPORT."
  (funcall (or (ebox-geometry--operation-frame-accept session) #'ebox-geometry--accept) session report))

(defun ebox-geometry--stage (operation publication-report)
  "Stage OPERATION's source and caller state with PUBLICATION-REPORT."
  (setq operation (ebox-geometry--operation-active-operation operation))
  (when ebox-surface--observation-context
    (setf (ebox-surface--observation-correlation-id ebox-surface--observation-context)
          (plist-get publication-report :transaction-id)))
  (let ((state (ebox-geometry--operation-state operation)))
    (setf (ebox-geometry--operation-old-revision operation)
          (plist-get state :runtime-revision)
          (ebox-geometry--operation-old-report operation)
          (plist-get state :last-update-report)
          (ebox-geometry--operation-staged-p operation) t)
    (ebox-source--update-slots-stage
     (ebox-geometry--operation-source-slots operation)
     (ebox-geometry--operation-values operation))
    (ebox-interaction--geometry-stage (ebox-geometry--interaction operation))
    (plist-put state :runtime-revision
               (1- (plist-get publication-report :new-revision)))
    (let ((report (ebox-geometry--operation-report operation)))
      (setf (ebox-geometry--operation-old-report-revision operation)
            (plist-get report :revision)
            (ebox-geometry--operation-old-report-publication operation)
            (plist-get report :publication))
      (plist-put report :revision (plist-get publication-report :new-revision))
      (plist-put report :publication publication-report)
      (plist-put state :last-update-report report))
    (when (ebox-geometry--operation-stage operation)
      (funcall (ebox-geometry--operation-stage operation)))))

(defun ebox-geometry--rollback (operation _report)
  "Restore OPERATION's source, caller state and primitive pixels."
  (setq operation (ebox-geometry--operation-active-operation operation))
  (when (ebox-geometry--operation-staged-p operation)
    (ebox-source--update-slots-rollback
     (ebox-geometry--operation-source-slots operation))
    (ebox-interaction--geometry-rollback (ebox-geometry--interaction operation))
    (let ((report (ebox-geometry--operation-report operation)))
      (plist-put report :revision (ebox-geometry--operation-old-report-revision operation))
      (plist-put report :publication (ebox-geometry--operation-old-report-publication operation)))
    (let ((state (ebox-geometry--operation-state operation)))
      (plist-put state :runtime-revision
                 (ebox-geometry--operation-old-revision operation))
      (plist-put state :last-update-report
                 (ebox-geometry--operation-old-report operation)))
    (when (ebox-geometry--operation-rollback operation)
      (funcall (ebox-geometry--operation-rollback operation))))
  (setf (ebox-geometry--operation-staged-p operation) nil))

(defun ebox-geometry--accept (operation _report)
  "Retire OPERATION's generic derived geometry after successful staging."
  (setq operation (ebox-geometry--operation-active-operation operation))
  (ebox-interaction--geometry-accept (ebox-geometry--interaction operation))
  (let ((state (ebox-geometry--operation-state operation)))
    ;; These proofs describe the old published fragment coordinates.  Source
    ;; and object identity remain authoritative; a later general publication
    ;; must reconstruct its exact geometry proof instead of reusing it.
    (dolist (key '(:layout-snapshots :layout-fragments :render-signature-cache))
      (when (hash-table-p (plist-get state key))
        (clrhash (plist-get state key))))
    (dolist (key '(:surface-owned-ranges :surface-fragments
                                         :native-render-fragment-template :native-committed-fragment-template
                                         :native-committed-owned-ranges :layout-snapshots-complete-p
                                         :layer-composition-cache))
      (when (plist-member state key) (plist-put state key nil)))))

(defun ebox-geometry--root-program (state node &optional prior-routes)
  "Return a compiled containing-plane route for positioned NODE in STATE.
Admission is conservative: anchors, portals and scroll producers require
additional prepared dependencies before they can use imperative execution."
  (let* ((root (plist-get state :root-node))
         (parents (plist-get state :parent-table))
         (id (plist-get node :node-id))
         (root-id (plist-get root :node-id))
         (cache (plist-get state :layer-composition-cache))
         (nodes (plist-get state :node-table)))
    (when (and (eq (plist-get node :position) 'absolute)
               (not (plist-get state :root-portals-p))
               (not (plist-get state :scroll-region-ids))
               (hash-table-p cache))
      (let ((child-id id) (host-id (ebox-runtime-index-get id parents))
            routes (valid t) previous)
        (while (and host-id valid)
          (let* ((host (ebox-runtime-index-get host-id nodes))
                 (entry (gethash (cons host-id 'final) cache))
                 (program (and entry (ebox-layer--program-prepare entry host)))
                 (target (and program
                              (gethash child-id (ebox-layer--program-targets program))))
                 first-row last-row)
            (setq valid
                  (and target (> (length target) 0)
                       (not (cl-some
                             (lambda (record)
                               (plist-get (plist-get record :node) :anchor))
                             (plist-get entry :records)))))
            (when valid
              (when previous
                (dotimes (offset (length target))
                  (let* ((record (aref (ebox-layer--program-records program)
                                       (aref target offset)))
                         (row (plist-get record :source-row)))
                    (unless (and (integerp row)
                                 (= 0 (plist-get record :source-start)))
                      (setq valid nil))
                    (when (integerp row)
                      (setq first-row (if first-row (min first-row row) row)
                            last-row (if last-row (max last-row row) row)))))
                (when (and valid (null (ebox-geometry--route-source-samples previous)))
                  (setf (ebox-geometry--route-lines previous)
                        (make-vector (1+ (- last-row first-row)) nil))))
              (when valid
                (let* ((prior (and prior-routes
                                   (cl-find host-id prior-routes
                                            :key (lambda (route)
                                                   (plist-get (ebox-geometry--route-wrapper route) :node-id))
                                            :test #'equal)))
                       (reuse (and prior
                                   (= (ebox-layer--program-width program)
                                      (ebox-layer--program-width (ebox-geometry--route-program prior)))
                                   (= (ebox-layer--program-height program)
                                      (ebox-layer--program-height (ebox-geometry--route-program prior)))))
                       (route (if reuse (copy-ebox-geometry--route prior)
                                (ebox-geometry--make-route))))
                  (setf (ebox-geometry--route-program route) program
                        (ebox-geometry--route-target route) target
                        (ebox-geometry--route-wrapper route) (ebox-geometry--wrapper host)
                        (ebox-geometry--route-content-offset route)
                        (+ (floor (ebox-get host :margin-top-height))
                           (floor (ebox-get host :padding-top-height)))
                        (ebox-geometry--route-first-row route) first-row
                        (ebox-geometry--route-refresh-p route) reuse)
                  (push route routes)
                  (setq previous route child-id host-id
                        host-id (unless (equal host-id root-id)
                                  (ebox-runtime-index-get host-id parents))))))))
        (when (and valid routes (equal child-id root-id))
          (vconcat (nreverse routes)))))))

(defun ebox-geometry--remapping-current-p (expected)
  "Compare current measurement remappings with cold EXPECTED without copying.
Like the ordinary display signature, ignore Ebox's paint-only face slots."
  (let ((current (and (boundp 'face-remapping-alist) face-remapping-alist))
        (same t))
    (while (and current same)
      (let* ((entry (car current)) (face (car-safe entry)))
        (unless (and (symbolp face)
                     (string-match-p "\\`ebox-paint-slot-" (symbol-name face)))
          (if (and expected (equal entry (car expected)))
              (setq expected (cdr expected))
            (setq same nil))))
      (setq current (cdr current)))
    (and same (null expected))))

(defun ebox-geometry--display-current-p (operation)
  "Compare OPERATION's cold display snapshot without constructing a signature.
Fields follow `ebox--display-signature-for-frame'; buffer-local facts are
read in the owning buffer even when the public caller uses another buffer."
  (let ((snapshot (ebox-geometry--operation-display-snapshot operation))
        (buffer (ebox-geometry--operation-buffer operation))
        (frame (ebox-geometry--operation-frame-font-frame operation)))
    (and (vectorp snapshot) (buffer-live-p buffer) (frame-live-p frame)
         (with-current-buffer buffer
           (and (eq frame (aref snapshot 0))
                (equal (frame-parameter frame 'font) (aref snapshot 1))
                (equal (frame-parameter frame 'font-backend) (aref snapshot 2))
                (equal (frame-parameter frame 'line-spacing) (aref snapshot 3))
                (equal (face-attribute 'default :family frame t) (aref snapshot 4))
                (equal (face-attribute 'default :height frame t) (aref snapshot 5))
                (equal (face-attribute 'default :weight frame t) (aref snapshot 6))
                (equal (face-attribute 'default :slant frame t) (aref snapshot 7))
                (equal (face-attribute 'default :width frame t) (aref snapshot 8))
                (ebox-geometry--remapping-current-p (aref snapshot 9))
                (equal (and (boundp 'text-scale-mode-amount) text-scale-mode-amount)
                       (aref snapshot 10))
                (equal (and (boundp 'text-scale-mode-step) text-scale-mode-step)
                       (aref snapshot 11)))))))

;;;###autoload
(defun ebox-geometry-prepare (buffer-or-name host-ref properties
                                             &optional stage rollback after-commit)
  "Prepare BUFFER-OR-NAME HOST-REF for fixed geometry PROPERTIES.
Return an opaque operation, or nil when its output dependencies cannot yet
be compiled.  HOST-REF has the same ownership and lifetime as
`ebox-host-ref-bounds'; a semantic ID also resolves in the target buffer.
PROPERTIES is a vector or list of geometry keywords.
The cold preparation owns all placement and rollback storage.  STAGE and
ROLLBACK are paired zero-argument callbacks; AFTER-COMMIT is called only after
acceptance.  Preparation itself does not advance the publication revision."
  (unless (and (or (listp properties) (vectorp properties))
               (or (null stage) (functionp stage))
               (or (null rollback) (functionp rollback))
               (eq (null stage) (null rollback))
               (or (null after-commit) (functionp after-commit)))
    (user-error "Invalid Ebox prepared geometry arguments"))
  (when (ebox-transaction-active-p)
    (user-error "Ebox geometry preparation requires a settled publication"))
  (catch 'ebox-geometry-unsupported
    (let* ((buffer (ebox--host-ref-buffer buffer-or-name))
           (state (and buffer (ebox--buffer-render-state buffer)))
           (display-window (and buffer (get-buffer-window buffer t)))
           (display-frame (if display-window (window-frame display-window) (selected-frame)))
           (display-signature
            (and state (with-current-buffer buffer
                         (ebox--display-signature-for-frame display-frame))))
           (node (and state
                      (equal display-signature (plist-get state :display-signature))
                      (or (ebox--host-ref-node buffer host-ref)
                          (and (ebox-source-semantic-id-p host-ref)
                               (with-current-buffer buffer
                                 (ignore-errors
                                   (nth 2 (ebox--region-update-geometry-target host-ref))))))))
           (surface (and buffer (ebox-surface--live-buffer-surface buffer)))
           (keys (vconcat properties))
           (session (and node surface (eq (plist-get node :position) 'absolute)
                         (with-current-buffer buffer
                           (and (ebox-geometry--session-valid-p ebox-geometry--session)
                                (gethash (plist-get node :node-id)
                                         (ebox-layer--program-targets
                                          (ebox-geometry--operation-program ebox-geometry--session)))
                                ebox-geometry--session))))
           (prior (and (not session) node surface
                       (with-current-buffer buffer
                         (let ((old ebox-geometry--session))
                           (and (ebox-geometry--operation-p old)
                                (eq surface (ebox-geometry--operation-surface old))
                                (plist-get state :geometry-topology-generation)
                                (eq (plist-get state :geometry-topology-generation)
                                    (plist-get (ebox-geometry--operation-state old) :geometry-topology-generation))
                                (eq (ebox-geometry--operation-stylesheet old) ebox-style-stylesheet)
                                (= (ebox-geometry--operation-stylesheet-epoch old) ebox-style--stylesheet-epoch)
                                (equal (plist-get state :display-signature)
                                       (plist-get (ebox-geometry--operation-state old) :display-signature))
                                old)))))
           (routes (or (and session (ebox-geometry--operation-routes session))
                       (and node surface (ebox-geometry--root-program
                                          state node (and prior (ebox-geometry--operation-routes prior))))))
           (program (and routes (ebox-geometry--route-program (aref routes 0)))))
      (dotimes (index (length keys))
        (unless (memq (aref keys index) ebox--region-geometry-properties)
          (user-error "Ebox property is not geometry: %S" (aref keys index)))
        (when (cl-position (aref keys index) keys :end index)
          (user-error "Ebox prepared geometry properties must be unique")))
      (when program
        (let* ((units (make-vector (length keys) nil))
               (fixed (make-vector (length keys) nil))
               (target (gethash (plist-get node :node-id)
                                (ebox-layer--program-targets program)))
               (containing-box (ebox-geometry--route-wrapper (aref routes 0)))
               (x-factor 1) (supported (and target (> (length target) 0))))
          (dotimes (index (length keys))
            (let* ((key (aref keys index)) (value (ebox-get node key)))
              (aset fixed index (copy-tree value))
              (cond
               ((eq key :left)
                (if (and (consp value) (memq (car value) '(px ch))
                         (numberp (cadr value)))
                    (progn
                      (aset units index (car value))
                      (setq x-factor (if (eq (car value) 'px) 1
                                       (ebox--size-pixels '(ch 1) containing-box 'width))))
                  (setq supported nil)))
               ((eq key :top)
                (if (and (consp value) (eq (car value) 'lh)
                         (numberp (cadr value)))
                    (aset units index 'lh)
                  (setq supported nil)))
               ((eq key :z-index)
                (unless (integerp value) (setq supported nil))))))
          (when (and supported (ebox-geometry--inline-slots-p state node keys))
            (unless (plist-get state :geometry-topology-generation)
              (plist-put state :geometry-topology-generation (list 'ebox/geometry-topology)))
            (let* ((source-slots
                    (ebox-source--update-slots-prepare
                     (plist-get state :source-index) node keys))
                   (operation
                    (and source-slots
                         (if session (copy-ebox-geometry--operation session)
                           (ebox-geometry--make-operation
                            :buffer buffer :surface surface :state state :node node
                            :program program :routes routes
                            :stylesheet ebox-style-stylesheet
                            :stylesheet-epoch ebox-style--stylesheet-epoch
                            :region-table (copy-hash-table (plist-get state :region-box-table))
                            :scroll-table (make-hash-table :test #'equal)
                            :viewport-cache (make-hash-table :test #'eq)
                            :content-cache (make-hash-table :test #'eq))))))
              (when operation
                (setf (ebox-geometry--operation-session operation) (or session operation)
                      (ebox-geometry--operation-node operation) node
                      (ebox-geometry--operation-properties operation) keys
                      (ebox-geometry--operation-units operation) units
                      (ebox-geometry--operation-values operation)
                      (vconcat (mapcar #'copy-tree (append fixed nil)))
                      (ebox-geometry--operation-source-slots operation) source-slots
                      (ebox-geometry--operation-target operation) target
                      (ebox-geometry--operation-x-factor operation) x-factor
                      (ebox-geometry--operation-stage operation) stage
                      (ebox-geometry--operation-rollback operation) rollback
                      (ebox-geometry--operation-after-commit operation) after-commit
                      (ebox-geometry--operation-report operation)
                      (list :strategy 'owner-rerender :projection-kind 'prepared-geometry
                            :dirty-kinds '(geometry) :prepared-geometry-p t
                            :revision 0 :publication nil))
                (plist-put node :ebox-source-handle
                           (ebox-source--update-slots-handle source-slots))
                (plist-put state :source-index
                           (ebox-source--update-slots-index source-slots))
                (setf (ebox-geometry--operation-interaction (or session operation))
                      (ebox-interaction--geometry-prepare buffer state surface))
                (unless session
                  (let ((window display-window) (frame display-frame))
                    (setf (ebox-geometry--operation-frame-window operation) window
                          (ebox-geometry--operation-frame-font-frame operation) frame
                          (ebox-geometry--operation-display-snapshot operation)
                          (vconcat display-signature)
                          (ebox-geometry--operation-frame-char-width operation) (frame-char-width frame)
                          (ebox-geometry--operation-frame-char-height operation) (frame-char-height frame)
                          (ebox-geometry--operation-window-width operation) (and window (window-pixel-width window))
                          (ebox-geometry--operation-window-height operation) (and window (window-pixel-height window))))
                  (let* ((wrapper-output (or (ebox-geometry--render operation)
                                             (throw 'ebox-geometry-unsupported nil)))
                         (_settled
                          (dotimes (index (length routes))
                            (ebox-layer--program-settle
                             (ebox-geometry--route-program (aref routes index)) t)))
                         (rasters
                          (cons wrapper-output
                                (cl-loop for route across routes append
                                         (append (ebox-geometry--route-lines route)
                                                 (ebox-layer--program-strings
                                                  (ebox-geometry--route-program route))))))
                         (rows (ebox-geometry--route-lines (aref routes (1- (length routes)))))
                         (reused-projection
                          (and prior
                               (ebox-surface--geometry-mount-refresh
                                (ebox-geometry--operation-projection prior)
                                surface state rasters rows)
                               (ebox-geometry--operation-projection prior)))
                         (projection
                          (or reused-projection
                              (ebox-surface--geometry-mount-prepare
                               surface state rasters
                               (max 8 (* 2 (ebox-layer--program-height program)))
                               (cl-loop for route across routes collect
                                        (plist-get (ebox-geometry--route-wrapper route) :region-id)) rows))))
                    (setf (ebox-geometry--operation-projection operation) projection
                          (ebox-geometry--operation-frame operation)
                          (or (and reused-projection
                                   (ebox--pub-frame-refresh
                                    (ebox-geometry--operation-frame prior) state operation))
                              (ebox--pub-frame-prepare
                               surface (ebox-surface--geometry-mount-slots projection)
                               operation #'ebox-geometry--dispatch-stage #'ebox-geometry--dispatch-rollback
                               #'ebox-geometry--dispatch-accept)))))
                (with-current-buffer buffer
                  (setq ebox-geometry--session (or session operation)))
                operation))))))))

;;;###autoload
(defun ebox-geometry-valid-p (operation)
  "Return whether prepared OPERATION still owns its committed generation.
This bounded check does not traverse a component or Box tree."
  (and (ebox-geometry--operation-p operation)
       (buffer-live-p (ebox-geometry--operation-buffer operation))
       (eq (ebox-geometry--operation-state operation)
           (ebox--buffer-render-state (ebox-geometry--operation-buffer operation)))
       (ebox-source--update-slots-current-p
        (ebox-geometry--operation-source-slots operation)
        (plist-get (ebox-geometry--operation-state operation) :source-index))
       (ebox-geometry--session-valid-p (ebox-geometry--operation-session operation))))

(defun ebox-geometry--session-valid-p (operation)
  "Return whether the shared canvas OPERATION still owns its surface."
  (and (ebox-geometry--operation-p operation)
       (buffer-live-p (ebox-geometry--operation-buffer operation))
       (with-current-buffer (ebox-geometry--operation-buffer operation)
         (eq operation ebox-geometry--session))
       (eq (ebox-geometry--operation-state operation)
           (ebox--buffer-render-state (ebox-geometry--operation-buffer operation)))
       (eq (ebox-geometry--operation-stylesheet operation) ebox-style-stylesheet)
       (= (ebox-geometry--operation-stylesheet-epoch operation) ebox-style--stylesheet-epoch)
       (ebox-geometry--display-current-p operation)
       (let ((frame (ebox-geometry--operation-frame-font-frame operation))
             (window (ebox-geometry--operation-frame-window operation)))
         (and (= (frame-char-width frame) (ebox-geometry--operation-frame-char-width operation))
              (= (frame-char-height frame) (ebox-geometry--operation-frame-char-height operation))
              (or (null window)
                  (and (window-live-p window)
                       (eq (window-buffer window) (ebox-geometry--operation-buffer operation))
                       (= (window-pixel-width window) (ebox-geometry--operation-window-width operation))
                       (= (window-pixel-height window) (ebox-geometry--operation-window-height operation))))))
       (ebox--pub-frame-current-p (ebox-geometry--operation-frame operation))))

;;;###autoload
(defun ebox-geometry-apply (operation values)
  "Apply canonical geometry VALUES through prepared OPERATION.
VALUES is a caller-owned reusable vector in the prepared property order.
Return t for acceptance, or nil before mutation when preparation is stale or
a changed property needs the general update path.  Invalid values signal an
error.  Changed translation and stacking are currently compiled; unchanged
width/height bindings may accompany them.  Publication failure restores the
source, display, revision, primitive geometry and paired caller state."
  (if (and (ebox-geometry--operation-p operation)
           (ebox-surface-buffer-observer (ebox-geometry--operation-buffer operation)))
      (ebox-surface-call-with-observation
       (ebox-geometry--operation-buffer operation) 'prepared-geometry
       (lambda () (ebox-geometry--apply operation values)))
    (ebox-geometry--apply operation values)))

(defun ebox-geometry--apply (operation values)
  "Apply OPERATION VALUES without allocating unrequested observation state."
  (unless (ebox-geometry--operation-p operation)
    (signal 'wrong-type-argument (list 'ebox-geometry--operation-p operation)))
  (unless (and (vectorp values)
               (= (length values) (length (ebox-geometry--operation-properties operation))))
    (user-error "Ebox prepared geometry values must match the property vector"))
  (when (ebox-geometry-valid-p operation)
    (let* ((keys (ebox-geometry--operation-properties operation))
           (units (ebox-geometry--operation-units operation))
           (node (ebox-geometry--operation-node operation))
           (program (ebox-geometry--operation-program operation))
           (owned-values (ebox-geometry--operation-values operation))
           (supported t) (dx 0) (dy 0)
           (z (or (ebox-get node :z-index) 0)) result)
      (dotimes (index (length keys))
        (let* ((key (aref keys index)) (value (aref values index))
               (old (ebox-get node key)) (unit (aref units index)))
          (cond
           ((memq key '(:left :top))
            (unless (and (consp value) (eq (car value) unit)
                         (consp (cdr value)) (null (cddr value))
                         (ebox-size--finite-number-p (cadr value)))
              (user-error "Prepared Ebox geometry must retain its finite unit"))
            (unless (= (cadr value) (cadr old))
              (if (eq key :left)
                  (setq dx (* (- (cadr value) (cadr old))
                              (ebox-geometry--operation-x-factor operation)))
                (setq dy (- (floor (cadr value)) (floor (cadr old))))))
            (setcar (cdr (aref owned-values index)) (cadr value)))
           ((eq key :z-index)
            (unless (integerp value) (user-error "Ebox z-index must be an integer"))
            (aset owned-values index value)
            (setq z value))
           ((not (equal value old)) (setq supported nil)))))
      (when supported
        (setf (ebox-geometry--operation-staged-p operation) nil)
        (let ((session (ebox-geometry--operation-session operation)))
          (setf (ebox-geometry--operation-active-operation session) operation
                (ebox-geometry--operation-frame-stage session) #'ebox-geometry--stage
                (ebox-geometry--operation-frame-rollback session) #'ebox-geometry--rollback
                (ebox-geometry--operation-frame-accept session) #'ebox-geometry--accept))
        ;; No-op values still stage paired semantic state.  The same bounded
        ;; publisher validates callbacks and preserves atomic failure rules.
        (ebox-layer--program-translate
         program (ebox-geometry--operation-target operation) dx dy z)
        (unwind-protect
            (let* ((rendered (ebox-incremental--with-phase 'layout
                                                           (ebox-geometry--render operation)))
                   (root-route (aref (ebox-geometry--operation-routes operation)
                                     (1- (length (ebox-geometry--operation-routes operation)))))
                   (count (and rendered (ebox-incremental--with-phase 'projection
                                                                      (ebox-surface--geometry-mount-fill
                                                                       (ebox-geometry--operation-projection operation) rendered
                                                                       (ebox-geometry--route-lines root-route)
                                                                       (ebox-geometry--route-dirty root-route))))))
              (when (and count
                         (ebox-interaction--geometry-ready-p
                          (ebox-geometry--interaction operation)
                          (ebox-surface--geometry-mount-slots
                           (ebox-geometry--operation-projection operation))
                          count rendered))
                (setq result
                      (ebox-incremental--with-phase 'transaction
                                                    (ebox--pub-frame-publish
                                                     (ebox-geometry--operation-frame operation) rendered
                                                     (ebox-geometry--operation-state operation) count
                                                     (ebox-geometry--route-damage root-route)
                                                     (ebox-geometry--route-damage-count root-route))))))
          (let ((routes (ebox-geometry--operation-routes operation)))
            (dotimes (index (length routes))
              (let ((route (aref routes index)))
                (ebox-layer--program-settle (ebox-geometry--route-program route) (and result t))
                (ebox-geometry--settle-wrapper route (and result t))))))
        (when result
          (setf (ebox-geometry--operation-staged-p operation) nil)
          (when (ebox-geometry--operation-after-commit operation)
            (funcall (ebox-geometry--operation-after-commit operation)))
          t)))))

(provide 'ebox-geometry)
;;; ebox-geometry.el ends here
