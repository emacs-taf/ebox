;;; ebox-node-memo-generation-tests.el --- Node memo ownership -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)
(setq load-prefer-newer t)
(load-file (expand-file-name "../ebox.el"
                            (file-name-directory load-file-name)))

(defconst ebox-node-memo-test--keys
  '(:render-signature-cache :viewport-height-dependent-subtree-cache
    :flex-content-min-widths))

(defun ebox-node-memo-test--input (map)
  "Build an ordinary responsive Flex/Grid tree with nested scroll and MAP."
  (ebox-build
   `(column :width (viewport)
      (text "Header")
      (column :id "body" :width stretch :height (viewport-height)
              :overflow scroll :padding (0 (2))
        ,@(cl-loop
           for index below 6
           collect
           `(flex :width stretch :align-items stretch
              (box :flex-grow 1 :flex-basis (40) :wrap-mode char
                (text ,(propertize
                        (format "Open %02d %s" index (make-string 48 ?x))
                        'keymap map 'mouse-face 'highlight 'help-echo "Open row")))
              (grid :width (40) :grid-template-columns ((fr 1))
                (text "Tag")))))
      (text "Footer"))))

(defun ebox-node-memo-test--counts (state)
  "Return total/current/stale key counts for the node memos in STATE."
  (let ((current (make-hash-table :test 'eq)))
    (maphash (lambda (_ node) (puthash node t current))
             (plist-get state :node-table))
    (mapcar
     (lambda (key)
       (let ((memo (plist-get state key)) (live 0) (stale 0))
         (should (hash-table-p memo))
         (should (eq (hash-table-test memo) 'eq))
         (maphash (lambda (node _value)
                    (if (gethash node current) (cl-incf live) (cl-incf stale)))
                  memo)
         (list key :total (hash-table-count memo) :current live :stale stale)))
     ebox-node-memo-test--keys)))

(defmacro ebox-node-memo-test--with-mounted (&rest body)
  "Run BODY with a pure responsive fixture in BUFFER and INPUT."
  (declare (indent 0))
  `(let* ((buffer (generate-new-buffer " *ebox-node-memo-boundary*"))
          (map (make-sparse-keymap))
          (_key (define-key map [mouse-1] #'ignore))
          (input (ebox-node-memo-test--input map))
          (ebox-viewport-width 180) (ebox-viewport-height 6)
          (ebox-runtime-idle-prewarm nil)
          (ebox-runtime-idle-reflow-cache-prewarm nil))
     (unwind-protect
         (cl-letf (((symbol-function 'ebox-native-reflow-layout-ready-p)
                    (lambda () nil)))
           (ebox-render-to-buffer buffer input)
           ,@body)
       (when (buffer-live-p buffer) (kill-buffer buffer)))))

(defun ebox-node-memo-test--resize (count axes)
  "Repeat COUNT real viewport changes on AXES and check generation ownership."
  (let* ((buffer (generate-new-buffer " *ebox-node-memo*"))
         (map (make-sparse-keymap))
         (_key (define-key map [mouse-1] #'ignore))
         (input (ebox-node-memo-test--input map))
         (host (ebox-canonical-input-root-host-ref input))
         (ebox-viewport-width 180)
         (ebox-viewport-height 6)
         (ebox-runtime-idle-prewarm nil)
         (ebox-runtime-idle-reflow-cache-prewarm nil)
         history)
    (unwind-protect
        (cl-letf (((symbol-function 'ebox-native-reflow-layout-ready-p)
                   (lambda () nil)))
          (ebox-render-to-buffer buffer input)
          (let* ((initial-state (ebox--buffer-render-state buffer))
                 (initial-text (with-current-buffer buffer (buffer-string)))
                 (objects (copy-hash-table
                           (plist-get initial-state :surface-node-object-table)))
                 (node-count (hash-table-count (plist-get initial-state :node-table))))
            (should (ebox-host-ref-position buffer host))
            (push (cons 0 (ebox-node-memo-test--counts initial-state)) history)
            ;; A later cache hit may legitimately leave a node memo empty;
            ;; require real population at mount, not a forced fill each turn.
            (dolist (entry (cdar history))
              (should (> (plist-get (cdr entry) :current) 0)))
            (dotimes (iteration count)
              (let* ((alternate (= (% iteration 2) 0))
                     (width (if (and alternate (memq axes '(width both))) 220 180))
                     (height (if (and alternate (memq axes '(height both))) 9 6)))
                (ebox-rerender-buffer-with-context buffer width height)
                (let ((state (ebox--buffer-render-state buffer)))
                  (should (eq (plist-get (ebox-buffer-update-report buffer) :viewport-axes)
                              axes))
                  (should (= node-count (hash-table-count (plist-get state :node-table))))
                  (should (ebox-host-ref-position buffer host))
                  (maphash
                   (lambda (id object)
                     (should (eq object
                                 (gethash id (plist-get state :surface-node-object-table)))))
                   objects)
                  (push (cons (1+ iteration) (ebox-node-memo-test--counts state)) history))))
            ;; The sequence ends at A.  Keep the public text/property and Host
            ;; contracts independent of the memo-size assertion below.
            (should (equal-including-properties
                     initial-text (with-current-buffer buffer (buffer-string))))
            (with-current-buffer buffer
              (let* ((pos (string-match "Open 00" (buffer-string)))
                     (output (buffer-string)))
                (should pos)
                (should (eq (lookup-key (get-text-property pos 'keymap output)
                                       [mouse-1]) #'ignore))
                (should (equal (get-text-property pos 'help-echo output) "Open row"))))
            (setq history (nreverse history))
            (ert-info ((format "axes=%S nodes=%d history=%S" axes node-count history))
              (dolist (generation history)
                (dolist (entry (cdr generation))
                  (should (= (plist-get (cdr entry) :stale) 0))
                  (should (<= (plist-get (cdr entry) :total) node-count)))))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-node-memo-generation-width-eight-resizes ()
  "Eight width changes must not retain preceding generations' node keys."
  (ebox-node-memo-test--resize 8 'width))

(ert-deftest ebox-node-memo-generation-height-eight-resizes ()
  "Eight height changes must not retain preceding generations' node keys."
  (ebox-node-memo-test--resize 8 'height))

(ert-deftest ebox-node-memo-generation-both-twenty-four-resizes ()
  "Twenty-four two-axis changes keep memo ownership bounded to live nodes."
  (ebox-node-memo-test--resize 24 'both))

(ert-deftest ebox-node-memo-generation-scroll-signatures-match-current-body ()
  "Height changes after a real scroll retain only correct recursive facts."
  (ebox-node-memo-test--with-mounted
    (ebox-rerender-buffer-with-context buffer 180 3)
    (let* ((state (ebox--buffer-render-state buffer))
           (id (car (plist-get state :scroll-region-ids))))
      (should (= (ebox--surface-scroll-region-by buffer id 1 nil) 1))
      (setq state (ebox--buffer-render-state buffer))
      (should (= (plist-get (gethash id (plist-get state :scroll-state-table))
                            :scroll-offset) 1))
      ;; The memoizer accepts every current node, including a recursive root.
      ;; Populate a valid old fact through its real computation, not a mock.
      (let ((ebox--render-cache-signature-cache
             (plist-get state :render-signature-cache)))
        (ebox--render-cache-node-body-signature (plist-get state :root-node)))
      (ebox-rerender-buffer-with-context buffer 180 20)
      (setq state (ebox--buffer-render-state buffer))
      (let ((ebox--render-cache-signature-cache nil))
        (maphash
         (lambda (node cached)
           (ert-info ((format "Current node %S, scroll-offset=%S"
                              (plist-get node :node-id) (plist-get node :scroll-offset)))
             (should (equal cached (ebox--render-cache-node-body-signature node)))))
         (plist-get state :render-signature-cache))))))

(ert-deftest ebox-node-memo-generation-retains-canonical-region-index ()
  "Resize keeps offscreen regions and canonical owners across real cache hits."
  (let* ((buffer (generate-new-buffer " *ebox-node-memo-regions*"))
         (ebox-viewport-width 180) (ebox-viewport-height 6)
         (ebox-runtime-idle-prewarm nil)
         (ebox-runtime-idle-reflow-cache-prewarm nil)
         (input
          (ebox-build
           `(column :width (viewport)
              (box :id "fixed" :width (80) (box (text "Cached child")))
              (flex :width stretch
                (box :flex-grow 1 :flex-basis (40) (text "Allocated")))
              (column :width stretch :height 2 :overflow scroll
                ,@(cl-loop for index below 64 collect
                           `(box :height 1 (text ,(format "Row %02d" index))))))))
         (probe (symbol-function 'ebox--render-cache-probe))
         fixed-node-id cache-hits)
    (unwind-protect
        (cl-letf (((symbol-function 'ebox-native-reflow-layout-ready-p)
                   (lambda () nil)))
          (ebox-render-to-buffer buffer input)
          (setq fixed-node-id
                (plist-get (car (ebox-selector-query-buffer buffer "#fixed"))
                           :node-id))
          (should fixed-node-id)
          (cl-letf (((symbol-function 'ebox--render-cache-probe)
                     (lambda (node &rest args)
                       (let ((result (apply probe node args)))
                         (when (and (equal (plist-get node :node-id) fixed-node-id)
                                    (plist-get result :rendered))
                           (push t cache-hits))
                         result))))
            (dolist (width '(220 180))
              (ebox-rerender-buffer-with-context buffer width 6)
              (let* ((state (ebox--buffer-render-state buffer))
                     (regions (plist-get state :region-box-table))
                     (ids (plist-get state :region-id-set))
                     (nodes (plist-get state :node-table))
                     (scroll (gethash (car (plist-get state :scroll-region-ids))
                                      (plist-get state :scroll-state-table))))
                (should scroll)
                (should-not (plist-get scroll :content-lines-complete-p))
                (should-not (with-current-buffer buffer
                              (string-match-p "Row 63" (buffer-string))))
                (should (= (hash-table-count regions) (hash-table-count ids)))
                (maphash
                 (lambda (id _)
                   (let ((box (gethash id regions)))
                     (should box)
                     (should (eq box (gethash (plist-get box :node-id) nodes)))))
                 ids))))
          (should cache-hits))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-node-memo-generation-seed-preserves-nil-and-zero ()
  "Seeding reads the exact current source key, including cached nil or zero."
  (dolist (value '(nil 0))
    (let* ((source (list :node-id 1))
           (orphan (list :node-id 1))
           (candidate (list :node-id 1))
           (old-nodes (make-hash-table :test 'eql))
           (new-nodes (make-hash-table :test 'eql))
           (memo (make-hash-table :test 'eq))
           (missing (make-symbol "missing")))
      (puthash 1 source old-nodes)
      (puthash 1 candidate new-nodes)
      (puthash source value memo)
      (puthash orphan 'poison memo)
      (let ((seeded (ebox-incremental--seed-candidate-node-cache
                     memo old-nodes new-nodes)))
        (should (= (hash-table-count seeded) 1))
        (should (eq (gethash candidate seeded missing) value))
        (should (eq (gethash orphan seeded missing) missing)))
      (remhash source memo)
      (should (= (hash-table-count
                  (ebox-incremental--seed-candidate-node-cache
                   memo old-nodes new-nodes)) 0)))))

(ert-deftest ebox-node-memo-generation-isolates-persistent-caches-only ()
  "Viewport cache isolation leaves node memo policy to the source-copy boundary."
  (let* ((signature (make-hash-table :test 'eq))
         (height (make-hash-table :test 'eq))
         (width (make-hash-table :test 'eq))
         (render (make-hash-table :test 'equal))
         (fragments (make-hash-table :test 'equal))
         (overrides (list :render-signature-cache signature
                          :viewport-height-dependent-subtree-cache height
                          :flex-content-min-widths width :render-cache render
                          :layout-fragments fragments))
         (first (ebox-surface--isolated-viewport-overrides overrides))
         (second (ebox-surface--isolated-viewport-overrides overrides)))
    (dolist (key '(:render-cache :layout-fragments))
      (should-not (eq (plist-get first key) (plist-get overrides key)))
      (should-not (eq (plist-get second key) (plist-get first key))))
    (dolist (key ebox-node-memo-test--keys)
      (should (eq (plist-get first key) (plist-get overrides key)))
      (should (eq (plist-get second key) (plist-get overrides key))))))

(ert-deftest ebox-node-memo-generation-does-not-copy-historical-memo-keys ()
  "Thirty thousand same-ID orphans per memo do not enter viewport table copies."
  (ebox-node-memo-test--with-mounted
    (let* ((state (ebox--buffer-render-state buffer))
           (id (plist-get (plist-get state :root-node) :node-id))
           (memos (mapcar (lambda (key) (plist-get state key)) ebox-node-memo-test--keys))
           (initial (with-current-buffer buffer (buffer-string)))
           (copy-function (symbol-function 'copy-hash-table))
           copied-memo-sizes)
      (dolist (memo memos)
        (dotimes (index 30000)
          (puthash (list :node-id id :orphan index) 'poison memo)))
      (let ((sizes (mapcar #'hash-table-count memos)))
        (cl-letf (((symbol-function 'copy-hash-table)
                   (lambda (table)
                     (when (memq table memos)
                       (push (hash-table-count table) copied-memo-sizes))
                     (funcall copy-function table))))
          (ebox-rerender-buffer-with-context buffer 220 9)
          (ebox-rerender-buffer-with-context buffer 180 6))
        (should-not copied-memo-sizes)
        (should (equal sizes (mapcar #'hash-table-count memos))))
      (should (equal-including-properties
               initial (with-current-buffer buffer (buffer-string))))
      (dolist (entry (ebox-node-memo-test--counts (ebox--buffer-render-state buffer)))
        (should (= (plist-get (cdr entry) :stale) 0))
        (should (<= (plist-get (cdr entry) :total) 34))))))

(ert-deftest ebox-node-memo-generation-context-miss-starts-fresh ()
  "Display and stylesheet proof misses get fresh node memos before rendering."
  (dolist (change '(display style))
    (let ((ebox-style-stylesheet (ecss-stylesheet-create)))
      (ebox-style-add-rule "#body" '(:background-color "#ddeeff") :layer 'base)
      (ebox-node-memo-test--with-mounted
        (let ((render (symbol-function 'ebox-surface--render-candidate))
              (display (symbol-function 'ebox--display-signature-for-window))
              (seen nil))
          (when (eq change 'style)
            (ebox-style-add-rule "#body" '(:background-color "#112233") :layer 'base))
          (cl-letf (((symbol-function 'ebox--display-signature-for-window)
                     (lambda (window)
                       (if (eq change 'display) '(ebox-node-memo-display changed)
                         (funcall display window))))
                    ((symbol-function 'ebox-surface--render-candidate)
                     (lambda (state)
                       (push t seen)
                       (dolist (key ebox-node-memo-test--keys)
                         (should (= (hash-table-count (plist-get state key)) 0)))
                       (funcall render state))))
            (ebox-rerender-buffer-with-context buffer 220 9))
          (should seen)
          (should-not (plist-get (ebox-buffer-update-report buffer) :projection-kind))
          (let* ((state (ebox--buffer-render-state buffer))
                 (ebox-viewport-width 220) (ebox-viewport-height 9)
                 (fresh-input (ebox-canonical-input-create
                               (list (plist-get state :root-node))
                               (plist-get state :source-index))))
            (should (equal-including-properties
                     (with-current-buffer buffer (buffer-string)) (ebox-render fresh-input)))
            (dolist (entry (ebox-node-memo-test--counts state))
              (should (= (plist-get (cdr entry) :stale) 0)))))))))

(ert-deftest ebox-node-memo-generation-failed-producers-own-private-tables ()
  "Late failures preserve source memo entries; every retry gets private tables."
  (ebox-node-memo-test--with-mounted
    (let* ((old (ebox--buffer-render-state buffer))
           (surface (plist-get old :surface))
           (revision (tp-surface-revision surface))
           (initial (with-current-buffer buffer (buffer-string)))
           (memos (mapcar (lambda (key) (plist-get old key)) ebox-node-memo-test--keys))
           (snapshots (mapcar (lambda (memo)
                                (let ((copy (copy-hash-table memo)))
                                  (maphash (lambda (node value)
                                             (puthash node (copy-tree value t) copy)) memo)
                                  copy)) memos))
           (render (symbol-function 'ebox-surface--render-candidate))
           produced-tables)
      (cl-letf (((symbol-function 'ebox-surface--render-candidate)
                 (lambda (state)
                   (dolist (key ebox-node-memo-test--keys)
                     (should (= (hash-table-count (plist-get state key)) 0)))
                   (let ((tables (mapcar (lambda (key) (plist-get state key))
                                         ebox-node-memo-test--keys)))
                     (dolist (previous (cons memos produced-tables))
                       (cl-mapc (lambda (a b) (should-not (eq a b))) tables previous))
                     (push tables produced-tables))
                   (let ((output (funcall render state)))
                     (dolist (entry (ebox-node-memo-test--counts state))
                       (should (= (plist-get (cdr entry) :stale) 0)))
                     output))))
        (dotimes (_ 2)
          (let ((tp--surface-publication-step-function
                 (lambda (step _surface)
                   (when (eq step 'client-state) (error "Reject memo candidate")))))
            (should-error (ebox-rerender-buffer-with-context buffer 220 9)))
          (should (eq old (ebox--buffer-render-state buffer)))
          (should (= revision (tp-surface-revision surface)))
          (should (equal-including-properties
                   initial (with-current-buffer buffer (buffer-string)))))
        (ebox-rerender-buffer-with-context buffer 220 9))
      (should (= (length produced-tables) 3))
      (cl-mapc (lambda (memo before)
                 (should (= (hash-table-count memo) (hash-table-count before)))
                 (maphash (lambda (node value)
                            (should (equal-including-properties value (gethash node memo))))
                          before)) memos snapshots)
      (should (ebox-host-ref-position buffer (ebox-canonical-input-root-host-ref input))))))

(ert-deftest ebox-node-memo-generation-same-fallback-producer-owns-fresh-memos ()
  "Repeated evaluation of one fallback closure must not write captured memos."
  (ebox-node-memo-test--with-mounted
    (let* ((old (ebox--buffer-render-state buffer))
           (display '(ebox-node-memo-display fallback))
           ;; Prepare once.  A changed display requires the ordinary fallback.
           (prepared (ebox-incremental-prepare-viewport-commit
                      buffer 220 9 'both display t))
           (overrides (plist-get prepared :state-overrides))
           (source-memos (mapcar (lambda (key) (plist-get overrides key))
                                ebox-node-memo-test--keys))
           (sizes (mapcar #'hash-table-count source-memos))
           (root (plist-get prepared :root))
           ;; Both public materializations below invoke this exact closure.
           (producer (ebox-surface-producer root old t overrides))
           (render (symbol-function 'ebox-surface--render-candidate))
           states history outputs first-memos first-snapshots)
      (should-not (plist-get prepared :projection-kind))
      (cl-letf (((symbol-function 'ebox-surface--render-candidate)
                 (lambda (state)
                   (let ((output (funcall render state)))
                     (push state states)
                     (push (ebox-node-memo-test--counts state) history)
                     (unless first-memos
                       (setq first-memos
                             (mapcar (lambda (key) (plist-get state key))
                                     ebox-node-memo-test--keys)
                             first-snapshots
                             (mapcar (lambda (memo)
                                       (let ((copy (copy-hash-table memo)))
                                         (maphash
                                          (lambda (node value)
                                            (puthash node (copy-tree value t) copy))
                                          memo)
                                         copy)) first-memos)))
                     output))))
        (dotimes (_ 2)
          (push (tp-surface-materialize-string producer) outputs)))
      (should (= (length states) 2))
      (should-not (eq (plist-get (car states) :root-node)
                      (plist-get (cadr states) :root-node)))
      (should (equal-including-properties (car outputs) (cadr outputs)))
      (let ((reference
             (tp-surface-materialize-string
              (ebox-surface-producer
               root old t
               (list :viewport-width 220 :viewport-height 9
                     :display-signature display
                     :source-base-index (plist-get old :source-index))))))
        (should (equal-including-properties (car outputs) reference)))
      (let* ((output (car outputs))
             (position (string-match "Open 00" output)))
        (should position)
        (should (eq (lookup-key (get-text-property position 'keymap output)
                                [mouse-1]) #'ignore)))
      (ert-info ((format "same closure, captured sizes %S -> %S; history %S"
                         sizes (mapcar #'hash-table-count source-memos) history))
        (should (equal sizes (mapcar #'hash-table-count source-memos)))
        (dolist (key ebox-node-memo-test--keys)
          (should-not (eq (plist-get (car states) key) (plist-get overrides key)))
          (should-not (eq (plist-get (car states) key) (plist-get (cadr states) key))))
        (cl-mapc
         (lambda (memo before)
           (should (= (hash-table-count memo) (hash-table-count before)))
           (maphash (lambda (node value)
                      (should (equal-including-properties value (gethash node memo))))
                    before)) first-memos first-snapshots)
        (dolist (generation history)
          (dolist (entry generation)
            (should (= (plist-get (cdr entry) :stale) 0))))))))

(provide 'ebox-node-memo-generation-tests)
;;; ebox-node-memo-generation-tests.el ends here
