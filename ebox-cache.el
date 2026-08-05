;;; ebox-cache.el --- Cache ownership metadata for Ebox -*- lexical-binding: t; -*-

;;; Commentary:
;; Owns shared cache contracts, cache invalidation metadata, and cache
;; reporting helpers.  It does not own rendering, layout, or buffer mutation.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(cl-defstruct (ebox-cache-spec
               (:constructor ebox-cache-spec-create))
  name owner scope key-deps invalidates lifetime value-owner)

(defvar ebox-cache--registry (make-hash-table :test 'eq)
  "Registry of cache specs keyed by cache name.")

(defvar ebox-cache--buffer-report-table (make-hash-table :test 'eq)
  "Buffer-keyed cache report facts for the current incremental operation.")

(defvar ebox-cache-report-buffer nil
  "Dynamically bound buffer whose cache report should be appended to reports.")

(defconst ebox-cache--default-specs
  '((:name measurement
     :owner ebox-measure
     :scope display
     :key-deps (string face text-scale display-signature)
     :invalidates (font frame text-scale display-signature)
     :lifetime global-or-display
     :value-owner ebox-measure)
    (:name computed-style
     :owner ebox-style
     :scope node
     :key-deps (specified-style-signature class-version theme-version)
     :invalidates (style class theme)
     :lifetime buffer-runtime
     :value-owner ebox-style)
    (:name viewport-dependency
     :owner ebox-incremental
     :scope buffer-runtime
     :key-deps (root-id computed-style-tree-version viewport-width)
     :invalidates (width display children style viewport)
     :lifetime buffer-runtime
     :value-owner ebox-incremental)
    (:name layout-fragment
     :owner ebox-layout
     :scope formatting-context
     :key-deps (node-id computed-style-signature child-signatures available-size)
     :invalidates (geometry structure viewport)
     :lifetime buffer-runtime
     :value-owner ebox-layout)
    (:name render-body
     :owner ebox-buffer-backend
     :scope buffer-render
     :key-deps (fragment-signature paint-signature backend-display-signature)
     :invalidates (paint geometry structure backend-display)
     :lifetime buffer-runtime
     :value-owner ebox-buffer-backend)
    (:name snapshot-signature
     :owner ebox-fragment
     :scope buffer-runtime
     :key-deps (node-id fragment-version style-signature)
     :invalidates (style geometry placement structure)
     :lifetime buffer-runtime
     :value-owner ebox-fragment))
  "Default cache contracts for existing Ebox engine caches.")

(defun ebox-cache-clear-registry ()
  "Clear the cache spec registry."
  (clrhash ebox-cache--registry))

(cl-defun ebox-cache-register
    (&key name owner scope key-deps invalidates lifetime value-owner)
  "Register and return a cache spec."
  (unless name
    (error "ebox-cache: cache spec requires :name"))
  (let ((spec (ebox-cache-spec-create
               :name name
               :owner owner
               :scope scope
               :key-deps key-deps
               :invalidates invalidates
               :lifetime lifetime
               :value-owner value-owner)))
    (puthash name spec ebox-cache--registry)
    spec))

(defun ebox-cache-spec (name)
  "Return registered cache spec NAME."
  (gethash name ebox-cache--registry))

