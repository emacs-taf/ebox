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
  program target region-table scroll-table scroll-timers projection frame values
  scroll-before-table scroll-before-regions scroll-before-global scroll-pending-p scroll-staged-p
  viewport-cache content-cache
  routes interaction session active-operation frame-stage frame-rollback frame-accept
  interaction-stage interaction-rollback interaction-accept
  x-factor old-revision old-report report
  old-report-revision old-report-publication
  stylesheet stylesheet-epoch frame-window frame-font-frame display-snapshot
  frame-char-width frame-char-height window-width window-height
  stage rollback after-commit staged-p crop)

(cl-defstruct (ebox-geometry--route (:constructor ebox-geometry--make-route))
  "One fixed wrapper and its containing plane in a compiled output route."
  program target wrapper first-row lines content-offset
  saved-lines dirty prefixes suffixes properties signature transforms variants
  output-spine offsets damage damage-count template-key refresh-p
  paint surface-properties)

(defvar-local ebox-geometry--session nil
  "One shared prepared canvas and publication frame for the mounted surface.")

(defsubst ebox-geometry--interaction (operation)
  "Return OPERATION's shared current interaction capability."
  (ebox-geometry--operation-interaction
   (ebox-geometry--operation-session operation)))

(defvar ebox-geometry--admission-detail nil
  "Dynamically bound one-cell sink for the first cold admission failure.
Its value contains only bounded scalar facts, never retained runtime data.")

(defvar ebox-geometry--admission-depth nil
  "Containing-plane depth during cold wrapper compilation, starting at zero.")

(defun ebox-geometry--record-admission (phase reason &rest facts)
  "Record the first cold PHASE rejection REASON and bounded scalar FACTS."
  (when (and (consp ebox-geometry--admission-detail)
             (null (car ebox-geometry--admission-detail)))
    (setcar ebox-geometry--admission-detail
            (append (list :phase phase :reason reason)
                    (when ebox-geometry--admission-depth
                      (list :depth ebox-geometry--admission-depth))
                    facts))))

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
                       (and (memq property '(:left :top :width :height :z-index :color :background-color :bgcolor :font-weight))
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

(defun ebox-geometry--signature-hash (key)
  "Hash every element of the sequence KEY.
`sxhash-equal' reads only the first few elements of a vector or list, and a
property signature's leading values are mostly nil, so a plain `equal' table
degenerates into long bucket scans of nested property values."
  (let ((hash 0))
    (if (vectorp key)
        (dotimes (index (length key))
          (setq hash (logand (logxor (ash hash 5) (ash hash -50)
                                     (sxhash-equal (aref key index)))
                             #xffffffffffffff)))
      (while (consp key)
        (setq hash (logand (logxor (ash hash 5) (ash hash -50)
                                   (sxhash-equal (car key)))
                           #xffffffffffffff)
              key (cdr key))))
    hash))

(define-hash-table-test 'ebox-geometry-signature #'equal #'ebox-geometry--signature-hash)

(defconst ebox-geometry--decoration-properties
  '(face mouse-face ebox--hover-style front-sticky rear-nonsticky
    ebox-content ebox-content-owner ebox-content-owners ebox-bt ebox-bb)
  "Properties the wrapper paint helpers may add to a primitive run.")

(defun ebox-geometry--compile-wrapper (route &optional inner-properties)
  "Compile ROUTE's fixed chrome and its content-property schema.
The generic Box renderer is used only here, before any geometry execution.
INNER-PROPERTIES is the enclosed route's output schema.  Every property that
the program's primitives, the enclosed route or the paint helpers can carry
joins the schema; the transformation of one property combination compiles
when a dirty row first presents it (`ebox-geometry--compile-signature'), so
preparing a wrapper no longer enumerates every combination up front."
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
                        (ebox-geometry--route-properties route)))
         (old-properties (and retained (ebox-geometry--route-properties route)))
         (keys (if retained (append old-properties nil)
                 (copy-sequence '(face font-lock-face ebox-content ebox-content-owner ebox-content-owners
                                       ebox-bt ebox-bb))))
         properties output rows)
    (unless (eq (ebox-get wrapper :text-align) 'left)
      (ebox-geometry--record-admission 'wrapper 'text-alignment
                                      :text-align (ebox-get wrapper :text-align))
      (throw 'ebox-geometry-unsupported nil))
    (unless (eq (ebox-get wrapper :visibility) 'visible)
      (ebox-geometry--record-admission 'wrapper 'visibility
                                      :visibility (ebox-get wrapper :visibility))
      (throw 'ebox-geometry-unsupported nil))
    (let ((content-height (ebox--content-height wrapper height content)))
      (unless (= height content-height)
        (ebox-geometry--record-admission
         'wrapper 'content-height :plane-height height :content-height content-height
         :overflow (ebox-get wrapper :overflow))
        (throw 'ebox-geometry-unsupported nil)))
    (if retained
        (setq rows (copy-sequence (ebox-geometry--route-lines route)))
      (plist-put wrapper :content content)
      (setq output (ebox--render-layout wrapper)
            rows (vconcat (ebox-string-lines output))))
    (when (and (ebox-geometry--route-lines route)
               (/= (length rows) (length (ebox-geometry--route-lines route))))
      (ebox-geometry--record-admission
       'wrapper 'retained-row-count :actual-rows (length rows)
       :expected-rows (length (ebox-geometry--route-lines route)))
      (throw 'ebox-geometry-unsupported nil))
    (unless (= (length rows)
               (+ height offset (floor (ebox-get wrapper :padding-bottom-height))
                  (floor (ebox-get wrapper :margin-bottom-height))))
      (ebox-geometry--record-admission
       'wrapper 'output-row-count :actual-rows (length rows)
       :plane-height height :content-offset offset
       :bottom-padding (floor (ebox-get wrapper :padding-bottom-height))
       :bottom-margin (floor (ebox-get wrapper :margin-bottom-height)))
      (throw 'ebox-geometry-unsupported nil))
    ;; The neutral fill primitive and every program string contribute their
    ;; source keys; clipping replacements keep a subset of those keys.
    (dolist (string (cons " " (ebox-layer--program-strings program)))
      (let ((position 0))
        (while (< position (length string))
          (let ((tail (text-properties-at position string)))
            (while tail
              (unless (memq (car tail) ebox-geometry--pass-through-properties)
                (cl-pushnew (car tail) keys))
              (setq tail (cddr tail))))
          (setq position (next-property-change position string (length string))))))
    (dotimes (index (length inner-properties))
      (cl-pushnew (aref inner-properties index) keys))
    (let ((tail surface-properties))
      (while tail (cl-pushnew (car tail) keys) (setq tail (cddr tail))))
    (dolist (key ebox-geometry--decoration-properties) (cl-pushnew key keys))
    (setq properties (vconcat keys))
    (let* ((same-schema (and retained (equal properties old-properties)))
           (tables (if same-schema (ebox-geometry--route-transforms route) (make-vector 8 nil)))
           (prefixes (if retained (ebox-geometry--route-prefixes route) (make-vector height nil)))
           (suffixes (if retained (ebox-geometry--route-suffixes route) (make-vector height nil)))
           (variants (if retained (ebox-geometry--route-variants route) (make-vector height 0))))
      (dotimes (row height)
        (let ((variant (+ (if (and top-p (= row 0)) 2 0)
                          (if (and bottom-p (= row (1- height))) 4 0))))
          (aset variants row variant)
          (dolist (direct '(0 1))
            (unless (aref tables (+ variant direct))
              (aset tables (+ variant direct)
                    (make-hash-table :test 'ebox-geometry-signature))))))
      (unless retained
        (dotimes (row height)
          (let* ((line (aref rows (+ offset row)))
                 (end (- (length line) right-count)))
            (unless (<= left-count end)
              (ebox-geometry--record-admission
               'wrapper 'horizontal-chrome :row row :characters (length line)
               :left-characters left-count :right-characters right-count)
              (throw 'ebox-geometry-unsupported nil))
            (aset prefixes row (substring line 0 left-count))
            (aset suffixes row (substring line end)))))
      (setf (ebox-geometry--route-lines route) rows
            (ebox-geometry--route-saved-lines route) (make-vector (length rows) nil)
            (ebox-geometry--route-dirty route) (make-vector (length rows) nil)
            (ebox-geometry--route-prefixes route) prefixes
            (ebox-geometry--route-suffixes route) suffixes
            (ebox-geometry--route-properties route) properties
            (ebox-geometry--route-signature route) (make-vector (length keys) nil)
            (ebox-geometry--route-transforms route) tables
            (ebox-geometry--route-variants route) variants
            (ebox-geometry--route-output-spine route) (make-list (length rows) nil)
            (ebox-geometry--route-offsets route) (make-vector (1+ (length rows)) 0)
            (ebox-geometry--route-damage route) (make-vector (* 4 (length rows)) 0)
            (ebox-geometry--route-template-key route) template-key
            (ebox-geometry--route-refresh-p route) nil
            (ebox-geometry--route-paint route) (list region color background
                                                     (ebox-get wrapper :border-top-color)
                                                     (ebox-get wrapper :border-bottom-color))
            (ebox-geometry--route-surface-properties route) surface-properties)
      (when retained
        (dotimes (row height)
          (aset rows (+ offset row)
                (ebox-geometry--render-wrapper-row
                 route row (aref (ebox-layer--program-rows program) row))))))
    output))

(defun ebox-geometry--compile-signature (route variant source position table)
  "Compile ROUTE's VARIANT transformation for SOURCE's run at POSITION.
Paint one probe character through the same helpers the generic renderer
uses, store the property changes in TABLE under the run's signature and
return them.  A run whose source or painted properties fall outside the
compiled schema declines the prepared operation."
  (let* ((properties (ebox-geometry--route-properties route))
         (paint (ebox-geometry--route-paint route))
         (region (nth 0 paint)) (color (nth 1 paint)) (background (nth 2 paint))
         (surface-properties (ebox-geometry--route-surface-properties route))
         (tail (text-properties-at position source))
         props)
    (while tail
      (let ((property (car tail)))
        (unless (memq property ebox-geometry--pass-through-properties)
          (unless (cl-position property properties) (throw 'ebox-geometry-unsupported nil))
          (setq props (cons property (cons (cadr tail) props)))))
      (setq tail (cddr tail)))
    (let* ((probe (apply #'propertize "x" props))
           ;; A nonempty child-content sentinel models rows whose other
           ;; pieces already carry content, without filling this piece's
           ;; intentionally empty direct-content property.
           (probe (if (= 0 (logand variant 1))
                      (concat (propertize "x" 'ebox-content 'ebox/geometry-sentinel) probe)
                    probe))
           (owned (ebox--propertize-content-line probe region 0 " "))
           (painted (ebox--propertize-colors owned color background)))
      (when (/= 0 (logand variant 2))
        (setq painted (ebox--propertize-overline painted (nth 3 paint)))
        (put-text-property 0 (length painted) 'ebox-bt region painted))
      (when (/= 0 (logand variant 4))
        (setq painted (ebox--propertize-underline painted (nth 4 paint)))
        (put-text-property 0 (length painted) 'ebox-bb region painted))
      (ebox--apply-surface-properties painted surface-properties)
      (let ((last (1- (length painted))) changes)
        (setq tail (text-properties-at last painted))
        (while tail
          (unless (or (memq (car tail) ebox-geometry--pass-through-properties)
                      (cl-position (car tail) properties))
            (throw 'ebox-geometry-unsupported nil))
          (setq tail (cddr tail)))
        (dotimes (index (length properties))
          (let ((property (aref properties index)))
            (unless (equal (get-text-property position property source)
                           (get-text-property last property painted))
              (setq changes (cons property (cons (get-text-property last property painted) changes))))))
        (puthash (copy-sequence (ebox-geometry--property-signature
                                 source position properties (ebox-geometry--route-signature route)))
                 (or changes 'ebox/unchanged) table)))))

(defun ebox-geometry--render-wrapper-row (route row source)
  "Execute ROUTE's ROW wrapper on primitive SOURCE pixels.
Property combinations compile on first use and stay in the route's tables."
  (let* ((direct (not (text-property-not-all 0 (length source) 'ebox-content nil source)))
         (variant (+ (aref (ebox-geometry--route-variants route) row) (if direct 1 0)))
         (table (aref (ebox-geometry--route-transforms route) variant))
         (properties (ebox-geometry--route-properties route))
         (signature (ebox-geometry--route-signature route))
         (result (copy-sequence source))
         (position 0) (limit (length source)))
    (while (< position limit)
      (let* ((next (next-property-change position source limit))
             (changes (or (gethash (ebox-geometry--property-signature source position properties signature) table)
                          (ebox-geometry--compile-signature route variant source position table))))
        (unless (eq changes 'ebox/unchanged)
          (add-text-properties position next changes result))
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
           (ebox--scroll-idle-prefetch-timers (ebox-geometry--operation-scroll-timers operation))
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
                (let ((ebox-geometry--admission-depth index))
                  (ebox-geometry--compile-wrapper
                   route (and (> index 0) (ebox-geometry--route-properties (aref routes (1- index))))))
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

(defun ebox-geometry--scroll-begin (scene)
  "Prepare SCENE's private scroll bank before any raster is re-rendered.
The current global entries include any completed idle prefix work.  Copy their
metadata cells; retained lines stay read-only and ordinary rendering owns new
producer state.  Placement-only frames never enter this path."
  (unless (ebox-geometry--operation-scroll-pending-p scene)
    (let* ((state (ebox-geometry--operation-state scene))
           (before (plist-get state :scroll-state-table))
           (regions (plist-get state :scroll-region-ids))
           (candidate (ebox-geometry--operation-scroll-table scene))
           (global (ebox-geometry--operation-scroll-before-global scene)))
      (when (eq candidate before)
        (error "Prepared scroll candidate aliases the accepted state"))
      (clrhash candidate)
      (clrhash global)
      (dolist (region regions)
        (when-let* ((current (or (gethash region ebox--scroll-global-state)
                                (and before (gethash region before)))))
          (puthash region (gethash region ebox--scroll-global-state) global)
          (puthash region (copy-sequence current) candidate)))
      (setf (ebox-geometry--operation-scroll-before-table scene) before
            (ebox-geometry--operation-scroll-before-regions scene) regions
            (ebox-geometry--operation-scroll-pending-p scene) t
            (ebox-geometry--operation-scroll-staged-p scene) nil))))

(defun ebox-geometry--scroll-stage (scene)
  "Install SCENE's candidate scroll bank with the prepared publication.
The publisher's rollback callback restores both runtime and global entries."
  (when (ebox-geometry--operation-scroll-pending-p scene)
    (let* ((state (ebox-geometry--operation-state scene))
           (candidate (ebox-geometry--operation-scroll-table scene))
           (global (ebox-geometry--operation-scroll-before-global scene))
           (buffer (ebox-geometry--operation-buffer scene))
           regions)
      (setf (ebox-geometry--operation-scroll-staged-p scene) t)
      (dolist (region (ebox-geometry--operation-scroll-before-regions scene))
        (remhash region ebox--scroll-global-state))
      (maphash
       (lambda (region scroll)
         (unless (gethash region global)
           (puthash region (gethash region ebox--scroll-global-state) global))
         (plist-put scroll :buffer buffer)
         (puthash region scroll ebox--scroll-global-state)
         (push region regions))
       candidate)
      (plist-put state :scroll-state-table candidate)
      (plist-put state :scroll-region-ids regions))))

(defun ebox-geometry--scroll-rollback (scene)
  "Restore SCENE's accepted scroll state after a rejected publication."
  (when (ebox-geometry--operation-scroll-staged-p scene)
    (let ((state (ebox-geometry--operation-state scene))
          (buffer (ebox-geometry--operation-buffer scene)))
      (maphash (lambda (region _scroll) (remhash region ebox--scroll-global-state))
               (ebox-geometry--operation-scroll-table scene))
      ;; Buffer teardown is authoritative even when it happens in STAGE.
      (when (and (buffer-live-p buffer)
                 (eq (ebox-geometry--operation-surface scene)
                     (ebox-surface--live-buffer-surface buffer)))
        (maphash (lambda (region scroll)
                   (if scroll (puthash region scroll ebox--scroll-global-state)
                     (remhash region ebox--scroll-global-state)))
                 (ebox-geometry--operation-scroll-before-global scene))
        (plist-put state :scroll-state-table (ebox-geometry--operation-scroll-before-table scene))
        (plist-put state :scroll-region-ids (ebox-geometry--operation-scroll-before-regions scene)))
      (setf (ebox-geometry--operation-scroll-staged-p scene) nil))))

(defun ebox-geometry--scroll-settle (scene accepted)
  "Retire SCENE's scroll journal after the publisher has returned ACCEPTED."
  (when (ebox-geometry--operation-scroll-pending-p scene)
    (if (not accepted) (ebox-geometry--scroll-rollback scene)
      (let ((before (ebox-geometry--operation-scroll-before-table scene))
            (state (ebox-geometry--operation-state scene)))
        ;; The newly accepted table is now public.  Reuse only the retired
        ;; table as the next candidate bank, never the accepted metadata.
        (setf (ebox-geometry--operation-scroll-table scene)
              (or before (make-hash-table :test #'equal)))
        (dolist (region (ebox-geometry--operation-scroll-before-regions scene))
          (unless (gethash region (plist-get state :scroll-state-table))
            (ebox--scroll-cancel-idle-prefetch region)))
        (dolist (region (plist-get state :scroll-region-ids))
          (ebox--scroll-schedule-idle-prefetch region))))
    (setf (ebox-geometry--operation-scroll-before-table scene) nil
          (ebox-geometry--operation-scroll-before-regions scene) nil
          (ebox-geometry--operation-scroll-pending-p scene) nil
          (ebox-geometry--operation-scroll-staged-p scene) nil)
    (clrhash (ebox-geometry--operation-scroll-before-global scene))))

(defun ebox-geometry--scroll-admission-facts (state node)
  "Summarize STATE's scroll ancestry relative to positioned NODE."
  (let ((regions (plist-get state :scroll-region-ids))
        (table (plist-get state :region-box-table))
        (parents (plist-get state :parent-table))
        (nodes (plist-get state :node-table))
        (target (plist-get node :node-id))
        (ancestors (make-hash-table :test #'equal))
        (ancestor-count 0) (descendant-count 0) (positioned-count 0)
        (unknown-count 0))
    (let ((id target))
      (while id
        (puthash id t ancestors)
        (setq id (ebox-runtime-index-get id parents))))
    (dolist (region regions)
      (let* ((scroll (and (hash-table-p table) (gethash region table)))
             (id (plist-get scroll :node-id))
             under-target positioned)
        (if (null id) (setq unknown-count (1+ unknown-count))
          (when (gethash id ancestors) (setq ancestor-count (1+ ancestor-count)))
          (while id
            (when (equal id target) (setq under-target t))
            (when (eq (plist-get (ebox-runtime-index-get id nodes) :position) 'absolute)
              (setq positioned t))
            (setq id (ebox-runtime-index-get id parents)))
          (when under-target (setq descendant-count (1+ descendant-count)))
          (when positioned (setq positioned-count (1+ positioned-count))))))
    (list :scroll-count (length regions) :ancestor-scroll-count ancestor-count
          :target-scroll-count descendant-count :positioned-scroll-count positioned-count
          :unknown-scroll-count unknown-count)))

(defun ebox-geometry--root-program (state node &optional prior-routes fixed-portals-p)
  "Return a compiled containing-plane route for positioned NODE in STATE.
Admission is conservative: anchors, portals and scrollable containing planes
require additional prepared dependencies.  FIXED-PORTALS-P is the update
provider's proof that all members leave the retained root portals unchanged.
Scrollers inside retained rasters keep their content-relative state
independently of the raster's placement."
  (let* ((root (plist-get state :root-node))
         (parents (plist-get state :parent-table))
         (id (plist-get node :node-id))
         (root-id (plist-get root :node-id))
         (cache (plist-get state :layer-composition-cache))
         (nodes (plist-get state :node-table)))
    (cond
     ((not (eq (plist-get node :position) 'absolute))
      (ebox-geometry--record-admission 'route 'position))
     ((and (plist-get state :root-portals-p) (not fixed-portals-p))
      (ebox-geometry--record-admission 'route 'root-portals))
     ((not (hash-table-p cache))
      (ebox-geometry--record-admission 'route 'composition-cache)))
    (when (and (eq (plist-get node :position) 'absolute)
               (or (not (plist-get state :root-portals-p)) fixed-portals-p)
               (hash-table-p cache))
      (let ((child-id id) (host-id (ebox-runtime-index-get id parents))
            routes (valid t) previous (depth 0))
        (while (and host-id valid)
          (let* ((ebox-geometry--admission-depth depth)
                 (host (ebox-runtime-index-get host-id nodes))
                 (entry (gethash (cons host-id 'final) cache))
                 (program (and entry (ebox-layer--program-prepare entry host)))
                 (target (and program
                              (gethash child-id (ebox-layer--program-targets program))))
                 first-row last-row)
            (setq valid
                  (and target (> (length target) 0)
                       (not (member (plist-get host :region-id)
                                    (plist-get state :scroll-region-ids)))
                       (not (cl-some
                             (lambda (record)
                               (plist-get (plist-get record :node) :anchor))
                             (plist-get entry :records)))))
            (unless valid
              (let ((scroll-p (member (plist-get host :region-id)
                                      (plist-get state :scroll-region-ids))))
                (apply #'ebox-geometry--record-admission
                       'route (cond ((null entry) 'containing-plane)
                                    ((null program) 'composition-program)
                                    ((or (null target) (= (length target) 0)) 'target)
                                    (scroll-p 'scroll-containing-plane)
                                    (t 'anchor))
                       (and scroll-p (ebox-geometry--scroll-admission-facts state node)))))
            (when valid
              (when previous
                (dotimes (offset (length target))
                  (let* ((record (aref (ebox-layer--program-records program)
                                       (aref target offset)))
                         (row (plist-get record :source-row)))
                    (unless (and (integerp row)
                                 (= 0 (plist-get record :source-start)))
                      (ebox-geometry--record-admission
                       'route 'source-row-mapping
                       :record offset :source-row (and (integerp row) row)
                       :source-start (plist-get record :source-start))
                      (setq valid nil))
                    (when (integerp row)
                      (setq first-row (if first-row (min first-row row) row)
                            last-row (if last-row (max last-row row) row)))))
                (when (and valid (null (ebox-geometry--route-properties previous)))
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
                  (setq previous route child-id host-id depth (1+ depth)
                        host-id (unless (equal host-id root-id)
                                  (ebox-runtime-index-get host-id parents))))))))
        (unless (and valid routes (equal child-id root-id))
          (ebox-geometry--record-admission 'route 'root-route :depth depth))
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

(defun ebox-geometry--crop-candidate-p (node)
  "Whether NODE has fixed text and an opaque, undecorated clipping box.
This initial resize primitive excludes child layout, wrapping, alignment,
scrolling and box decorations rather than changing their normal semantics."
  (and (eq (plist-get node :ebox-kind) 'box)
       (eq (ebox--box-layout-kind node) 'normal)
       (eq (ebox-get node :position) 'absolute)
       (eq (ebox-get node :overflow) 'hidden)
       (eq (ebox-get node :wrap-mode) 'none)
       (eq (ebox-get node :text-align) 'left)
       (eq (ebox-get node :vertical-align) 'top)
       (stringp (ebox-get node :bgcolor))
       (not (member (ebox-get node :bgcolor) '("transparent" "unspecified-bg")))
       (equal (ebox-get node :min-width) '(px 0))
       (equal (ebox-get node :min-height) '(lh 0))
       (not (ebox-get node :max-width)) (not (ebox-get node :max-height))
       (cl-every (lambda (key) (zerop (or (ebox-get node key) 0)))
                 '(:padding-left-pixel :padding-right-pixel
                   :padding-top-height :padding-bottom-height
                   :margin-left-pixel :margin-right-pixel
                   :margin-top-height :margin-bottom-height
                   :border-left-pixel :border-right-pixel
                   :border-top-pixel :border-bottom-pixel :scroll-offset))
       (cl-every (lambda (child) (eq (plist-get child :ebox-kind) 'text))
                 (ebox-tree-node-children node))
       (let ((width (ebox-get node :width)) (height (ebox-get node :height)))
         (and (eq (car-safe width) 'px) (integerp (cadr width)) (> (cadr width) 0)
              (eq (car-safe height) 'lh) (integerp (cadr height)) (> (cadr height) 0)))))

(defun ebox-geometry--resize-program (program target descriptor width height)
  "Stage DESCRIPTOR's crop of TARGET in PROGRAM at WIDTH and HEIGHT.
Return nil before mutation when the size exceeds the prepared capacity."
  (when (and (integerp width) (integerp height) (> width 0) (> height 0)
             (<= width (aref descriptor 1)) (<= height (aref descriptor 2)))
    (ebox-layer--program-crop program target width height)
    t))

(defun ebox-geometry--prepare-crop (state route node)
  "Compile NODE's fixed-content crop in ROUTE without publishing anything.
Keep a single maximum raster, not a cache of rendered sizes.  Its capacity is
the containing plane.  Ordinary source/style/environment changes invalidate
the session; unsupported sizes are declined before mutation."
  (when (and (ebox-geometry--crop-candidate-p node)
             (ebox-incremental--static-style-bindings-p state))
    (let* ((old (ebox-geometry--route-program route))
           (width (ebox-layer--program-width old))
           (height (ebox-layer--program-height old))
           (current-width (cadr (ebox-get node :width)))
           (current-height (cadr (ebox-get node :height)))
           (targets (gethash (plist-get node :node-id) (ebox-layer--program-targets old)))
           (records (ebox-layer--program-records old))
           (first (and targets (> (length targets) 0) (aref records (aref targets 0))))
           (x (and first (- (plist-get first :x) (plist-get first :source-start))))
           (y (and first (- (plist-get first :y) (plist-get first :source-row))))
           (host (ebox-runtime-index-get
                  (plist-get (ebox-geometry--route-wrapper route) :node-id)
                  (plist-get state :node-table))))
      (when (and first host (integerp width) (integerp height)
                 (<= current-width width) (<= current-height height))
        (let* ((probe (copy-tree node))
               (ebox--render-source-index (plist-get state :source-index))
               (ebox--paint-origin-capture-p t)
               (_size (progn (plist-put probe :width (list 'px width))
                             (plist-put probe :height (list 'lh height))))
               (lines (vconcat (ebox-string-lines (ebox--render-ephemeral-static probe))))
               source program)
          (when (= (length lines) height)
            (dotimes (index (length records))
              (unless (cl-position index targets)
                (push (aref records index) source)))
            (dotimes (row height)
              (push (list :node node :x x :y (+ y row) :text (aref lines row)
                          :source-start 0 :source-end (if (< row current-height) current-width 0)
                          :source-row row) source))
            (setq program
                  (ebox-layer--program-prepare
                   (list :width width :height height :records (nreverse source)
                         :rows (ebox-layer--program-rows old)) host))
            ;; The different internal row representation must reproduce the
            ;; accepted pixels before it may replace the old primitive plan.
            (ebox-layer--program-batch-begin program)
            (dotimes (row height) (ebox-layer--program-mark-row program row))
            (ebox-layer--program-batch-end program)
            (ebox-layer--program-render program t)
            (when (cl-loop for before across (ebox-layer--program-rows old)
                           for after across (ebox-layer--program-rows program)
                           always (equal-including-properties before after))
              (ebox-layer--program-settle program t)
              (setf (ebox-geometry--route-program route) program
                    (ebox-geometry--route-refresh-p route) t)
              (vector node width height))))))))

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
  (ebox-geometry--prepare buffer-or-name host-ref properties stage rollback after-commit))

(defun ebox-geometry--prepare (buffer-or-name host-ref properties stage rollback
                                            after-commit &optional fixed-portals-p)
  "Compile HOST-REF in BUFFER-OR-NAME for PROPERTIES and paired callbacks.
STAGE, ROLLBACK and AFTER-COMMIT follow `ebox-geometry-prepare'.
Only the mixed-update provider supplies FIXED-PORTALS-P, after proving every
member independent of the mounted root portals.  Public geometry preparation
continues to reject these scenes, including reuse of an existing scene."
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
           (_portal-admission
            (when (and (plist-get state :root-portals-p) (not fixed-portals-p))
              (ebox-geometry--record-admission 'route 'root-portals)
              (throw 'ebox-geometry-unsupported nil)))
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
                                          state node (and prior (ebox-geometry--operation-routes prior))
                                          fixed-portals-p))))
           (crop (or (and session (ebox-geometry--operation-crop session))
                     (and (not session) routes (= (length routes) 1)
                          (cl-some (lambda (key) (memq key '(:width :height)))
                                   (append keys nil))
                          (with-current-buffer buffer
                            (ebox-geometry--prepare-crop state (aref routes 0) node)))))
           (program (and routes (ebox-geometry--route-program (aref routes 0)))))
      (dotimes (index (length keys))
        (unless (memq (aref keys index) ebox--region-geometry-properties)
          (user-error "Ebox property is not geometry: %S" (aref keys index)))
        (when (cl-position (aref keys index) keys :end index)
          (user-error "Ebox prepared geometry properties must be unique")))
      (unless program
        (ebox-geometry--record-admission
         'geometry (cond ((null state) 'unmounted)
                         ((not (equal display-signature (plist-get state :display-signature)))
                          'display-context)
                         ((null node) 'missing-host)
                         ((null surface) 'surface)
                         (t 'containing-plane))))
      (when program
        (let* ((units (make-vector (length keys) nil))
               (fixed (make-vector (length keys) nil))
               (target (gethash (plist-get node :node-id)
                                (ebox-layer--program-targets program)))
               (containing-box (ebox-geometry--route-wrapper (aref routes 0)))
               (x-factor 1) (supported (and target (> (length target) 0))))
          (unless supported
            (ebox-geometry--record-admission 'geometry 'target))
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
                  (ebox-geometry--record-admission 'geometry 'horizontal-unit :property key)
                  (setq supported nil)))
               ((eq key :top)
                (if (and (consp value) (eq (car value) 'lh)
                         (numberp (cadr value)))
                    (aset units index 'lh)
                  (ebox-geometry--record-admission 'geometry 'vertical-unit :property key)
                  (setq supported nil)))
               ((eq key :z-index)
                (unless (integerp value)
                  (ebox-geometry--record-admission 'geometry 'stacking-value :property key)
                  (setq supported nil))))))
          (when (and supported
                     (or (ebox-geometry--inline-slots-p state node keys)
                         (progn (ebox-geometry--record-admission 'geometry 'inline-winner) nil)))
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
                            :scroll-timers (make-hash-table :test #'equal)
                            :scroll-before-global (make-hash-table :test #'equal)
                            :viewport-cache (make-hash-table :test #'eq)
                            :content-cache (make-hash-table :test #'eq))))))
              (unless source-slots
                (ebox-geometry--record-admission 'geometry 'source-binding))
              (when operation
                (setf (ebox-geometry--operation-session operation) (or session operation)
                      (ebox-geometry--operation-node operation) node
                      (ebox-geometry--operation-crop operation) crop
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
                                        (plist-get (ebox-geometry--route-wrapper route) :region-id))
                               rows
                               ;; Unoccluded base and layer pixels, before
                               ;; composition splits them.
                               (cl-loop for route across routes
                                        for layer = (ebox-geometry--route-program route)
                                        append (append (ebox-layer--program-base-lines layer) nil)
                                        append (cl-loop for record across
                                                        (ebox-layer--program-records layer)
                                                        collect (plist-get record :text)))
                               (cl-loop for route across routes sum
                                        (hash-table-count
                                         (ebox-layer--program-targets
                                          (ebox-geometry--route-program route))))))))
                    (setf (ebox-geometry--operation-projection operation) projection
                          (ebox-geometry--operation-frame operation)
                          (or (and reused-projection
                                   (when-let* ((frame (ebox--pub-frame-refresh
                                                      (ebox-geometry--operation-frame prior)
                                                      state operation)))
                                     (let ((slots (ebox-surface--geometry-mount-slots projection)))
                                       (if (eq (ebox--pub-frame-slots frame) slots) frame
                                         (ebox--pub-frame-replace frame slots)))))
                              (ebox--pub-frame-prepare
                               surface (ebox-surface--geometry-mount-slots projection)
                               operation #'ebox-geometry--dispatch-stage #'ebox-geometry--dispatch-rollback
                               #'ebox-geometry--dispatch-accept)))))
                (with-current-buffer buffer
                  (setq ebox-geometry--session (or session operation)))
                operation))))))))

(defun ebox-geometry--fill (holder rendered rows dirty)
  "Fill HOLDER's projection slots from RENDERED ROWS with DIRTY damage.
An owner whose interval pool is exhausted grows within its fixed bound; its
publication frame is then replaced over the grown slots before the retry.
Return the active mount count, or nil when the bound cannot represent RENDERED."
  (let ((projection (ebox-geometry--operation-projection holder))
        count)
    (while (and (null (setq count (ebox-surface--geometry-mount-fill
                                   projection rendered rows dirty)))
                (ebox-surface--geometry-mount-grow projection))
      (setf (ebox-geometry--operation-frame holder)
            (ebox--pub-frame-replace
             (ebox-geometry--operation-frame holder)
             (ebox-surface--geometry-mount-slots projection))))
    count))

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
           (crop (ebox-geometry--operation-crop operation))
           (crop-p (and crop (eq node (aref crop 0))))
           (width (and crop-p (cadr (ebox-get node :width))))
           (height (and crop-p (cadr (ebox-get node :height))))
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
           ((and crop-p (memq key '(:width :height)))
            (unless (and (consp value) (eq (car value) (if (eq key :width) 'px 'lh))
                         (consp (cdr value)) (null (cddr value))
                         (ebox-size--finite-number-p (cadr value)) (>= (cadr value) 0))
              (user-error "Prepared crop dimensions must retain finite px/lh units"))
            (unless (and (integerp (cadr value)) (> (cadr value) 0)
                         (<= (cadr value) (aref crop (if (eq key :width) 1 2))))
              (setq supported nil))
            (if (eq key :width) (setq width (cadr value)) (setq height (cadr value)))
            (setcar (cdr (aref owned-values index)) (cadr value)))
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
            (let* ((resized (or (not crop-p)
                                (ebox-geometry--resize-program
                                 program (ebox-geometry--operation-target operation) crop width height)))
                   (rendered (and resized (ebox-incremental--with-phase 'layout
                                                           (ebox-geometry--render operation))))
                   (root-route (aref (ebox-geometry--operation-routes operation)
                                     (1- (length (ebox-geometry--operation-routes operation)))))
                   (count (and rendered (ebox-incremental--with-phase 'projection
                                                                      (ebox-geometry--fill
                                                                       operation rendered
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
