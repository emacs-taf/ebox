;;; ebox-render-context.el --- Shared render context binding -*- lexical-binding: t; -*-

;;; Commentary:
;; Owns the compile-safe render-context binding shared by the incremental
;; planner and the buffer backend.  Keeping this macro below both modules avoids
;; their runtime dependency cycle becoming an invalid byte-compiled function.

;;; Code:

(defvar ebox-viewport-width nil)
(defvar ebox-viewport-height nil)
(defvar ebox--render-runtime-revision nil)
(defvar ebox--surface-materialization-active nil)
(defvar ebox--render-cache-table nil)
(defvar ebox--render-cache-signature-cache nil)
(defvar ebox--viewport-dependent-node-ids-cache nil)
(defvar ebox--viewport-dependent-subtree-cache nil)
(defvar ebox--viewport-height-dependent-subtree-cache nil)
(defvar ebox--flex-content-min-width-table nil
  "Render-owned box measurements reusable by native scene compilation.")

(defvar ebox--render-owned-text-values nil
  "Candidate-local text-property values explicitly created by Ebox.")

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
    (when-let ((values (ebox--render-owned-text-values-for property t)))
      (puthash value t values)))
  value)

(defun ebox--render-owned-text-value-p (property value &optional registry)
  "Return non-nil when VALUE is Ebox-owned for PROPERTY.
REGISTRY defaults to the active render candidate."
  (let ((ebox--render-owned-text-values
         (or registry ebox--render-owned-text-values)))
    (when-let ((values (ebox--render-owned-text-values-for property)))
      (gethash value values))))

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
    (when-let ((provenance
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
