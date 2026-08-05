;;; ebox-render-context.el --- Shared render context binding -*- lexical-binding: t; -*-

;;; Commentary:
;; Owns the compile-safe render-context binding shared by the incremental
;; planner and the buffer backend.  Keeping this macro below both modules avoids
;; their runtime dependency cycle becoming an invalid byte-compiled function.

;;; Code:

(defvar ebox-viewport-width nil)
(defvar ebox-viewport-height nil)
(defvar ebox--render-runtime-revision nil)
(defvar ebox--render-cache-table nil)
(defvar ebox--render-cache-signature-cache nil)
(defvar ebox--viewport-dependent-node-ids-cache nil)
(defvar ebox--viewport-dependent-subtree-cache nil)
(defvar ebox--viewport-height-dependent-subtree-cache nil)
(defvar ebox--flex-content-min-width-table nil
  "Render-owned box measurements reusable by native scene compilation.")

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
