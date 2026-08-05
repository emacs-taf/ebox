;;; ebox-fragment.el --- Layout fragments and snapshots for Ebox -*- lexical-binding: t; -*-

;;; Commentary:
;; Owns derived layout fragment and snapshot data used for diffing and
;; patchability checks.  It does not own source identity or buffer edits.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ebox-tree)
(require 'ebox-measure)

(cl-defstruct (ebox-fragment
               (:constructor ebox-fragment-create))
  node-id type display region-ids child-ids style-signature size
  line-signature span-footprint-signature external-footprint-signature
  parent-slot-signature role-topology-signature overflow-signature
  buffer-span buffer-spans)

(defun ebox-fragment-layout-signature (fragment)
  "Return layout-significant fields from FRAGMENT.
Backend marker and buffer span data are intentionally excluded."
  (let (signature)
    (dolist (field '(:node-id :type :display :region-ids :child-ids
                     :style-signature :size :line-signature))
      (let* ((name (intern (substring (symbol-name field) 1)))
             (accessor (intern (format "ebox-fragment-%s" name)))
             (value (and (fboundp accessor) (funcall accessor fragment))))
        (when value
          (setq signature (plist-put signature field value)))))
    signature))

(defconst ebox--paint-style-signature-keys
  '(:color :bgcolor
    :border-top-p :border-bottom-p
    :border-left-color :border-right-color
    :border-top-color :border-bottom-color)
  "Box properties that affect paint without changing layout geometry.")

(defconst ebox--geometry-style-signature-keys
  '(:box-sizing
    :width :min-width :max-width
    :height :min-height :max-height
    :padding-left-pixel :padding-right-pixel
    :padding-top-height :padding-bottom-height
    :margin-left-pixel :margin-right-pixel
    :margin-top-height :margin-bottom-height
    :border-left-pixel :border-right-pixel
    :text-align :vertical-align
    :overflow :wrap-mode
    :flex-props :flex-participation)
  "Style signature keys that require layout or owner rerender work.")

(defconst ebox--structure-style-signature-keys
  '(:display)
  "Style signature keys that change tree or formatting-context structure.")

(defconst ebox--style-signature-keys
  (append ebox--paint-style-signature-keys
          ebox--geometry-style-signature-keys)
  "Box properties included in layout snapshot style signatures.")

