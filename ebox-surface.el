;;; ebox-surface.el --- Pure retained surface projection -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Owns the pure boundary from an Ebox candidate runtime and rendered layout to
;; a generic TP surface plan.  It never publishes or scans a live buffer.

;;; Code:

(require 'cl-lib)
(require 'ebox-tree)
(require 'ebox-layout)
(require 'ebox-incremental)
(require 'tp-surface)

(defvar ebox-region-types)
(defvar ebox--region-box-table)
(defvar ebox--scroll-global-state)
(defvar ebox--scroll-idle-prefetch-timers)
(defvar ebox--smooth-scroll-state-table)

(declare-function ebox-render "ebox-layout" (node))
(declare-function ebox--scroll-schedule-idle-prefetch
                  "ebox" (region-id &optional delay))

(defconst ebox-surface--root-key 'ebox/surface
  "Stable TP key for an Ebox surface projection root.")

(defconst ebox-surface--nodes-key 'ebox/nodes
  "Stable TP key for the retained logical Ebox node tree.")

(defconst ebox-surface--fragments-key 'ebox/fragments
  "Stable TP key for linear rendered fragments.")

(defun ebox-surface--candidate-root (source previous-state)
  "Return an isolated runtime copy of SOURCE reconciled with PREVIOUS-STATE."
  (unless (and (listp source) (not (stringp source)))
    (error "Ebox surface source must be an Ebox node"))
  (ebox-tree-validate-declarative-root source)
  (let ((candidate
         (ebox-tree-clear-runtime-identities
          (ebox-tree-copy-node-structure source))))
    (when-let ((previous-root (plist-get previous-state :root-node)))
      (ebox-tree-reconcile-runtime previous-root candidate))
    candidate))

(defun ebox-surface--node-key (node)
  "Return NODE's namespaced sibling key, or nil for positional identity."
  (when-let ((key (plist-get node :key)))
    (list 'ebox/key key)))

(defun ebox-surface--node-kind (node)
  "Return the TP kind discriminator for Ebox NODE."
  (list 'ebox/node (plist-get node :ebox-type)))

(defun ebox-surface--ensure-node-tree (context parent node table)
  "Ensure NODE and descendants below PARENT in CONTEXT and fill TABLE."
  (let ((object
         (tp-object-ensure context parent
                           (ebox-surface--node-key node)
                           (ebox-surface--node-kind node))))
    (tp-object-retain context object)
    (plist-put node :surface-object object)
    (puthash node object table)
    (dolist (child (ebox-tree--children-raw node))
      (ebox-surface--ensure-node-tree context object child table))
    object))

(defun ebox-surface--node-object-table (objects-by-node)
  "Return a node-id keyed table from OBJECTS-BY-NODE."
  (let ((table (make-hash-table :test 'equal)))
    (maphash
     (lambda (node object)
       (let ((node-id (plist-get node :node-id)))
         (unless node-id
           (error "Ebox rendered node has no runtime identity"))
         (puthash node-id object table)))
     objects-by-node)
    table))

(defun ebox-surface--region-object-table (state node-objects)
  "Return region-to-object table from candidate STATE and NODE-OBJECTS."
  (let ((table (make-hash-table :test 'equal)))
    (maphash
     (lambda (region-id node-id)
       (let ((object (gethash node-id node-objects)))
         (unless object
           (error "Ebox region %S has no candidate surface object" region-id))
         (puthash region-id object table)))
     (plist-get state :region-node-table))
    table))

(defun ebox-surface--hash-keys (table)
  "Return TABLE keys in unspecified order."
  (let (keys)
    (maphash (lambda (key _value) (push key keys)) table)
    keys))

(defun ebox-surface--render-candidate (state)
  "Render candidate STATE in isolated Ebox side tables."
  (let ((scroll-table (make-hash-table :test 'equal))
        (timer-table (make-hash-table :test 'equal))
        (smooth-table (make-hash-table :test 'equal)))
    (let ((ebox--region-box-table (plist-get state :region-box-table))
          (ebox--scroll-global-state scroll-table)
          (ebox--scroll-idle-prefetch-timers timer-table)
          (ebox--smooth-scroll-state-table smooth-table))
      (cl-letf (((symbol-function 'ebox--scroll-schedule-idle-prefetch)
                 (lambda (&rest _) nil)))
        (prog1 (ebox-render (plist-get state :root-node))
          (plist-put state :scroll-state-table scroll-table)
          (plist-put state :scroll-region-ids
                     (ebox-surface--hash-keys scroll-table)))))))

(defun ebox-surface--finish-runtime-state (state)
  "Install post-layout runtime indexes into candidate STATE."
  (ebox--render-state-install-index
   state (ebox--runtime-index (plist-get state :root-node) t)))

(defun ebox-surface--role-ids-at (rendered position)
  "Return namespaced Ebox role/id pairs at POSITION in RENDERED."
  (let (roles)
    (dolist (region-id
             (get-text-property position 'ebox-content-owners rendered))
      (cl-pushnew (cons 'content-owner region-id) roles :test #'equal))
    (dolist (entry ebox-region-types)
      (when-let ((region-id
                  (get-text-property position (cdr entry) rendered)))
        (cl-pushnew (cons (car entry) region-id) roles :test #'equal)))
    (nreverse roles)))

(defun ebox-surface--region-role-tags (region-id role-ids)
  "Return projection tags for REGION-ID from ROLE-IDS."
  (list :ebox/region-id region-id
        :ebox/roles
        (cl-loop for (role . owner) in role-ids
                 when (equal owner region-id) collect role)))

(defun ebox-surface--attach-fragment
    (context fragment role-ids region-objects)
  "Attach FRAGMENT to ROLE-IDS owners through REGION-OBJECTS in CONTEXT."
  (dolist (region-id (delete-dups (mapcar #'cdr role-ids)))
    (let ((object (gethash region-id region-objects)))
      (unless object
        (error "Ebox output references unknown region %S" region-id))
      (tp-object-attach-fragment
       context object fragment
       (ebox-surface--region-role-tags region-id role-ids)))))

(defun ebox-surface--fragment-plan
    (context parent rendered start end index region-objects)
  "Return one plan below PARENT for RENDERED START..END at INDEX in CONTEXT."
  (let* ((key (cons 'ebox/fragment index))
         (object (tp-object-ensure context parent key 'ebox/fragment))
         (role-ids (ebox-surface--role-ids-at rendered start))
         (tags (list :ebox/fragment index :ebox/role-ids role-ids)))
    (ebox-surface--attach-fragment
     context object role-ids region-objects)
    (tp-surface-plan-create
     :key key :kind 'ebox/fragment
     :text (substring rendered start end) :tags tags
     :capability 'content)))

(defun ebox-surface--fragment-plans
    (context parent rendered region-objects)
  "Return property-interval plans in CONTEXT for RENDERED below PARENT."
  (let ((position 0)
        (limit (length rendered))
        (index 0)
        plans)
    (while (< position limit)
      (let ((next (or (next-property-change position rendered limit) limit)))
        (push (ebox-surface--fragment-plan
               context parent rendered position next index region-objects)
              plans)
        (setq position (max next (1+ position))
              index (1+ index))))
    (nreverse plans)))

(defun ebox-surface--surface-plan
    (context surface-root rendered region-objects)
  "Return CONTEXT's plan below SURFACE-ROOT for RENDERED and REGION-OBJECTS."
  (let* ((fragment-root
          (tp-object-ensure context surface-root
                            ebox-surface--fragments-key 'ebox/fragments))
         (fragments
          (ebox-surface--fragment-plans
           context fragment-root rendered region-objects)))
    (tp-surface-plan-create
     :key ebox-surface--root-key :kind 'ebox/surface
     :children
     (list (tp-surface-plan-create
            :key ebox-surface--fragments-key :kind 'ebox/fragments
            :children fragments :capability 'content))
     :capability 'content)))

(defun ebox-surface--project (context source previous-state)
  "Project SOURCE in CONTEXT using optional PREVIOUS-STATE."
  (let* ((root (ebox-surface--candidate-root source previous-state))
         (state (ebox--new-buffer-render-state root))
         (surface-root
          (tp-object-ensure context nil ebox-surface--root-key 'ebox/surface))
         (node-root
          (tp-object-ensure context surface-root
                            ebox-surface--nodes-key 'ebox/nodes))
         (objects-by-node (make-hash-table :test 'eq)))
    (tp-object-retain context node-root)
    (ebox-surface--ensure-node-tree context node-root root objects-by-node)
    (plist-put state :region-box-table (make-hash-table :test 'equal))
    (let ((rendered (ebox-surface--render-candidate state)))
      (setq state (ebox-surface--finish-runtime-state state))
      (let* ((node-objects (ebox-surface--node-object-table objects-by-node))
             (region-objects
              (ebox-surface--region-object-table state node-objects)))
        (plist-put state :surface-node-object-table node-objects)
        (plist-put state :region-surface-object-table region-objects)
        (tp-surface-result-create
         (ebox-surface--surface-plan
          context surface-root rendered region-objects)
         state)))))

(defun ebox-surface--producer (source &optional previous-state)
  "Return a TP producer for Ebox SOURCE and optional PREVIOUS-STATE."
  (lambda (context)
    (ebox-surface--project context source previous-state)))

(provide 'ebox-surface)

;;; ebox-surface.el ends here
