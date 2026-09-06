;;; ebox-viewport-topology-tests.el --- Viewport topology contracts -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)

(setq load-prefer-newer t)
(load-file (expand-file-name "../ebox.el"
                            (file-name-directory load-file-name)))
(require 'tp-surface)

(defun ebox-viewport-topology-test--nested-scroll (map &optional count)
  "Build one ordinary nested scroll owner with interactive MAP content."
  (ebox-build
   `(column :key root :width (viewport)
            (text "Header")
            (column :key body :id "body" :width stretch
                    :height (viewport-height) :overflow scroll
                    :padding (0 (2))
                    ,@(cl-loop
                       for index below (or count 12)
                       collect
                       `(box :key ,(format "row-%d" index) :width stretch
                             :wrap-mode char
                             (text ,(propertize
                                     (format "Open %02d %s" index (make-string 130 ?x))
                                     'keymap map 'mouse-face 'highlight
                                     'help-echo "Open this row"
                                     'face '(:foreground "#123456"))))))
            (text "Footer"))))

(defun ebox-viewport-topology-test--fresh-output (input state width height &optional offset)
  "Freshly mount INPUT and map only its region identities to matching STATE."
  (let ((buffer (generate-new-buffer " *ebox-viewport-fresh*"))
        (ebox-viewport-width width)
        (ebox-viewport-height height)
        (regions-by-source (make-hash-table :test 'eq))
        (region-map (make-hash-table :test 'equal)))
    (maphash (lambda (_ node)
               (puthash (ebox-node-source-handle node)
                        (plist-get node :region-id) regions-by-source))
             (plist-get state :node-table))
    (unwind-protect
        (progn
          (ebox-render-to-buffer buffer input)
          (when offset
            (let ((region-id (car (plist-get (ebox--buffer-render-state buffer)
                                            :scroll-region-ids))))
              (dotimes (_ offset)
                (ebox--surface-scroll-region-by buffer region-id 1 nil))))
          (maphash (lambda (_ node)
                     (let ((region (gethash (ebox-node-source-handle node)
                                            regions-by-source)))
                       (should region)
                       (puthash (plist-get node :region-id) region region-map)))
                   (plist-get (ebox--buffer-render-state buffer) :node-table))
          (let ((output (with-current-buffer buffer (buffer-string)))
                (properties (cons 'ebox-scroll-window (mapcar #'cdr ebox-region-types)))
                (position 0))
            (while (< position (length output))
              (let ((next (or (next-property-change position output) (length output))))
                (dolist (property properties)
                  (when-let* ((region (get-text-property position property output)))
                    (should (gethash region region-map))
                    (put-text-property position next property
                                       (gethash region region-map) output)))
                (when-let* ((owners (get-text-property position 'ebox-content-owners output)))
                  (put-text-property
                   position next 'ebox-content-owners
                   (mapcar (lambda (region)
                             (should (gethash region region-map))
                             (gethash region region-map)) owners)
                   output))
                (setq position next)))
            output))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(defun ebox-viewport-topology-test--resize (width height axes &optional count)
  "Resize the same nested-scroll topology to WIDTH and HEIGHT on AXES."
  (let ((buffer (generate-new-buffer " *ebox-viewport-topology*"))
        (map (make-sparse-keymap))
        (ebox-viewport-width 120)
        (ebox-viewport-height 4)
        (ebox-runtime-idle-prewarm nil)
        (ebox-runtime-idle-reflow-cache-prewarm nil)
        (ensure-count 0)
        (original-ensure (symbol-function 'ebox-surface--ensure-node-tree)))
    (define-key map [mouse-1] #'ignore)
    (unwind-protect
        (cl-letf (((symbol-function 'ebox-native-reflow-layout-ready-p)
                   (lambda () nil)))
          (let* ((input (ebox-viewport-topology-test--nested-scroll map count))
                 (_mounted (ebox-render-to-buffer buffer input))
                 (old-state (ebox--buffer-render-state buffer))
                 (old-objects (copy-hash-table
                               (plist-get old-state :surface-node-object-table)))
                 (old-text (with-current-buffer buffer (buffer-string)))
                 (scroll-ids (plist-get old-state :scroll-region-ids)))
            ;; This is the all-affected case: one nested owner, no stable peer.
            (should (= (length scroll-ids) 1))
            (should-not (equal (car scroll-ids)
                               (plist-get (plist-get old-state :root-node) :region-id)))
            (cl-letf (((symbol-function 'ebox-surface--ensure-node-tree)
                       (lambda (&rest args)
                         (cl-incf ensure-count)
                         (apply original-ensure args))))
              (ebox-rerender-buffer-with-context buffer width height))
            (let* ((state (ebox--buffer-render-state buffer))
                   (report (ebox-buffer-update-report buffer))
                   (surface (plist-get state :surface))
                   (tp-report (tp-surface-report surface))
                   (objects (plist-get state :surface-node-object-table))
                   (actual (with-current-buffer buffer (buffer-string)))
                   (expected (ebox-viewport-topology-test--fresh-output
                              input state width height))
                   (position (string-match "Open 00" actual)))
              (should (eq (plist-get report :viewport-axes) axes))
              (should (ebox-host-ref-position
                       buffer (ebox-canonical-input-root-host-ref input)))
              (should-not (plist-get state :layout-fragments-reuse-p))
              (should-not (plist-get report :viewport-scroll-stable-ids))
              (should (equal (plist-get report :viewport-scroll-affected-ids) scroll-ids))
              (should-not (equal-including-properties old-text actual))
              (should (equal-including-properties actual expected))
              (should position)
              (should (eq (lookup-key (get-text-property position 'keymap actual)
                                     [mouse-1]) #'ignore))
              (should (equal (get-text-property position 'help-echo actual)
                             "Open this row"))
              (should (eq (get-text-property position 'mouse-face actual) 'highlight))
              (should (= (hash-table-count old-objects) (hash-table-count objects)))
              (maphash (lambda (id object) (should (eq object (gethash id objects))))
                       old-objects)
              (should (= (plist-get tp-report :created-objects) 0))
              (should (= (plist-get tp-report :removed-objects) 0))
              (should (= (plist-get tp-report :moved-objects) 0))
              ;; Producer freshness does not require reconciling stable topology.
              (ert-info ((format "axes=%S ensure=%S reconciled=%S objects=%S"
                                 axes ensure-count
                                 (plist-get tp-report :reconciled-objects)
                                 (hash-table-count objects)))
                (should (= ensure-count 0))
                (should (<= (plist-get tp-report :reconciled-objects) 4))))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-viewport-topology-nested-scroll-width ()
  (ebox-viewport-topology-test--resize 200 4 'width))

(ert-deftest ebox-viewport-topology-nested-scroll-height ()
  (ebox-viewport-topology-test--resize 120 7 'height))

(ert-deftest ebox-viewport-topology-nested-scroll-both ()
  (ebox-viewport-topology-test--resize 200 7 'both))

(ert-deftest ebox-viewport-topology-work-does-not-scale-with-children ()
  (ebox-viewport-topology-test--resize 200 4 'width 48))

(ert-deftest ebox-viewport-topology-unproven-producers-remain-affected ()
  "Missing producer indexes cannot authorize spatial or producer reuse."
  (let ((partition (ebox-incremental--viewport-scroll-partition
                    '(:scroll-region-ids (11 22)))))
    (should-not (plist-get partition :stable))
    (should (equal (plist-get partition :affected) '(11 22)))))

(ert-deftest ebox-viewport-topology-mixed-scroll-preserves-only-stable-producer ()
  "Existing mixed producer preservation remains narrower than topology reuse."
  (let ((buffer (generate-new-buffer " *ebox-viewport-mixed-control*"))
        (ebox-viewport-width 120) (ebox-viewport-height 4)
        (ebox-runtime-idle-prewarm nil)
        (ebox-runtime-idle-reflow-cache-prewarm nil))
    (unwind-protect
        (cl-letf (((symbol-function 'ebox-native-reflow-layout-ready-p)
                   (lambda () nil)))
          (ebox-render-to-buffer
           buffer
           (ebox-build
            '(column :width (viewport)
                     (box :id "stable" :width (80) :height 2 :overflow scroll
                          (text "stable zero\nstable one\nstable two"))
                     (box :id "affected" :width stretch :height (viewport-height)
                          :overflow scroll :wrap-mode char
                          (text "affected zero\naffected one\naffected two\naffected three\naffected four")))))
          (let* ((state (ebox--buffer-render-state buffer))
                 (partition (ebox-incremental--viewport-scroll-partition state))
                 (stable-id (car (plist-get partition :stable)))
                 (affected-id (car (plist-get partition :affected)))
                 (table (plist-get state :scroll-state-table))
                 (stable-lines (plist-get (gethash stable-id table) :content-lines))
                 (affected-lines (plist-get (gethash affected-id table) :content-lines)))
            (should stable-id)
            (should affected-id)
            (ebox-rerender-buffer-with-context buffer 200 5)
            (let* ((new-state (ebox--buffer-render-state buffer))
                   (new-table (plist-get new-state :scroll-state-table))
                   (report (ebox-buffer-update-report buffer)))
              (should (eq (plist-get report :projection-kind) 'viewport-reflow-mixed-scroll))
              (should (plist-get new-state :layout-fragments-reuse-p))
              (should (equal (plist-get report :viewport-scroll-stable-ids) (list stable-id)))
              (should (eq stable-lines (plist-get (gethash stable-id new-table) :content-lines)))
              (should-not (eq affected-lines (plist-get (gethash affected-id new-table) :content-lines))))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-viewport-topology-affected-scroll-round-trip ()
  "Affected producers reach their fresh end after width A-to-B-to-A."
  (let* ((buffer (generate-new-buffer " *ebox-viewport-scroll-round-trip*"))
         (input (ebox-viewport-topology-test--nested-scroll (make-sparse-keymap)))
         (ebox-viewport-width 120) (ebox-viewport-height 4)
         (ebox-runtime-idle-prewarm nil)
         (ebox-runtime-idle-reflow-cache-prewarm nil))
    (unwind-protect
        (cl-letf (((symbol-function 'ebox-native-reflow-layout-ready-p)
                   (lambda () nil)))
          (ebox-render-to-buffer buffer input)
          (let* ((initial (with-current-buffer buffer (buffer-string)))
                 (region-id (car (plist-get (ebox--buffer-render-state buffer)
                                           :scroll-region-ids))))
            (dolist (width '(200 120))
              (ebox-rerender-buffer-with-context buffer width 4)
              (should (<= (plist-get (ebox-buffer-update-report buffer)
                                    :reconciled-objects) 4))
              ;; Small foreground steps synchronously extend a lazy prefix.
              ;; A large absolute jump may intentionally stop at a cold prefix.
              (cl-loop repeat 32
                       for scroll = (gethash region-id
                                             (plist-get (ebox--buffer-render-state buffer)
                                                        :scroll-state-table))
                       until (and (plist-get scroll :content-lines-complete-p)
                                  (= (plist-get scroll :scroll-offset)
                                     (- (length (plist-get scroll :content-lines))
                                        (plist-get scroll :content-height))))
                       do (ebox--surface-scroll-region-by buffer region-id 1 nil))
              (let* ((state (ebox--buffer-render-state buffer))
                     (scroll (gethash region-id (plist-get state :scroll-state-table)))
                     (actual (with-current-buffer buffer (buffer-string)))
                     (offset (plist-get scroll :scroll-offset)))
                (should (plist-get scroll :content-lines-complete-p))
                (should (= offset (max 0 (- (length (plist-get scroll :content-lines))
                                           (plist-get scroll :content-height)))))
                (should (> offset 0))
                (should (string-match-p "Open 11" actual))
                (should (equal-including-properties
                         actual (ebox-viewport-topology-test--fresh-output
                                 input state width 4 offset))))
              (ebox--surface-scroll-to-offset buffer region-id 0))
            (should (equal-including-properties
                     initial (with-current-buffer buffer (buffer-string))))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-viewport-topology-affected-scroll-failure-rolls-back ()
  "Failed all-affected reflow keeps committed identities, producer and timer."
  (let* ((buffer (generate-new-buffer " *ebox-viewport-scroll-failure*"))
         (input (ebox-viewport-topology-test--nested-scroll (make-sparse-keymap)))
         (ebox-viewport-width 120) (ebox-viewport-height 4)
         (ebox-runtime-idle-prewarm nil)
         (ebox-runtime-idle-reflow-cache-prewarm nil)
         timer)
    (unwind-protect
        (cl-letf (((symbol-function 'ebox-native-reflow-layout-ready-p)
                   (lambda () nil)))
          (ebox-render-to-buffer buffer input)
          (let* ((state (ebox--buffer-render-state buffer))
                 (surface (plist-get state :surface))
                 (revision (tp-surface-revision surface))
                 (contents (with-current-buffer buffer (buffer-string)))
                 (region-id (car (plist-get state :scroll-region-ids)))
                 (scroll (gethash region-id (plist-get state :scroll-state-table)))
                 (lines (plist-get scroll :content-lines))
                 (producer (plist-get scroll :render-content-prefix))
                 (host-ref (ebox-canonical-input-root-host-ref input))
                 (host-position (ebox-host-ref-position buffer host-ref))
                 (host-bounds (ebox-host-ref-bounds buffer host-ref))
                 (indexes (mapcar (lambda (key) (plist-get state key))
                                  '(:node-table :parent-table :region-node-table
                                    :surface-node-object-table)))
                 (index-contents
                  (mapcar (lambda (table)
                            (let ((copy (copy-hash-table table)))
                              (maphash (lambda (key value)
                                         (when (listp value)
                                           (puthash key (copy-sequence value) copy)))
                                       table)
                              copy))
                          indexes)))
            (should host-position)
            (ebox--scroll-cancel-idle-prefetch region-id)
            (setq timer (run-at-time 3600 nil #'ignore))
            (puthash region-id timer ebox--scroll-idle-prefetch-timers)
            (let ((tp--surface-publication-step-function
                   (lambda (step _surface)
                     (when (eq step 'client-state)
                       (error "Reject all-affected viewport publication")))))
              (should-error (ebox-rerender-buffer-with-context buffer 200 7)))
            (should (eq state (ebox--buffer-render-state buffer)))
            (should (eq state (tp-surface-client-state surface)))
            (should (= revision (tp-surface-revision surface)))
            (should (equal-including-properties
                     contents (with-current-buffer buffer (buffer-string))))
            (should (eq scroll (gethash region-id (plist-get state :scroll-state-table))))
            (should (eq lines (plist-get scroll :content-lines)))
            (should (eq producer (plist-get scroll :render-content-prefix)))
            (should (eq timer (gethash region-id ebox--scroll-idle-prefetch-timers)))
            (should (memq timer timer-list))
            (should (equal host-position (ebox-host-ref-position buffer host-ref)))
            (should (equal host-bounds (ebox-host-ref-bounds buffer host-ref)))
            (cl-mapc (lambda (table key) (should (eq table (plist-get state key))))
                     indexes '(:node-table :parent-table :region-node-table
                               :surface-node-object-table))
            (cl-mapc (lambda (before after)
                       (should (= (hash-table-count before) (hash-table-count after)))
                       (maphash (lambda (key value)
                                  (should (equal-including-properties
                                           value (gethash key after))))
                                before))
                     index-contents indexes)
            (ebox-rerender-buffer-with-context buffer 200 7)
            (should (ebox-host-ref-position buffer host-ref))
            (should (equal-including-properties
                     (with-current-buffer buffer (buffer-string))
                     (ebox-viewport-topology-test--fresh-output
                      input (ebox--buffer-render-state buffer) 200 7)))))
      (when (timerp timer) (cancel-timer timer))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-viewport-topology-retains-public-range-and-host-addresses ()
  "An integration Range and its child Host remain addressable after resize."
  (let* ((buffer (generate-new-buffer " *ebox-viewport-range*"))
         (base (ebox-viewport-topology-test--nested-scroll (make-sparse-keymap)))
         (builder (ebox-source-builder-create))
         (handle (ebox-source-builder-bind builder :identity 'range-root))
         (range-ref (make-symbol "viewport-range"))
         (children (ebox-canonical-input-import-roots
                    base (ebox-canonical-input-roots base) builder))
         (input (ebox-canonical-input-create
                 (list (ebox-box-create
                        :source-handle handle :source-builder builder
                        :owned-facts (ebox-canonical-facts-from-declarations
                                      'box '(ebox/width (viewport)))
                        :layout (ebox-column-layout-create)
                        :children (list (apply #'ebox-child-range range-ref children))))
                 (ebox-source-builder-finish builder)))
         (host-ref (ebox-canonical-input-root-host-ref base))
         (ebox-viewport-width 120) (ebox-viewport-height 4)
         (ebox-runtime-idle-prewarm nil)
         (ebox-runtime-idle-reflow-cache-prewarm nil))
    (unwind-protect
        (cl-letf (((symbol-function 'ebox-native-reflow-layout-ready-p)
                   (lambda () nil)))
          (ebox-render-to-buffer buffer input)
          (should (ebox-range-ref-present-p buffer range-ref))
          (should (ebox-host-ref-position buffer host-ref))
          (let ((objects (copy-hash-table
                          (plist-get (ebox--buffer-render-state buffer)
                                     :surface-node-object-table))))
            (ebox-rerender-buffer-with-context buffer 200 7)
            (let ((state (ebox--buffer-render-state buffer)))
              (maphash (lambda (id object)
                         (should (eq object (gethash id (plist-get state :surface-node-object-table)))))
                       objects)
              (should (equal-including-properties
                       (with-current-buffer buffer (buffer-string))
                       (ebox-viewport-topology-test--fresh-output input state 200 7)))))
          (should (ebox-range-ref-present-p buffer range-ref))
          (should (ebox-host-ref-position buffer host-ref))
          (should (<= (plist-get (ebox-buffer-update-report buffer) :reconciled-objects) 4))
          (let ((candidate (ebox-candidate-begin buffer)))
            (ebox-candidate-replace-range-ref
             candidate range-ref (ebox-build '(text "Range replaced")))
            (ebox-commit buffer candidate))
          (should (ebox-range-ref-present-p buffer range-ref))
          (should (string-match-p "Range replaced" (with-current-buffer buffer (buffer-string)))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(provide 'ebox-viewport-topology-tests)
;;; ebox-viewport-topology-tests.el ends here