(defun ebox-fragment-style-source-node (node)
  "Return the box-like node carrying visual style for NODE."
  (pcase (and (listp node) (plist-get node :ebox-type))
    ('box node)
    ('flex (plist-get node :box))
    ('grid (plist-get node :box))
    (_ nil)))

(defun ebox-fragment-node-style-signature (node)
  "Return NODE's display, layout, flex, and paint style signature."
  (when (listp node)
    (let ((signature (list :display (ebox--computed-display node))))
      (when-let ((style-node (ebox-fragment-style-source-node node)))
        (dolist (key ebox--style-signature-keys)
          (when (plist-member style-node key)
            (setq signature
                  (plist-put signature key (plist-get style-node key)))))
        (when-let ((participation (ebox--flex-participation-props style-node)))
          (setq signature
                (plist-put signature :flex-participation participation))))
      (when (eq (ebox--display-inner node) 'flex)
        (setq signature
              (plist-put signature :flex-props
                         (plist-get node :props))))
      (when-let ((participation (ebox--flex-participation-props node)))
        (setq signature
              (plist-put signature :flex-participation participation)))
      signature)))

(defun ebox-fragment-plist-keys (plist)
  "Return the keyword keys present in PLIST."
  (let (keys)
    (while plist
      (push (pop plist) keys)
      (pop plist))
    (nreverse keys)))

(defun ebox-fragment-plist-changed-keys (old new)
  "Return keys whose plist values differ between OLD and NEW."
  (let (changed keys)
    (dolist (key (append (ebox-fragment-plist-keys old)
                         (ebox-fragment-plist-keys new)))
      (cl-pushnew key keys))
    (dolist (key keys)
      (unless (equal (plist-get old key)
                     (plist-get new key))
        (push key changed)))
    changed))

(defun ebox-fragment-style-signature-dirty-kind (old new)
  "Return dirty kind implied by OLD and NEW style signatures."
  (let ((changed (ebox-fragment-plist-changed-keys old new)))
    (cond
     ((null changed) nil)
     ((cl-some (lambda (key)
                 (memq key ebox--structure-style-signature-keys))
               changed)
      'structure)
     ((cl-some (lambda (key)
                 (memq key ebox--geometry-style-signature-keys))
               changed)
      'geometry)
     (t 'paint))))

(defun ebox-fragment-layout-snapshot-detailed-p (snapshot)
  "Return non-nil when SNAPSHOT already has expensive detail fields."
  (and (plist-member snapshot :buffer-spans)
       (plist-member snapshot :line-signature)
       (plist-member snapshot :span-footprint-signature)
       (plist-member snapshot :external-footprint-signature)
       (plist-member snapshot :parent-slot-signature)
       (plist-member snapshot :role-topology-signature)
       (plist-member snapshot :overflow-signature)))

(defun ebox-fragment-layout-snapshot-spans-p (snapshot)
  "Return non-nil when SNAPSHOT already has buffer span details."
  (plist-member snapshot :buffer-spans))

(defun ebox-fragment-node-layout-snapshot (buffer node &optional details)
  "Return a derived layout snapshot for NODE in BUFFER.
The default snapshot is intentionally lightweight; when DETAILS is non-nil,
include buffer spans and line signatures."
  (let* ((node-id (ebox--ensure-node-id node))
         (region-ids (ebox--node-all-region-ids node))
         (snapshot
          (list :node-id node-id
                :type (plist-get node :ebox-type)
                :display (ebox--computed-display node)
                :region-ids region-ids
                :style-signature (ebox--node-style-signature node)
                :child-ids
                (mapcar #'ebox--ensure-node-id
                        (ebox--node-children node)))))
    (if details
        (ebox--complete-layout-snapshot buffer node snapshot)
      snapshot)))

(defun ebox-fragment-layout-snapshot-dirty-kind (old new)
  "Return the dirty kind between OLD and NEW layout snapshots."
  (cond
   ((or (null old) (null new)) 'structure)
   ((not (eq (plist-get old :type)
             (plist-get new :type)))
    'structure)
   ((not (equal (plist-get old :display)
                (plist-get new :display)))
    'structure)
   ((not (equal (plist-get old :child-ids)
                (plist-get new :child-ids)))
    'structure)
   ((not (equal (plist-get old :line-signature)
                (plist-get new :line-signature)))
    'geometry)
   ((not (equal (plist-get old :buffer-spans)
                (plist-get new :buffer-spans)))
    'placement)
   ((not (equal (plist-get old :style-signature)
                (plist-get new :style-signature)))
    (ebox-fragment-style-signature-dirty-kind
     (plist-get old :style-signature)
     (plist-get new :style-signature)))))

(defalias 'ebox--style-source-node #'ebox-fragment-style-source-node)
(defalias 'ebox--node-style-signature #'ebox-fragment-node-style-signature)
(defalias 'ebox--plist-keys #'ebox-fragment-plist-keys)
(defalias 'ebox--plist-changed-keys #'ebox-fragment-plist-changed-keys)
(defalias 'ebox--style-signature-dirty-kind
  #'ebox-fragment-style-signature-dirty-kind)
(defalias 'ebox--layout-snapshot-detailed-p
  #'ebox-fragment-layout-snapshot-detailed-p)
(defalias 'ebox--layout-snapshot-spans-p
  #'ebox-fragment-layout-snapshot-spans-p)
(defalias 'ebox--node-layout-snapshot
  #'ebox-fragment-node-layout-snapshot)
(defalias 'ebox--layout-snapshot-dirty-kind
  #'ebox-fragment-layout-snapshot-dirty-kind)

(provide 'ebox-fragment)

;;; ebox-fragment.el ends here
