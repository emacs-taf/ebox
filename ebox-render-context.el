;;; ebox-render-context.el --- Shared render context binding -*- lexical-binding: t; -*-

;;; Commentary:
;; Owns the compile-safe render-context binding shared by the incremental
;; planner and the buffer backend.  Keeping this macro below both modules avoids
;; their runtime dependency cycle becoming an invalid byte-compiled function.

;;; Code:

(require 'cl-lib)

(define-error 'ebox-layout-context-error
  "Ebox layout context is unavailable")

(cl-defstruct
    (ebox-layout-context-port
     (:constructor ebox-render-context--make-layout-port))
  "Injected operations used when layout needs candidate materialization."
  candidate-root inline-inheritance-required-p materialize-string)

(defvar ebox--layout-context-port nil
  "Current surface-independent input port for candidate materialization.")

(cl-defun ebox-render-context-create-layout-port
    (&key candidate-root inline-inheritance-required-p materialize-string)
  "Create a validated layout context port from three operation functions."
  (dolist (entry
           `((candidate-root . ,candidate-root)
             (inline-inheritance-required-p
              . ,inline-inheritance-required-p)
             (materialize-string . ,materialize-string)))
    (unless (functionp (cdr entry))
      (signal 'ebox-layout-context-error
              (list :invalid-operation (car entry) (cdr entry)))))
  (ebox-render-context--make-layout-port
   :candidate-root candidate-root
   :inline-inheritance-required-p inline-inheritance-required-p
   :materialize-string materialize-string))

(defun ebox-render-context--require-layout-port ()
  "Return the current validated layout context port."
  (unless (ebox-layout-context-port-p ebox--layout-context-port)
    (signal 'ebox-layout-context-error (list :missing-layout-port)))
  ebox--layout-context-port)

(defun ebox-render-context-candidate-root (source preserve-identities-p)
  "Return an isolated candidate for SOURCE through the current layout port."
  (funcall
   (ebox-layout-context-port-candidate-root
    (ebox-render-context--require-layout-port))
   source preserve-identities-p))

(defun ebox-render-context-inline-inheritance-required-p
    (root source-index)
  "Ask the current layout port whether ROOT requires inherited cascade."
  (funcall
   (ebox-layout-context-port-inline-inheritance-required-p
    (ebox-render-context--require-layout-port))
   root source-index))

(defun ebox-render-context-materialize-string (source source-index)
  "Materialize SOURCE with SOURCE-INDEX through the current layout port."
  (funcall
   (ebox-layout-context-port-materialize-string
    (ebox-render-context--require-layout-port))
   source source-index))

(defvar ebox-viewport-width nil)
(defvar ebox-viewport-height nil)
(defvar ebox--render-runtime-revision nil)
(defvar ebox--surface-materialization-active nil)
(defvar ebox--render-root-parent-kind nil
  "Formatting context owning the detached render root, or nil.")
(defvar ebox--render-cache-table nil)
(defvar ebox--render-cache-signature-cache nil)
(defvar ebox--viewport-dependent-node-ids-cache nil)
(defvar ebox--viewport-dependent-subtree-cache nil)
(defvar ebox--viewport-height-dependent-subtree-cache nil)
(defvar ebox--flex-content-min-width-table nil
  "Render-owned box measurements reusable by native scene compilation.")

(defvar ebox--render-owned-text-values nil
  "Candidate-local text-property values explicitly created by Ebox.")

(cl-defstruct (ebox--paint-origin
               (:constructor ebox--paint-origin-create))
  "Transient caller-face baseline captured before Ebox paint composition."
  baseline)

(defconst ebox--paint-origin-property 'ebox--paint-origin
  "Private transient property carrying one render-time paint baseline.")

(defvar ebox--paint-origin-capture-p nil
  "Non-nil while production Ebox rendering captures paint origins.")

(defvar ebox--render-output-provenance-table
  (make-hash-table :test #'eq :weakness 'key)
  "Weak map from rendered strings to Ebox-owned property values.")

(defun ebox--render-owned-text-values-for (property &optional create)
  "Return the active candidate registry for PROPERTY when CREATE is non-nil."
  (when (hash-table-p ebox--render-owned-text-values)
    (or (gethash property ebox--render-owned-text-values)
        (when create
          (let ((values (make-hash-table :test #'eq :weakness 'key)))
            (puthash property values ebox--render-owned-text-values)
            values)))))

(defun ebox--register-render-owned-text-value (property value)
  "Register Ebox-created VALUE for PROPERTY in the active render candidate."
  (when value
    (when-let* ((values (ebox--render-owned-text-values-for property t)))
      (puthash value t values)))
  value)

(defun ebox--render-owned-text-value-p (property value &optional registry)
  "Return non-nil when VALUE is Ebox-owned for PROPERTY.
REGISTRY defaults to the active render candidate."
  (let ((ebox--render-owned-text-values
         (or registry ebox--render-owned-text-values)))
    (when-let* ((values (ebox--render-owned-text-values-for property)))
      (gethash value values))))

(defun ebox--capture-paint-origins! (string start end)
  "Capture caller FACE baselines on STRING between START and END.
Existing origins are preserved so nested Ebox contributions never replace the
original caller baseline.  The property is stripped before a TP plan leaves
the render boundary."
  (when (and ebox--paint-origin-capture-p
             (stringp string)
             (< start end))
    (let ((position start))
      (while (< position end)
        (let* ((next (min end
                          (or (next-single-property-change
                               position ebox--paint-origin-property string end)
                              end)
                          (or (next-single-property-change
                               position 'face string end)
                              end)))
               (origin (get-text-property
                        position ebox--paint-origin-property string)))
          (unless origin
            (put-text-property
             position next ebox--paint-origin-property
             (ebox--paint-origin-create
              :baseline (copy-tree (get-text-property position 'face string)))
             string))
          (setq position (max next (1+ position)))))))
  string)

(defun ebox--add-render-face! (string start end face &optional append)
  "Add Ebox FACE to STRING after capturing its caller baseline."
  (ebox--capture-paint-origins! string start end)
  (add-face-text-property start end face append string))

(defun ebox--strip-paint-origins! (string)
  "Remove transient caller-face carriers from STRING before it escapes.
The carrier is retained only while an active surface producer harvests its
baseline.  Public/ephemeral renders must never expose this private property,
including strings returned from a render-cache hit."
  (when (and (stringp string)
             (> (length string) 0))
    (remove-text-properties
     0 (length string) (list ebox--paint-origin-property nil) string))
  string)

(defun ebox--register-render-owned-face-values (source rendered)
  "Register Ebox-generated face identities added to RENDERED from SOURCE."
  (when (and (stringp source)
             (stringp rendered)
             (= (length source) (length rendered))
             (hash-table-p ebox--render-owned-text-values))
    (let ((position 0)
          (length (length rendered)))
      (while (< position length)
        (let ((next
               (min (or (next-property-change position source) length)
                    (or (next-property-change position rendered) length)))
              (source-face (get-text-property position 'face source))
              (rendered-face (get-text-property position 'face rendered)))
          (when (and rendered-face (null source-face))
            (ebox--register-render-owned-text-value 'face rendered-face))
          (setq position next)))))
  rendered)

(defun ebox--record-render-output-provenance (rendered)
  "Record owned property identities actually present in RENDERED."
  (when (and (stringp rendered)
             (hash-table-p ebox--render-owned-text-values))
    (let ((provenance (make-hash-table :test #'eq))
          (position 0)
          (length (length rendered)))
      (remhash rendered ebox--render-output-provenance-table)
      (while (< position length)
        (let ((next (or (next-property-change position rendered) length))
              (properties (text-properties-at position rendered)))
          (while properties
            (let* ((property (pop properties))
                   (value (pop properties))
                   (owned (ebox--render-owned-text-value-p property value)))
              (when owned
                (let ((values (or (gethash property provenance)
                                  (let ((new (make-hash-table
                                              :test #'eq :weakness 'key)))
                                    (puthash property new provenance)
                                    new))))
                  (puthash value t values)))))
          (setq position next)))
      (when (> (hash-table-count provenance) 0)
        (puthash rendered provenance ebox--render-output-provenance-table))))
  rendered)

(defun ebox--replay-render-output-provenance (rendered)
  "Replay owned property identities recorded for RENDERED into this candidate."
  (when (and (stringp rendered)
             (hash-table-p ebox--render-owned-text-values))
    (when-let* ((provenance
                (gethash rendered ebox--render-output-provenance-table)))
      (maphash
       (lambda (property values)
         (let ((owned (ebox--render-owned-text-values-for property t)))
           (maphash (lambda (value _marker)
                    (puthash value t owned))
                    values)))
       provenance)))
  rendered)

(declare-function ebox--buffer-render-state
                  "ebox-incremental" (buffer))

(defmacro ebox--with-buffer-render-context (buffer &rest body)
  "Evaluate BODY using BUFFER's stored render context."
  (declare (indent 1) (debug t))
  (let ((target-buffer (make-symbol "target-buffer"))
        (render-state (make-symbol "render-state")))
    `(let* ((,target-buffer ,buffer)
            (,render-state
             (ebox--buffer-render-state ,target-buffer)))
       (with-current-buffer ,target-buffer
         (let* ((ebox-viewport-width
                 (plist-get ,render-state :viewport-width))
                (ebox-viewport-height
                 (plist-get ,render-state :viewport-height))
                (ebox--render-runtime-revision
                 (plist-get ,render-state :runtime-revision))
                (ebox--surface-materialization-active t)
                (ebox--render-cache-table
                 (plist-get ,render-state :render-cache))
                (ebox--render-cache-signature-cache
                 (or ebox--render-cache-signature-cache
                     (plist-get ,render-state :render-signature-cache)
                     (make-hash-table :test 'eq)))
                (ebox--viewport-dependent-node-ids-cache
                 (or ebox--viewport-dependent-node-ids-cache
                     (make-hash-table :test 'eq)))
                (ebox--viewport-dependent-subtree-cache
                 (or ebox--viewport-dependent-subtree-cache
                     (make-hash-table :test 'eq)))
                (ebox--viewport-height-dependent-subtree-cache
                 (or ebox--viewport-height-dependent-subtree-cache
                     (plist-get
                      ,render-state
                      :viewport-height-dependent-subtree-cache)
                     (make-hash-table :test 'eq)))
                (ebox--flex-content-min-width-table
                 (or ebox--flex-content-min-width-table
                     (plist-get ,render-state :flex-content-min-widths))))
           ,@body)))))

(provide 'ebox-render-context)
;;; ebox-render-context.el ends here