(defun ebox-cache-register-default-specs ()
  "Register default cache specs and return the registry."
  (dolist (spec ebox-cache--default-specs)
    (apply #'ebox-cache-register spec))
  ebox-cache--registry)

(defun ebox-cache-reset-default-registry ()
  "Reset the registry to the default engine cache specs."
  (ebox-cache-clear-registry)
  (ebox-cache-register-default-specs))

(defun ebox-cache--intersects-p (left right)
  "Return non-nil when LEFT and RIGHT share a symbol."
  (cl-intersection left right :test #'eq))

(defun ebox-cache-invalidated-spec-names (dirty-kinds)
  "Return cache spec names whose invalidation rules intersect DIRTY-KINDS."
  (let (names)
    (maphash
     (lambda (name spec)
       (when (ebox-cache--intersects-p
              dirty-kinds (ebox-cache-spec-invalidates spec))
         (push name names)))
     ebox-cache--registry)
    names))

(defun ebox-cache--empty-report ()
  "Return a new empty cache report plist."
  (list :cache-invalidated nil
        :cache-hit-count 0
        :cache-miss-count 0
        :cache-scope nil
        :cache-fallback-reason nil))

(defun ebox-cache-clear-report (buffer)
  "Clear cache report facts for BUFFER."
  (when buffer
    (ebox-cache-publish-report buffer (ebox-cache--empty-report))))

(defun ebox-cache-publish-report (buffer report)
  "Atomically replace BUFFER's cache REPORT facts."
  (when buffer
    (puthash buffer (copy-sequence report)
             ebox-cache--buffer-report-table)))

(defun ebox-cache-snapshot-report (buffer)
  "Return an exact restorable snapshot of BUFFER's cache report entry."
  (let* ((missing (make-symbol "missing"))
         (report (and buffer
                      (gethash buffer ebox-cache--buffer-report-table missing))))
    (list :present-p (and buffer (not (eq report missing)))
          :report (unless (eq report missing) (copy-sequence report)))))

(defun ebox-cache-restore-report (buffer snapshot)
  "Restore BUFFER's cache report entry from SNAPSHOT."
  (when buffer
    (if (plist-get snapshot :present-p)
        (puthash buffer (copy-sequence (plist-get snapshot :report))
                 ebox-cache--buffer-report-table)
      (remhash buffer ebox-cache--buffer-report-table))))

(defun ebox-cache-discard-report (buffer)
  "Discard cache report facts owned by BUFFER."
  (when buffer
    (remhash buffer ebox-cache--buffer-report-table)))

(defun ebox-cache--report-state (buffer)
  "Return mutable cache report state for BUFFER."
  (when buffer
    (or (gethash buffer ebox-cache--buffer-report-table)
        (let ((state (ebox-cache--empty-report)))
          (puthash buffer state ebox-cache--buffer-report-table)
          state))))

(defun ebox-cache--push-unique-values (state key values)
  "Append VALUES uniquely to STATE at KEY."
  (dolist (value values)
    (when value
      (cl-pushnew value (plist-get state key) :test #'equal))))

(defun ebox-cache--spec-scopes (cache-names)
  "Return distinct scopes for CACHE-NAMES."
  (let (scopes)
    (dolist (name cache-names)
      (when-let ((spec (ebox-cache-spec name)))
        (cl-pushnew (ebox-cache-spec-scope spec) scopes :test #'equal)))
    scopes))

(defun ebox-cache-record-hit (buffer cache-name)
  "Record a CACHE-NAME hit for BUFFER's current update report."
  (when-let ((state (ebox-cache--report-state buffer)))
    (plist-put state :cache-hit-count
               (1+ (or (plist-get state :cache-hit-count) 0)))
    (ebox-cache--push-unique-values
     state :cache-scope (ebox-cache--spec-scopes (list cache-name)))))

(defun ebox-cache-record-miss (buffer cache-name)
  "Record a CACHE-NAME miss for BUFFER's current update report."
  (when-let ((state (ebox-cache--report-state buffer)))
    (plist-put state :cache-miss-count
               (1+ (or (plist-get state :cache-miss-count) 0)))
    (ebox-cache--push-unique-values
     state :cache-scope (ebox-cache--spec-scopes (list cache-name)))))

(defun ebox-cache-record-invalidation (buffer cache-names reason)
  "Record invalidated CACHE-NAMES and REASON for BUFFER."
  (when-let ((state (ebox-cache--report-state buffer)))
    (ebox-cache--push-unique-values state :cache-invalidated cache-names)
    (ebox-cache--push-unique-values
     state :cache-scope (ebox-cache--spec-scopes cache-names))
    (plist-put state :cache-fallback-reason reason)))

(defun ebox-cache-report (buffer)
  "Return cache report plist for BUFFER."
  (copy-sequence
   (or (gethash buffer ebox-cache--buffer-report-table)
       (ebox-cache--empty-report))))

(ebox-cache-register-default-specs)

(provide 'ebox-cache)

;;; ebox-cache.el ends here
