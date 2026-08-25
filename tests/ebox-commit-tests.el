;;; ebox-commit-tests.el --- Declarative commit smoke tests -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)
(require 'ebox)
(require 'ebox-native-commit)

;; These tests lock the named Elisp projection proofs.  Native commit has its
;; own focused contract tests below; disable runtime module discovery here so
;; a locally built optional module cannot silently replace paint/span/mixed
;; plans with `native-frame' and make this suite environment-dependent.
(setq ebox-native-reflow-module-path nil)

(defun ebox-commit-test--buffer-string (buffer)
  "Return BUFFER's complete propertized contents."
  (with-current-buffer buffer
    (save-restriction
      (widen)
      (buffer-substring (point-min) (point-max)))))

(ert-deftest ebox-native-fragment-style-delta-copies-only-changed-records ()
  "A native style delta keeps the retained template immutable."
  (let* ((first [0 1 0 nil nil nil nil (1)])
         (second [1 2 0 nil nil nil nil (2)])
         (template (vector first second))
         (target
          (ebox-native-commit--apply-fragment-style-delta
           template '((1 3 5)))))
    (should (eq (aref target 0) first))
    (should-not (eq (aref target 1) second))
    (should (equal (aref (aref target 1) 7) '(3 5)))
    (should (equal (aref second 7) '(2)))))

(ert-deftest ebox-native-object-delta-orders-moved-and-new-nodes ()
  "A topology delta names parents before moved and introduced children."
  (let* ((old-root
          (ebox-column (ebox-create :key 'a :content "A")
                       (ebox-create :key 'b :content "B")))
         (_old-ids (ebox--runtime-node-ids old-root))
         (old-index (ebox--runtime-index old-root t))
         (old-objects (make-hash-table :test 'equal))
         (new-root
          (ebox-column (ebox-create :key 'b :content "B")
                       (ebox-create :key 'a :content "A")
                       (ebox-create :key 'c :content "C")))
         (_reconciled (ebox-tree-reconcile-runtime old-root new-root))
         (new-index (ebox--runtime-index new-root t))
         (root-id (plist-get old-root :node-id)))
    (maphash (lambda (node-id _node)
               (puthash node-id (list 'object node-id) old-objects))
             (plist-get old-index :node-table))
    (let* ((old-state (append (list :root-node old-root
                                    :surface-node-object-table old-objects)
                              old-index))
           (new-state (append (list :root-node new-root) new-index))
           (delta
            (ebox-native-commit-object-delta-node-ids
             old-state new-state
             (list :touched-node-ids (list root-id)
                   :removed-node-ids nil)))
           (children (ebox-tree--children-raw new-root)))
      (should
       (equal delta
              (cons root-id (mapcar (lambda (node)
                                      (plist-get node :node-id))
                                    children)))))))

(ert-deftest ebox-native-object-delta-requires-complete-removal-proof ()
  "An unreported disappeared object rejects the native topology delta."
  (let* ((old-root
          (ebox-column (ebox-create :key 'a :content "A")
                       (ebox-create :key 'tail :content "T")
                       (ebox-create :key 'b :content "B")))
         (_old-ids (ebox--runtime-node-ids old-root))
         (old-index (ebox--runtime-index old-root t))
         (old-objects (make-hash-table :test 'equal))
         (removed-node (car (last (ebox-tree--children-raw old-root))))
         (new-root
          (ebox-column (ebox-create :key 'a :content "A")
                       (ebox-create :key 'tail :content "T")))
         (_reconciled (ebox-tree-reconcile-runtime old-root new-root))
         (new-index (ebox--runtime-index new-root t))
         (root-id (plist-get old-root :node-id)))
    (maphash (lambda (node-id _node)
               (puthash node-id (list 'object node-id) old-objects))
             (plist-get old-index :node-table))
    (let ((old-state (append (list :root-node old-root
                                   :surface-node-object-table old-objects)
                             old-index))
          (new-state (append (list :root-node new-root) new-index)))
      (should-not
       (ebox-native-commit-object-delta-node-ids
        old-state new-state
        (list :touched-node-ids (list root-id)
              :removed-node-ids nil)))
      (should
       (equal
        (list root-id)
        (ebox-native-commit-object-delta-node-ids
         old-state new-state
         (list :touched-node-ids (list root-id)
               :removed-node-ids
               (list (plist-get removed-node :node-id)))))))))

(ert-deftest ebox-style-schema-registration-is-not-per-node-copy ()
  "Repeated node construction must not copy the whole ECSS schema domain."
  (let ((calls 0)
        (original (symbol-function 'ecss-schema-set-property)))
    (cl-letf (((symbol-function 'ecss-schema-set-property)
               (lambda (&rest arguments)
                 (cl-incf calls)
                 (apply original arguments))))
      (dotimes (_ 24)
        (ebox-create :content "schema-hot-path" :color "#111111")))
    (should (= calls 0))))

(ert-deftest ebox-style-declaration-compilation-is-memoized ()
  "Repeated equivalent style declarations compile through ECSS once."
  (clrhash ebox-style--declaration-cache)
  (let ((calls 0)
        (original (symbol-function 'ecss-merge-declarations)))
    (cl-letf (((symbol-function 'ecss-merge-declarations)
               (lambda (&rest arguments)
                 (cl-incf calls)
                 (apply original arguments))))
      (dotimes (_ 24)
        (ebox-style-compile-declarations
         '(:color "#111111" :bgcolor "#222222"))))
    (should (= calls 1))))

(ert-deftest ebox-commit-publishes-content-change ()
  "A declarative commit should publish changed content."
  (let* ((buffer (ebox-render-to-buffer
                  (generate-new-buffer-name " *ebox-commit-content*")
                  (ebox-create :key 'root :content "Before" :width '(80))))
         (report (ebox-commit
                  buffer
                  (ebox-create :key 'root :content "After" :width '(80)))))
    (unwind-protect
        (progn
          (should (string-prefix-p
                   "After"
                   (string-trim-right
                    (substring-no-properties
                     (ebox-commit-test--buffer-string buffer)))))
          (should (plist-get report :runtime-published))
          (should (> (plist-get report :patch-count) 0)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-commit-preserves-keyed-sibling-identity ()
  "Keyed siblings should remain addressable after a reorder commit."
  (let* ((buffer (ebox-render-to-buffer
                  (generate-new-buffer-name " *ebox-commit-keyed*")
                  (ebox-column
                   (ebox-create :key 'a :host-ref 'a :content "A" :width '(40))
                   (ebox-create :key 'b :host-ref 'b :content "B" :width '(40)))))
         (old-b (ebox-host-ref-position buffer 'b))
         (report (ebox-commit
                  buffer
                  (ebox-column
                   (ebox-create :key 'b :host-ref 'b :content "B2" :width '(40))
                   (ebox-create :key 'a :host-ref 'a :content "A" :width '(40))))))
    (unwind-protect
        (progn
          (should old-b)
          (should (ebox-host-ref-position buffer 'b))
          (should (plist-get report :runtime-published))
          (should (string-match-p "B2"
                                  (substring-no-properties
                                   (ebox-commit-test--buffer-string buffer)))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-candidate-root-replacement-is-last-wins-and-absorbing ()
  "The private root address absorbs descendant operations without ref overlap."
  (let* ((buffer
          (ebox-render-to-buffer
           (generate-new-buffer-name " *ebox-root-candidate*")
           (ebox-column
            (ebox-create :key 'a :host-ref 'a :content "A" :width '(40))
            (ebox-create :key 'b :host-ref 'b :content "B" :width '(40)))))
         (surface (with-current-buffer buffer ebox-surface--buffer-surface))
         (revision (tp-surface-revision surface))
         (candidate (ebox-candidate-begin buffer)))
    (unwind-protect
        (progn
          (ebox-candidate-replace-host-ref
           candidate 'a (ebox-create :key 'a :content "ignored-before"))
          (ebox-candidate-replace-root
           candidate
           (ebox-create :key 'root :host-ref 'a :content "first-root"
                        :width '(80)))
          (ebox-candidate-replace-host-ref
           candidate 'b (ebox-create :key 'b :content "ignored-after"))
          (ebox-candidate-replace-root
           candidate
           (ebox-create :key 'root :host-ref 'b :content "final-root"
                        :width '(80)))
          (should (= (length (ebox-candidate--replacements candidate)) 1))
          (let ((report (ebox-commit buffer candidate)))
            (should (string-match-p
                     "final-root"
                     (substring-no-properties
                      (ebox-commit-test--buffer-string buffer))))
            (should-not (string-match-p
                         "ignored"
                         (substring-no-properties
                          (ebox-commit-test--buffer-string buffer))))
            (should (= (tp-surface-revision surface) (1+ revision)))
            (should (plist-get report :runtime-published)))
          (should-error
           (ebox-candidate-replace-root
            candidate (ebox-create :key 'root :content "sealed"))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-commit-framework-participant-completes-and-rolls-back ()
  "Framework publication is paired, diagnosed, and completed exactly once."
  (let ((buffer (generate-new-buffer " *ebox-framework-participant*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer
              buffer (ebox-create :key 'root :content "old" :width '(80)))
          (let (trace)
            (let ((report
                   (ebox-commit
                    buffer (ebox-create :key 'root :content "new" :width '(80))
                    (lambda (_report) (push 'publish trace))
                    (lambda (_report) (push 'rollback trace)))))
              (should (equal trace '(publish)))
              (should (eq (plist-get report :framework-participant-state)
                          'completed))
              (should-not
               (plist-get report :framework-participant-diagnostics))))
          (let* ((before (ebox-commit-test--buffer-string buffer))
                 (original
                  (symbol-function 'tp--run-transaction-precommit-functions))
                 trace captured failure)
            (cl-letf
                (((symbol-function 'tp--run-transaction-precommit-functions)
                  (lambda ()
                    (funcall original)
                    (error "later TP failure"))))
              (setq failure
                    (condition-case condition
                        (ebox-commit
                         buffer
                         (ebox-create :key 'root :content "rejected"
                                      :width '(80))
                         (lambda (report)
                           (setq captured report)
                           (push 'publish trace))
                         (lambda (_report)
                           (push 'rollback trace)
                           (error "rollback diagnostic")))
                      (error condition))))
            (should (equal trace '(rollback publish)))
            (should (equal (cadr failure) "later TP failure"))
            (should (equal-including-properties
                     (ebox-commit-test--buffer-string buffer) before))
            (should (eq (plist-get captured :framework-participant-state)
                        'rolled-back))
            (should (= (length
                        (plist-get
                         captured :framework-participant-diagnostics))
                       1))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-commit-framework-publish-failure-rolls-back-full-and-scoped ()
  "A framework publish failure invokes its pair once on both commit paths."
  (dolist (mode '(full scoped))
    (let ((buffer (generate-new-buffer " *ebox-framework-publish-fail*")))
      (unwind-protect
          (progn
            (ebox-render-to-buffer
                buffer
              (ebox-column
               (ebox-create :key 'a :host-ref 'a :content "old-a" :width '(40))
               (ebox-create :key 'b :host-ref 'b :content "old-b" :width '(40))))
            (let ((before (ebox-commit-test--buffer-string buffer))
                  (candidate (ebox-candidate-begin buffer))
                  trace captured)
              (when (eq mode 'scoped)
                (ebox-candidate-replace-host-ref
                 candidate 'a
                 (ebox-create :key 'a :host-ref 'a :content "new-a"
                              :width '(40))))
              (should-error
               (ebox-commit
                buffer
                (if (eq mode 'scoped)
                    candidate
                  (ebox-create :key 'root :content "new-root" :width '(80)))
                (lambda (report)
                  (setq captured report)
                  (push 'publish trace)
                  (error "framework publish failed"))
                (lambda (_report) (push 'rollback trace))))
              (should (equal trace '(rollback publish)))
              (should (eq (plist-get captured :framework-participant-state)
                          'rolled-back))
              (should (equal-including-properties
                       (ebox-commit-test--buffer-string buffer) before))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest ebox-commit-framework-argument-validation ()
  "Four-argument framework callbacks have an exact paired contract."
  (let ((buffer (generate-new-buffer " *ebox-framework-validation*"))
        (root (ebox-create :key 'root :content "x")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer buffer root)
          (should-error (ebox-commit buffer root 7) :type 'wrong-type-argument)
          (should-error
           (ebox-commit buffer root nil #'ignore))
          (should-error
           (ebox-commit buffer root #'ignore 7)
           :type 'wrong-type-argument))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-commit-expands-scope-for-length-changing-column-content ()
  "A column content growth must publish shifted later styled siblings."
  (let* ((buffer (generate-new-buffer-name " *ebox-commit-column-scope*"))
         (old-root
          (ebox-column
           (ebox-create :key 'panel :padding '(1 (2))
                        :border "#687386" :bgcolor "#FFFDF8"
                        :content "Panel")
           (ebox-create :key 'payload :padding '(0 (1))
                        :border "#AAA" :content "No payload yet.")
           (ebox-create :key 'later :padding '(0 (1))
                        :border "#BBB" :content "Later sibling")))
         (new-root
          (ebox-column
           (ebox-create :key 'panel :padding '(1 (2))
                        :border "#687386" :bgcolor "#FFFDF8"
                        :content "Panel")
           (ebox-create :key 'payload :padding '(0 (1))
                        :border "#AAA"
                        :content "Payload received: payload=42")
           (ebox-create :key 'later :padding '(0 (1))
                        :border "#BBB" :content "Later sibling")))
         (report nil))
    (unwind-protect
        (progn
          (ebox-render-to-buffer buffer old-root)
          (setq report (ebox-commit buffer new-root))
          (should (string-match-p
                   "Payload received: payload=42"
                   (with-current-buffer buffer (buffer-string))))
          (should (string-match-p "Later sibling"
                                  (with-current-buffer buffer (buffer-string))))
          (should (eq (plist-get report :strategy) 'owner-rerender))
          (should (equal (plist-get report :patch-ops) '(owner-rerender)))
          (should-not (plist-get report :tp-scope-fallback)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-commit-reuses-unchanged-style-computations ()
  "A content-only commit should not recompute unchanged retained styles."
  (let* ((ebox-style-stylesheet (ecss-stylesheet-create))
         (calls 0)
         (original (symbol-function 'ecss-compute-style))
         (buffer nil))
    (ebox-style-add-rule ".card" '(:color "#111111") :layer 'components)
    (unwind-protect
        (progn
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-commit-style-cache*")
                 (ebox-column
                  (ebox-create :key 'first :class "card" :content "Before"
                               :width '(40))
                  (ebox-create :key 'second :class "card" :content "Stable"
                               :width '(40)))))
          (setq calls 0)
          (cl-letf (((symbol-function 'ecss-compute-style)
                     (lambda (&rest arguments)
                       (cl-incf calls)
                       (apply original arguments))))
            (ebox-commit
             buffer
             (ebox-column
              (ebox-create :key 'first :class "card" :content "After"
                           :width '(40))
              (ebox-create :key 'second :class "card" :content "Stable"
                           :width '(40))))
            (should (= calls 0))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-commit-builds-one-selector-tree-snapshot ()
  "A styled commit should snapshot selector context once for the whole tree."
  (let* ((ebox-style-stylesheet (ecss-stylesheet-create))
         (calls 0)
         (original (symbol-function 'ebox-surface--subject-signature))
         (buffer nil))
    (ebox-style-add-rule ".card" '(:color "#111111") :layer 'components)
    (unwind-protect
        (progn
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-commit-selector-snapshot*")
                 (ebox-column
                  (ebox-create :key 'first :class "card" :content "Before"
                               :width '(40))
                  (ebox-create :key 'second :class "card" :content "Stable"
                               :width '(40)))))
          (cl-letf (((symbol-function 'ebox-surface--subject-signature)
                     (lambda (&rest arguments)
                       (cl-incf calls)
                       (apply original arguments))))
            (ebox-commit
             buffer
             (ebox-column
              (ebox-create :key 'first :class "card" :content "After"
                           :width '(40))
              (ebox-create :key 'second :class "card" :content "Stable"
                           :width '(40))))
            (should (= calls 1))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-commit-reuses-local-selector-styles-across-tree-change ()
  "A subject-local stylesheet should compute only newly inserted node styles."
  (let* ((ebox-style-stylesheet (ecss-stylesheet-create))
         (calls 0)
         (original (symbol-function 'ecss-compute-style))
         (buffer nil))
    (ebox-style-add-rule ".card" '(:color "#2255AA") :layer 'components)
    (unwind-protect
        (progn
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-local-selector-reuse*")
                 (ebox-column
                  (ebox-create :key 'first :class "card" :content "First"
                               :width '(40))
                  (ebox-create :key 'second :class "card" :content "Second"
                               :width '(40)))))
          (cl-letf (((symbol-function 'ecss-compute-style)
                     (lambda (&rest arguments)
                       (cl-incf calls)
                       (apply original arguments))))
            (ebox-commit
             buffer
             (ebox-column
              (ebox-create :key 'first :class "card" :content "First"
                           :width '(40))
              (ebox-create :key 'second :class "card" :content "Second"
                           :width '(40))
              (ebox-create :key 'third :class "card" :content "Third"
                           :width '(40)))))
          (should (= calls 1))
          (let* ((text (ebox-commit-test--buffer-string buffer))
                 (position (string-match "Third" text)))
            (should position)
            (should (equal (plist-get (get-text-property position 'face text)
                                      :foreground)
                           "#2255AA"))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-commit-reuses-successful-allocation-certificate ()
  "A repeated fixed-slot update must not rescan unchanged ancestor spans."
  (let* ((ebox-style-stylesheet (ecss-stylesheet-create))
         (buffer nil)
         (ancestor-scans 0))
    (ebox-style-add-rule ".card" '(:color "#111111") :layer 'components)
    (unwind-protect
        (progn
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-allocation-certificate*")
                 (ebox-build
                  '(grid :width (100) :height 2
                    :grid-template-columns (1fr 1fr)
                    (column :key card-shell :width stretch :height 2
                     (box :key card :class "card" :host-ref target
                          :content "Before" :width (40)))
                    (box :key stable :content "Stable"
                         :width (40) :height 1)))))
          (let ((first (ebox-candidate-begin buffer)))
            (ebox-candidate-replace-host-ref
             first 'target
             (ebox-create :key 'card :class "card" :host-ref 'target
                          :content "Middle" :width '(40)))
            (should (eq (plist-get (ebox-commit buffer first)
                                   :projection-kind)
                        'owner-scoped)))
          (let* ((state (ebox--buffer-render-state buffer))
                 (certificates
                  (plist-get state :retained-allocation-certificates)))
            (should (hash-table-p certificates))
            (should (= 1 (hash-table-count certificates))))
          (let ((second (ebox-candidate-begin buffer))
                (original
                 (symbol-function
                  'ebox-incremental--compute-ancestor-slot-signature)))
            (ebox-candidate-replace-host-ref
             second 'target
             (ebox-create :key 'card :class "card" :host-ref 'target
                          :content "After" :width '(40)))
            (cl-letf
                (((symbol-function
                   'ebox-incremental--compute-ancestor-slot-signature)
                  (lambda (&rest arguments)
                    (cl-incf ancestor-scans)
                    (apply original arguments))))
              (should (eq (plist-get (ebox-commit buffer second)
                                     :projection-kind)
                          'owner-scoped))))
          (should (= ancestor-scans 0))
          (should
           (string-match-p
            "After"
            (substring-no-properties
             (ebox-commit-test--buffer-string buffer)))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-commit-invalidates-selector-tree-token-for-sibling-change ()
  "A sibling metadata change must invalidate retained selector computations."
  (let* ((ebox-style-stylesheet (ecss-stylesheet-create))
         (buffer nil))
    (ebox-style-add-rule ".active + .target" '(:color "#2255AA")
                         :layer 'components)
    (unwind-protect
        (progn
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-commit-selector-change*")
                 (ebox-column
                  (ebox-create :key 'state :class "inactive" :content "State"
                               :width '(40))
                  (ebox-create :key 'target :class "target" :content "Target"
                               :width '(40)))))
          (let* ((before (ebox-commit-test--buffer-string buffer))
                 (position (string-match "Target" before)))
            (should position)
            (should-not (get-text-property position 'face before)))
          (ebox-commit
           buffer
           (ebox-column
            (ebox-create :key 'state :class "active" :content "State"
                         :width '(40))
            (ebox-create :key 'target :class "target" :content "Target"
                         :width '(40))))
          (let* ((after (ebox-commit-test--buffer-string buffer))
                 (position (string-match "Target" after)))
            (should position)
            (should (equal (plist-get (get-text-property position 'face after)
                                      :foreground)
                           "#2255AA"))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-commit-observes-in-place-stylesheet-changes ()
  "A retained commit must refresh when its stylesheet changes in place."
  (let* ((ebox-style-stylesheet (ecss-stylesheet-create))
         (buffer nil))
    (ebox-style-add-rule ".card" '(:color "#111111") :layer 'components)
    (unwind-protect
        (progn
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-commit-style-rule*")
                 (ebox-create :key 'card :class "card" :content "Stable"
                              :width '(40))))
          (should (equal (plist-get (get-text-property
                                     (point-min) 'face buffer) :foreground)
                         "#111111"))
          (ebox-style-add-rule ".card" '(:color "#222222") :layer 'components)
          (ebox-commit
           buffer
           (ebox-create :key 'card :class "card" :content "Stable"
                        :width '(40)))
          (should (equal (plist-get (get-text-property
                                     (point-min) 'face buffer) :foreground)
                         "#222222")))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-commit-observes-cascade-activation-during-content-change ()
  "A commit must not span-patch across an inactive-to-active cascade change."
  (let* ((ebox-style-stylesheet (ecss-stylesheet-create))
         (buffer nil))
    (unwind-protect
        (progn
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-commit-cascade-activation*")
                 (ebox-create :key 'card :class "card" :content "Before"
                              :width '(40))))
          (should-not (get-text-property (point-min) 'face buffer))
          (ebox-style-add-rule ".card" '(:color "#2255AA")
                               :layer 'components)
          (let ((report
                 (ebox-commit
                  buffer
                  (ebox-create :key 'card :class "card" :content "After"
                               :width '(40)))))
            (should (string-prefix-p
                     "After"
                     (string-trim-right
                      (substring-no-properties
                       (ebox-commit-test--buffer-string buffer)))))
            (should-not (eq (plist-get report :strategy) 'span-patch))
            (should (equal (plist-get (get-text-property
                                       (point-min) 'face buffer) :foreground)
                           "#2255AA"))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-commit-uses-static-cascade-owner-proof ()
  "A static cascade content commit may plan its local owner."
  (let* ((ebox-style-stylesheet (ecss-stylesheet-create))
         (calls 0)
         (ensured 0)
         (rendered nil)
         (buffer nil))
    (ebox-style-add-rule ".card" '(:color "#111111") :layer 'components)
    (unwind-protect
        (progn
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-commit-proof-cache*")
                 (ebox-build
                  '(column :width (100) :height 4
                    (column :key main :width (100) :height 2
                     (grid :key grid :width (100) :height 2
                      :grid-template-columns (1fr 1fr)
                      (column :key card-shell :width stretch :height 2
                       (box :key card :class "card" :host-ref target
                            :content "Before"))
                      (box :key stable :content "Stable"
                           :width (40) :height 1)))
                    (box :key footer :content "Footer"
                         :width (100) :height 1)))))
          (let* ((state (ebox--buffer-render-state buffer))
                 (style-states (plist-get state :style-binding-states))
                 (binding-state
                  (cl-loop for value being the hash-values of style-states
                           when (and (plist-get value :declarations)
                                     (plist-get value :parent-style-state)
                                     (ebox-surface--static-style-state-p value))
                           return value)))
            (should binding-state)
            (should (tp-binding-live-p (plist-get binding-state :binding)))
            (should (plist-get binding-state :parent-style-state))
            (should (= 1 (plist-get binding-state
                                    :inherited-dependency-count)))
            (should (= 1 (tp-binding-dependency-count
                          (plist-get binding-state :binding))))
            (should (ebox-surface--static-style-state-p binding-state)))
          (let ((original
                 (symbol-function 'ebox-incremental--layout-owner-plan))
                (original-ensure
                 (symbol-function 'ebox-surface--ensure-node-tree))
                (original-render (symbol-function 'ebox--render-layout)))
            (cl-letf (((symbol-function 'ebox-incremental--layout-owner-plan)
                       (lambda (&rest arguments)
                         (cl-incf calls)
                         (apply original arguments)))
                      ((symbol-function 'ebox-surface--ensure-node-tree)
                       (lambda (&rest arguments)
                         (cl-incf ensured)
                         (apply original-ensure arguments)))
                      ((symbol-function 'ebox--render-layout)
                       (lambda (node)
                         (push (plist-get node :node-id) rendered)
                         (funcall original-render node))))
              (let* ((candidate (ebox-candidate-begin buffer))
                     (_replacement
                      (ebox-candidate-replace-host-ref
                       candidate 'target
                       (ebox-create :key 'card :class "card"
                                    :host-ref 'target :content "After")))
                     (report (ebox-commit buffer candidate)))
                (should (eq (plist-get report :projection-kind)
                            'owner-scoped))
                ;; The nested 1fr Grid now carries a strict local allocation
                ;; certificate; the proof no longer rescans every normal-flow
                ;; ancestor just to establish the same slot width.
                (should (= 1 (plist-get report :ancestor-slot-count)))
                (should (= 0 (plist-get report
                                        :ancestor-slot-generation))))
              (should (string-match-p
                       "After"
                       (substring-no-properties
                        (ebox-commit-test--buffer-string buffer))))
              (should (= calls 1))
              (should (= ensured 0))
              (should (= (length rendered) 1))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))))))

(ert-deftest ebox-commit-keeps-root-owner-for-dynamic-cascade-source ()
  "A TP-dependent cascade binding must preserve root-owner fallback."
  (let* ((ebox-style-stylesheet (ecss-stylesheet-create))
         (color (tp-signal-create "#111111"))
         (calls 0)
         (buffer nil))
    (ebox-style-add-rule
     ".card" (list :color (tp-computed (lambda () (tp-signal-read color))))
     :layer 'components)
    (unwind-protect
        (progn
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-dynamic-style-proof*")
                 (ebox-column
                  (ebox-create :key 'card :class "card" :content "Before"
                               :width '(40))
                  (ebox-create :key 'stable :content "Stable"
                               :width '(40)))))
          (let* ((state (ebox--buffer-render-state buffer))
                 (style-states (plist-get state :style-binding-states))
                 (binding-state
                  (cl-loop for value being the hash-values of style-states
                           when (and (plist-get value :binding)
                                     (not (ebox-surface--static-style-state-p
                                           value)))
                           return value)))
            (should binding-state)
            (should (> (tp-binding-dependency-count
                        (plist-get binding-state :binding))
                       (if (plist-get binding-state :parent-binding) 1 0)))
            (should-not (ebox-surface--static-style-state-p binding-state)))
          (let ((original
                 (symbol-function 'ebox-incremental--layout-owner-plan)))
            (cl-letf (((symbol-function 'ebox-incremental--layout-owner-plan)
                       (lambda (&rest arguments)
                         (cl-incf calls)
                         (apply original arguments))))
              (ebox-commit
               buffer
               (ebox-column
                (ebox-create :key 'card :class "card" :content "After"
                             :width '(40))
                (ebox-create :key 'stable :content "Stable"
                             :width '(40))))
              (should (= calls 0)))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-owner-scoped-proof-rejects-unstable-allocation ()
  "Auto intrinsic, line-count, and topology changes must keep root fallback."
  (let ((ebox-style-stylesheet (ecss-stylesheet-create)))
    (ebox-style-add-rule ".card" '(:color "#111111") :layer 'components)
    (dolist
        (case
         (list
          (list :name "auto"
                :old (ebox-create :key 'card :class "card" :host-ref 'target
                                  :content "Before")
                :new (ebox-create :key 'card :class "card" :host-ref 'target
                                  :content "After, intrinsically wider"))
          (list :name "lines"
                :old (ebox-create :key 'card :class "card" :host-ref 'target
                                  :content "Before" :width '(40))
                :new (ebox-create :key 'card :class "card" :host-ref 'target
                                  :content "After\nsecond" :width '(40)))
          (list :name "topology"
                :old (ebox-create :key 'card :class "card" :host-ref 'target
                                  :content "Before" :width '(40) :height 1)
                :new (ebox-column
                      (ebox-create :key 'first :content "After" :width '(40))
                      (ebox-create :key 'second :content "Second"
                                   :width '(40))))))
      (let ((buffer nil))
        (unwind-protect
            (progn
              (setq buffer
                    (ebox-render-to-buffer
                     (generate-new-buffer-name
                      (format " *ebox-owner-proof-%s*" (plist-get case :name)))
                     (ebox-column
                      (plist-get case :old)
                      (ebox-create :key 'stable :content "Stable"
                                   :width '(40)))))
              (let ((candidate (ebox-candidate-begin buffer)))
                (ebox-candidate-replace-host-ref
                 candidate 'target (plist-get case :new))
                (let ((report (ebox-commit buffer candidate)))
                  (should-not (eq (plist-get report :projection-kind)
                                  'owner-scoped)))))
          (when (buffer-live-p buffer)
            (kill-buffer buffer)))))
    (let ((buffer nil))
      (unwind-protect
          (progn
            (setq buffer
                  (ebox-render-to-buffer
                   (generate-new-buffer-name " *ebox-owner-proof-auto-grid*")
                   (ebox-build
                    '(grid :width (100) :height 1
                      :grid-template-columns (auto (40))
                      (box :key card :class "card" :host-ref target
                           :content "Before" :height 1)
                      (box :key stable :content "Stable"
                           :width (40) :height 1)))))
            (let ((candidate (ebox-candidate-begin buffer)))
              (ebox-candidate-replace-host-ref
               candidate 'target
               (ebox-create :key 'card :class "card" :host-ref 'target
                            :content "After" :height 1))
              (let ((report (ebox-commit buffer candidate)))
                (should-not (eq (plist-get report :projection-kind)
                                'owner-scoped)))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ebox-commit-owner-scoped-multi-owner-is-atomic ()
  "Two disjoint fixed-slot owners render locally in one publication."
  (let* ((ebox-style-stylesheet (ecss-stylesheet-create))
         (buffer nil)
         (ensured 0)
         (ancestor-proofs 0)
         (rendered nil)
         (published 0))
    (ebox-style-add-rule ".card" '(:color "#111111") :layer 'components)
    (unwind-protect
        (progn
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-owner-multi*")
                 (ebox-build
                  '(grid :width (100)
                    :grid-template-columns (1fr 1fr)
                    (column :key card-shell :width stretch
                     :border "#687386" :padding (1 2)
                     (box :key first :class "card" :host-ref first
                          :content "First" )
                     (box :key second :class "card" :host-ref second
                          :content "Second"))
                    (box :key stable :content "Stable"
                         :width (40) :height 2)))))
          (let* ((surface (with-current-buffer buffer
                            ebox-surface--buffer-surface))
                 (revision (tp-surface-revision surface))
                 (candidate (ebox-candidate-begin buffer))
                 (original-ensure
                  (symbol-function 'ebox-surface--ensure-node-tree))
                 (original-ancestor-proof
                  (symbol-function
                   'ebox-incremental--compute-ancestor-slot-signature))
                 (original-render (symbol-function 'ebox--render-layout)))
            (ebox-candidate-replace-host-ref
             candidate 'first
             (ebox-create :key 'first :class "card" :host-ref 'first
                          :content "Alpha"))
            (ebox-candidate-replace-host-ref
             candidate 'second
             (ebox-create :key 'second :class "card" :host-ref 'second
                          :content "Bravo!"))
            (cl-letf (((symbol-function 'ebox-surface--ensure-node-tree)
                       (lambda (&rest arguments)
                         (cl-incf ensured)
                         (apply original-ensure arguments)))
                      ((symbol-function 'ebox--render-layout)
                       (lambda (node)
                         (push (plist-get node :node-id) rendered)
                         (funcall original-render node)))
                      ((symbol-function
                        'ebox-incremental--compute-ancestor-slot-signature)
                       (lambda (&rest arguments)
                         (cl-incf ancestor-proofs)
                         (apply original-ancestor-proof arguments))))
              (let ((report
                     (ebox-commit
                      buffer candidate
                      (lambda (_report) (cl-incf published)))))
                (should (eq (plist-get report :projection-kind)
                            'owner-scoped))
                (should (= 2 (length (plist-get report
                                                :rendered-owner-ids))))
                (should (= 1 published))
                (should (= 1 (- (tp-surface-revision surface) revision)))
                (should (= 0 ensured))
                (should (= 2 ancestor-proofs))
                (should (= 2 (length rendered)))
                (should (string-match-p
                         "Alpha" (ebox-commit-test--buffer-string buffer)))
                (should (string-match-p
                         "Bravo!" (ebox-commit-test--buffer-string buffer)))
                (let* ((text (ebox-commit-test--buffer-string buffer))
                       (position (string-match "Alpha" text)))
                  (should position)
                  (should (equal
                           (plist-get (get-text-property position 'face text)
                                      :foreground)
                           "#111111")))
                (should (< (plist-get report :reconciled-objects)
                           (plist-get (tp-surface-inspect surface)
                                      :object-count)))))
            (let* ((fallback-revision (tp-surface-revision surface))
                   (fallback (ebox-candidate-begin buffer)))
              (ebox-candidate-replace-host-ref
               fallback 'first
               (ebox-create :key 'first :class "card" :host-ref 'first
                            :content "Gamma"))
              (ebox-candidate-replace-host-ref
               fallback 'second
               (ebox-create :key 'second :class "card" :host-ref 'second
                            :content "Much much much much much much longer beta content"))
              (let ((report (ebox-commit buffer fallback)))
                (should-not (eq (plist-get report :projection-kind)
                                'owner-scoped))
                (should (or (plist-get report :tp-scope-fallback)
                            (plist-get report :tp-full-root)))
                (should (= 1 (- (tp-surface-revision surface)
                                fallback-revision)))
                (let ((text (ebox-commit-test--buffer-string buffer)))
                  (should (string-match-p
                           "Much much much much much much longer beta"
                           text))
                  (should (string-match-p "content" text)))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-commit-formatting-context-reflow-owns-variable-line-siblings ()
  "Two variable-line owners should publish through their nearest stack context.
The context owns the complete local block; the root and untouched header/footer
remain retained identities."
  (let* ((old-root
          (ebox-column
           (ebox-create :key 'header :content "Header" :width '(160))
           (ebox-create
            :key 'shell :width '(160)
            :ebox-content-node
            (ebox-column
             (ebox-create :key 'message :host-ref 'message
                          :content "Callback action pending")
             (ebox-flex :width '(120) :height 1
                        (ebox-create :key 'toggle :host-ref 'toggle
                                     :content "Behavior: off"))))
           (ebox-create :key 'footer :content "Footer" :width '(160))))
         (new-message
          (ebox-create :key 'message :host-ref 'message
                       :content "Behavior toggle: on / callback active / a longer status line"))
         (new-toggle
          (ebox-create :key 'toggle :host-ref 'toggle
                       :content "Behavior: on"))
         (new-root
          (ebox-column
           (ebox-create :key 'header :content "Header" :width '(160))
           (ebox-create
            :key 'shell :width '(160)
            :ebox-content-node
            (ebox-column
             new-message
             (ebox-flex :width '(120) :height 1 new-toggle)))
           (ebox-create :key 'footer :content "Footer" :width '(160))))
         (buffer nil)
         (fresh nil))
    (unwind-protect
        (progn
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name
                  " *ebox-formatting-context-reflow*")
                 old-root))
          (let ((candidate (ebox-candidate-begin buffer)))
            (ebox-candidate-replace-host-ref candidate 'message new-message)
            (ebox-candidate-replace-host-ref candidate 'toggle new-toggle)
            (let ((root-id
                   (plist-get (plist-get (ebox--buffer-render-state buffer)
                                          :root-node)
                              :node-id))
                  report)
              (setq report (ebox-commit buffer candidate))
              (should (eq (plist-get report :projection-kind)
                          'formatting-context-reflow))
              (should (= 1 (length (plist-get report :owner-ids))))
              (should-not (member root-id (plist-get report :owner-ids)))
              (should-not (plist-get report :tp-full-root))
              (should-not (plist-get report :tp-scope-fallback))
              (should (= 1 (plist-get report :tp-scope-count)))
              (should (= 1 (plist-get report :tp-scope-range-count)))
              (should (= 1 (plist-get report :tp-text-operations)))))
          (setq fresh
                (ebox-render-to-buffer
                 (generate-new-buffer-name
                  " *ebox-formatting-context-fresh*")
                 new-root))
          (let* ((committed (ebox-commit-test--buffer-string buffer))
                 (expected (ebox-commit-test--buffer-string fresh))
                 (keys '(ebox-content ebox-content-idx ebox-content-owner
                         ebox-content-owners display))
                 (semantic-owner
                  (lambda (state value)
                    (if (numberp value)
                        (let* ((region-node-table
                                (plist-get state :region-node-table))
                               (node-table (plist-get state :node-table))
                               (node-id (and region-node-table
                                             (gethash value region-node-table)))
                               (node (and node-id
                                           (gethash node-id node-table))))
                          (or (and node (ebox-tree-node-key node)) value))
                      value)))
                 (semantic-properties
                  (lambda (state text position)
                    (mapcar
                     (lambda (key)
                       (cons key
                             (let ((value (get-text-property
                                           position key text)))
                               (if (memq key '(ebox-content-owner
                                               ebox-content-owners
                                               ebox-content))
                                   (if (listp value)
                                       (mapcar (lambda (owner)
                                                 (funcall semantic-owner
                                                          state owner))
                                               value)
                                     (funcall semantic-owner state value))
                                 value))))
                     keys))))
            ;; Region ids are buffer-local allocation identities.  Compare
            ;; stable node semantics and layout properties, not those ids.
            (should (equal (substring-no-properties committed)
                           (substring-no-properties expected)))
            (should (= (length committed) (length expected)))
            (dotimes (position (length committed))
              (should
               (equal (funcall semantic-properties
                               (ebox--buffer-render-state buffer)
                               committed position)
                      (funcall semantic-properties
                               (ebox--buffer-render-state fresh)
                               expected position))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (when (buffer-live-p fresh)
        (kill-buffer fresh)))))

(ert-deftest ebox-commit-formatting-context-reflow-rolls-back-and-retries ()
  "Formatting-context reflow keeps one rollback boundary and can retry."
  (cl-labels
      ((root (message toggle)
         (ebox-column
          (ebox-create :key 'header :content "Header" :width '(160))
          (ebox-create
           :key 'shell :width '(160)
           :ebox-content-node
           (ebox-column
            (ebox-create :key 'message :host-ref 'message :content message)
            (ebox-flex :width '(120) :height 1
                       (ebox-create :key 'toggle :host-ref 'toggle
                                    :content toggle))))
          (ebox-create :key 'footer :content "Footer" :width '(160)))))
    (dolist (failure-kind '(client-state final-accept))
      (let ((buffer (generate-new-buffer
                     (format " *ebox-formatting-context-%S*" failure-kind))))
        (unwind-protect
            (progn
              (ebox-render-to-buffer
               buffer (root "Callback action pending" "Behavior: off"))
              (let* ((before (ebox-commit-test--buffer-string buffer))
                     (state (tp-surface-client-state
                             (with-current-buffer
                                 buffer ebox-surface--buffer-surface)))
                     (revision (tp-surface-revision
                                (with-current-buffer
                                    buffer ebox-surface--buffer-surface)))
                     (candidate (ebox-candidate-begin buffer)))
                (ebox-candidate-replace-host-ref
                 candidate 'message
                 (ebox-create
                  :key 'message :host-ref 'message
                  :content "Behavior toggle: on / callback active / a longer status line"))
                (ebox-candidate-replace-host-ref
                 candidate 'toggle
                 (ebox-create :key 'toggle :host-ref 'toggle
                              :content "Behavior: on"))
                (if (eq failure-kind 'client-state)
                    (let ((tp--surface-publication-step-function
                           (lambda (step _surface)
                             (when (eq step 'client-state)
                               (error "reject formatting reflow publication")))))
                      (should-error (ebox-commit buffer candidate)))
                  (cl-letf (((symbol-function 'accept-change-group)
                             (lambda (_group)
                               (error "reject formatting reflow accept"))))
                    (should-error (ebox-commit buffer candidate))))
                (let ((surface (with-current-buffer
                                   buffer ebox-surface--buffer-surface)))
                  (should (eq (tp-surface-client-state surface) state))
                  (should (= (tp-surface-revision surface) revision))
                  (should (equal-including-properties
                           (ebox-commit-test--buffer-string buffer) before)))
                (let ((retry (ebox-candidate-begin buffer)))
                  (ebox-candidate-replace-host-ref
                   retry 'message
                   (ebox-create
                    :key 'message :host-ref 'message
                    :content "Behavior toggle: on / callback active / a longer status line"))
                  (ebox-candidate-replace-host-ref
                   retry 'toggle
                   (ebox-create :key 'toggle :host-ref 'toggle
                                :content "Behavior: on"))
                  (let ((report (ebox-commit buffer retry)))
                    (should (eq (plist-get report :projection-kind)
                                'formatting-context-reflow))
                    (should-not (plist-get report :tp-scope-fallback))
                    (should-not (plist-get report :tp-full-root))))))
          (when (buffer-live-p buffer)
            (kill-buffer buffer)))))))

(ert-deftest ebox-commit-multi-owner-variable-content-keeps-fixed-slots ()
  "Two fixed Grid slots accept unequal one-line content in one publication."
  (let* ((new-left
          (ebox-create :key 'left :host-ref 'left
                       :content "L"))
         (new-right
          (ebox-create :key 'right :host-ref 'right :content "R"))
         (old-root
          (ebox-build
           '(grid :key grid :width (80)
                  :grid-template-columns ((36) (36))
                  :column-gap (0 (8))
                  (box :key left :host-ref left :content "left-old")
                  (box :key right :host-ref right :content "right-old"))))
         (buffer nil)
         (fresh nil)
         report)
    (unwind-protect
        (progn
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name
                  " *ebox-multi-owner-variable-slots*")
                 old-root))
          (let ((candidate (ebox-candidate-begin buffer)))
            (ebox-candidate-replace-host-ref candidate 'left new-left)
            (ebox-candidate-replace-host-ref candidate 'right new-right)
            (setq report (ebox-commit buffer candidate)))
          (should (memq (plist-get report :projection-kind)
                        '(span-patch owner-scoped)))
          (should-not (plist-get report :tp-full-root))
          (should-not (plist-get report :tp-scope-fallback))
          (should (= 1 (plist-get report :tp-text-operations)))
          (should (string-match-p "L"
                                  (ebox-commit-test--buffer-string buffer)))
          (setq fresh
                (ebox-render-to-buffer
                 (generate-new-buffer-name
                  " *ebox-multi-owner-variable-slots-fresh*")
                 (ebox-build
                  '(grid :key grid :width (80)
                         :grid-template-columns ((36) (36))
                         :column-gap (0 (8))
                         (box :key left :host-ref left :content "L")
                         (box :key right :host-ref right :content "R")))))
          (should (equal
                   (substring-no-properties
                    (ebox-commit-test--buffer-string buffer))
                   (substring-no-properties
                    (ebox-commit-test--buffer-string fresh))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (when (buffer-live-p fresh)
        (kill-buffer fresh))))))

(ert-deftest ebox-commit-multi-owner-variable-content-rolls-back-and-retries ()
  "Variable multi-owner spans restore old state at both TP failure points."
  (cl-labels
      ((root (left right)
         (ebox-grid :key 'grid :width '(80)
                    :grid-template-columns '((36) (36))
                    :column-gap '(0 (8))
                    (ebox-create :key 'left :host-ref 'left :content left)
                    (ebox-create :key 'right :host-ref 'right :content right)))
       (candidate (buffer)
         (let ((candidate (ebox-candidate-begin buffer)))
           (ebox-candidate-replace-host-ref
            candidate 'left
            (ebox-create :key 'left :host-ref 'left :content "L"))
           (ebox-candidate-replace-host-ref
            candidate 'right
            (ebox-create :key 'right :host-ref 'right :content "R"))
           candidate)))
    (dolist (failure-kind '(client-state final-accept))
      (let ((buffer (generate-new-buffer
                     (format " *ebox-variable-span-%S*" failure-kind))))
        (unwind-protect
            (progn
              (ebox-render-to-buffer
               buffer (root "left-old" "right-old"))
              (let* ((surface (with-current-buffer
                                  buffer ebox-surface--buffer-surface))
                     (state (tp-surface-client-state surface))
                     (revision (tp-surface-revision surface))
                     (before (ebox-commit-test--buffer-string buffer))
                     (candidate (candidate buffer)))
                (if (eq failure-kind 'client-state)
                    (let ((tp--surface-publication-step-function
                           (lambda (step _surface)
                             (when (eq step 'client-state)
                               (error "reject variable span publication")))))
                      (should-error (ebox-commit buffer candidate)))
                  (cl-letf (((symbol-function 'accept-change-group)
                             (lambda (_group)
                               (error "reject variable span accept"))))
                    (should-error (ebox-commit buffer candidate))))
                (should (eq (tp-surface-client-state surface) state))
                (should (= (tp-surface-revision surface) revision))
                (should (equal-including-properties
                         (ebox-commit-test--buffer-string buffer) before))
                (let ((report (ebox-commit buffer (candidate buffer))))
                  (should (memq (plist-get report :projection-kind)
                                '(span-patch owner-scoped)))
                  (should-not (plist-get report :tp-full-root))
                  (should-not (plist-get report :tp-scope-fallback)))))
          (when (buffer-live-p buffer)
            (kill-buffer buffer)))))))

(ert-deftest ebox-commit-updates-raw-runtime-type-counts ()
  "A structural candidate should publish exact raw runtime type counts."
  (let* ((buffer
          (ebox-render-to-buffer
           (generate-new-buffer-name " *ebox-commit-types*")
           (ebox-build
            '(flex :key root :width (80)
                   (item (box :key child :content "A" :width (40)))))))
         (before (gethash buffer ebox--buffer-render-state-table)))
    (unwind-protect
        (progn
          (should (= (gethash
                      'item (plist-get before :runtime-type-count-table))
                     1))
          (ebox-commit
           buffer (ebox-create :key 'root :content "B" :width '(80)))
          (let ((after (gethash buffer ebox--buffer-render-state-table)))
            (should-not
             (gethash 'item (plist-get after :runtime-type-count-table)))
            (should (= (gethash
                        'box (plist-get after :runtime-type-count-table))
                       1))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-commit-rolls-back-on-invalid-root ()
  "A failed candidate must leave the previously published buffer intact."
  (let ((buffer (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-commit-rollback*")
                 (ebox-create :key 'root :content "Stable" :width '(80)))))
    (unwind-protect
        (progn
          (should-error
           (ebox-commit buffer (ebox-create :key 'root :content nil
                                             :width 'invalid)))
          (should (string-prefix-p
                   "Stable"
                   (string-trim-right
                    (substring-no-properties
                     (ebox-commit-test--buffer-string buffer))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-candidate-root-replacement-reuses-candidate-validity-contract ()
  "Root replacement rejects invalid, other-buffer, stale, and sealed use."
  (let ((first (generate-new-buffer " *ebox-root-valid-first*"))
        (second (generate-new-buffer " *ebox-root-valid-second*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer first (ebox-create :key 'root :content "one"))
          (ebox-render-to-buffer second (ebox-create :key 'root :content "two"))
          (let ((candidate (ebox-candidate-begin first)))
            (should-error (ebox-candidate-replace-root candidate "invalid"))
            (ebox-candidate-replace-root
             candidate (ebox-create :key 'root :content "candidate"))
            (should-error (ebox-commit second candidate))
            (should-error
             (ebox-candidate-replace-root
              candidate (ebox-create :key 'root :content "sealed"))))
          (let ((candidate (ebox-candidate-begin first)))
            (ebox-candidate-replace-root
             candidate (ebox-create :key 'root :content "stale"))
            (ebox-commit first (ebox-create :key 'root :content "new-base"))
            (should-error (ebox-commit first candidate))))
      (dolist (buffer (list first second))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest ebox-commit-two-and-three-argument-compatibility ()
  "Two-argument commits complete and legacy callbacks receive one same report."
  (let ((buffer (generate-new-buffer " *ebox-framework-compat*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer buffer (ebox-create :key 'root :content "0"))
          (should (eq (plist-get
                       (ebox-commit buffer (ebox-create :key 'root :content "1"))
                       :framework-participant-state)
                      'completed))
          (let ((calls 0) seen)
            (let ((report
                   (ebox-commit
                    buffer (ebox-create :key 'root :content "2")
                    (lambda (value) (cl-incf calls) (setq seen value)))))
              (should (= calls 1))
              (should (eq seen report))
              (should (eq (plist-get seen :framework-participant-state)
                          'completed)))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-commit-final-accept-failure-rolls-framework-back ()
  "A TP final-accept failure rolls the paired framework pointer back once."
  (dolist (mode '(full scoped))
    (let ((buffer (generate-new-buffer " *ebox-framework-accept-fail*")))
      (unwind-protect
          (progn
            (ebox-render-to-buffer
                buffer
              (ebox-column
               (ebox-create :key 'a :host-ref 'a :content "old-a")
               (ebox-create :key 'b :host-ref 'b :content "old-b")))
            (let* ((before (ebox-commit-test--buffer-string buffer))
                   (candidate (ebox-candidate-begin buffer))
                   trace captured failure)
              (ebox-candidate-replace-host-ref
               candidate 'a (ebox-create :key 'a :host-ref 'a :content "new-a"))
              (cl-letf (((symbol-function 'accept-change-group)
                         (lambda (_group) (error "accept failed"))))
                (setq failure
                      (condition-case condition
                          (ebox-commit
                           buffer
                           (if (eq mode 'scoped)
                               candidate
                             (ebox-create :key 'root :content "new-root"))
                           (lambda (report)
                             (setq captured report)
                             (push 'publish trace))
                           (lambda (_report)
                             (push 'rollback trace)
                             (signal 'quit nil)))
                        (error condition))))
              (should (equal (cadr failure) "accept failed"))
              (should (equal trace '(rollback publish)))
              (should (eq (plist-get captured :framework-participant-state)
                          'rolled-back))
              (should (= (length
                          (plist-get captured
                                     :framework-participant-diagnostics))
                         1))
              (should (equal-including-properties
                       (ebox-commit-test--buffer-string buffer) before))
              (should (eq (plist-get
                           (ebox-commit
                            buffer (ebox-create :key 'root :content "next"))
                           :framework-participant-state)
                          'completed))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest ebox-commit-records-scroll-diagnostics-before-completion ()
  "Contained scroll failures are separately reported and do not block retry."
  (let ((buffer (generate-new-buffer " *ebox-scroll-diagnostics*"))
        (diagnostics
         '((:region-id one :phase scroll-finalization :action cancel
                       :condition (error "x"))
           (:region-id one :phase scroll-finalization :action stop
                       :condition (quit)))))
    (unwind-protect
        (progn
          (ebox-render-to-buffer buffer (ebox-create :key 'root :content "0"))
          (cl-letf
              (((symbol-function
                 'ebox-incremental--finalize-declarative-scroll-publication)
                (lambda (&rest _arguments) diagnostics)))
            (let ((report
                   (ebox-commit
                    buffer (ebox-create :key 'root :content "1"))))
              (should (eq (plist-get report :framework-participant-state)
                          'completed))
              (should (equal
                       (plist-get report :scroll-finalization-diagnostics)
                       diagnostics))))
          (should (eq (plist-get
                       (ebox-commit buffer
                                    (ebox-create :key 'root :content "2"))
                       :framework-participant-state)
                      'completed)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-commit-restores-ebox-after-participant-owner-failure ()
  "A rollback-owner failure cannot skip restoration of Ebox runtime state."
  (let ((buffer (generate-new-buffer " *ebox-participant-owner-failure*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer buffer (ebox-create :key 'root :content "old"))
          (let* ((surface (with-current-buffer
                            buffer ebox-surface--buffer-surface))
                 (old-state (tp-surface-client-state surface))
                 (old-buffer (ebox-commit-test--buffer-string buffer))
                 (original-report
                  (symbol-function 'ebox-surface--participant-report))
                 rollback-called failure)
            (cl-letf
                (((symbol-function 'accept-change-group)
                  (lambda (_group) (error "primary accept failure")))
                 ((symbol-function 'ebox-surface--participant-report)
                  (lambda (participant report state)
                    (prog1 (funcall original-report participant report state)
                      (when (and rollback-called (eq state 'rolled-back))
                        (error "rollback owner failure"))))))
              (setq failure
                    (condition-case condition
                        (ebox-commit
                         buffer (ebox-create :key 'root :content "new")
                         #'ignore
                         (lambda (_report) (setq rollback-called t)))
                      (error condition))))
            (should (equal (cadr failure) "primary accept failure"))
            (should rollback-called)
            (should
             (tp--transaction-condition-trailer failure :rollback-failures))
            (should (eq (tp-surface-client-state surface) old-state))
            (should (eq (ebox--buffer-render-state buffer) old-state))
            (should (equal-including-properties
                     (ebox-commit-test--buffer-string buffer) old-buffer))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(defun ebox-commit-test--mixed-owner-root
    (left right paint-a paint-b paint-c)
  "Return the raw sibling fixture for mixed geometry/paint publication."
  (ebox-column
   (ebox-create
    :key 'geometry-context :width '(80)
    :ebox-content-node
    (ebox-column
     (ebox-create :key 'left :host-ref 'left
                  :content left :font 'bold)
     (ebox-create :key 'right :host-ref 'right
                  :content right)))
   (ebox-create :key 'paint-a :host-ref 'paint-a
                :content "paint-a" :color paint-a)
   (ebox-create :key 'paint-b :host-ref 'paint-b
                :content "paint-b" :bgcolor paint-b)
   (ebox-create :key 'paint-c :host-ref 'paint-c
                :content "paint-c" :color paint-c)
   (ebox-create :key 'untouched :host-ref 'untouched
                :content "untouched")))

(ert-deftest ebox-candidate-host-paint-patch-preserves-subtree-identity ()
  "Patch one Host's paint without copying or reconciling its descendants."
  (let* ((buffer
          (ebox-render-to-buffer
           (generate-new-buffer-name " *ebox-host-paint-patch* ")
           (ebox-create
            :key 'target :host-ref 'target :bgcolor "#111111"
            :ebox-content-node
            (ebox-column
             (ebox-create :key 'child :host-ref 'child :content "child")))))
         (child-id (plist-get (ebox--host-ref-node buffer 'child) :node-id)))
    (unwind-protect
        (progn
          (let ((candidate (ebox-candidate-begin buffer)))
            (ebox-candidate-patch-host-paint
             candidate 'target
             (ebox-create
              :key 'target :host-ref 'target :bgcolor "#111111"
              :ebox-content-node
              (ebox-column
               (ebox-create :key 'child :host-ref 'child :content "child")))
             (ebox-create
              :key 'target :host-ref 'target :bgcolor "#EEEEEE"
              :ebox-content-node
              (ebox-column
               (ebox-create :key 'child :host-ref 'child :content "child"))))
            (let ((report (ebox-commit buffer candidate)))
              (should (eq (plist-get report :projection-kind) 'paint))
              (should (= child-id
                         (plist-get (ebox--host-ref-node buffer 'child)
                                    :node-id)))
              (should (equal "#EEEEEE"
                             (plist-get (ebox--host-ref-node buffer 'target)
                                        :bgcolor)))))
          (let ((candidate (ebox-candidate-begin buffer)))
            (should-not
             (ebox-candidate-patch-host-paint
              candidate 'target
              (ebox-create
               :key 'target :host-ref 'target :bgcolor "#EEEEEE"
               :content "child")
              (ebox-create
               :key 'target :host-ref 'target :bgcolor "#EEEEEE"
               :width '(40) :content "child"))))
          (let ((candidate (ebox-candidate-begin buffer)))
            (should
             (ebox-candidate-patch-host-paint
              candidate 'target
              (ebox-create
               :key 'target :host-ref 'target :bgcolor "#EEEEEE"
               :ebox-content-node
               (ebox-column
                (ebox-create :key 'child :host-ref 'child :content "child")))
              (ebox-create
               :key 'target :host-ref 'target :bgcolor "#EEEEEE"
               :color "#FFFFFF"
               :ebox-content-node
               (ebox-column
                (ebox-create :key 'child :host-ref 'child :content "child")))))
            (ebox-commit buffer candidate)
            (should
             (equal "#FFFFFF"
                    (plist-get (ebox--host-ref-node buffer 'target) :color)))
            (should
             (equal "#FFFFFF"
                    (plist-get (ebox--host-ref-node buffer 'child) :color)))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(defun ebox-commit-test--fixed-basis-selection-root (row-1 row-2)
  "Return a stretched fixed-basis panel containing two selectable rows."
  (let ((panel
         (ebox-create
          :key 'selection-panel :width 'stretch :min-width 0 :min-height 24
          :flex-grow 2 :flex-shrink 1 :flex-basis '(340)
          :ebox-content-node
          (ebox-column
           (ebox-create :key 'row-1 :host-ref 'row-1 :content row-1)
           (ebox-create :key 'row-2 :host-ref 'row-2 :content row-2)))))
    (ebox-flex
     :key 'fixed-basis-selection-root
     :width '(900) :height 24
     :flex-flow '(row nowrap) :align-items 'stretch
     (ebox-create :key 'peer :content "peer" :width 'stretch
                  :min-width 0 :min-height 24
                  :flex-grow 4 :flex-shrink 1 :flex-basis '(620))
     panel)))

(defun ebox-commit-test--fixed-basis-selection-candidate
    (buffer row-1 row-2)
  "Return BUFFER candidate replacing both fixed-basis selection rows."
  (let ((candidate (ebox-candidate-begin buffer)))
    (ebox-candidate-replace-host-ref
     candidate 'row-1
     (ebox-create :key 'row-1 :host-ref 'row-1 :content row-1))
    (ebox-candidate-replace-host-ref
     candidate 'row-2
     (ebox-create :key 'row-2 :host-ref 'row-2 :content row-2))
    candidate))

(ert-deftest ebox-commit-fixed-basis-selection-round-trip-stays-local ()
  "Continuous row-1 -> row-2 -> row-1 publication keeps local TP scope."
  (let ((slot-proof-count 0)
        (original-slot-proof
         (symbol-function 'ebox--flex-item-slot-footprint-safe-p))
        (buffer
         (ebox-render-to-buffer
          (generate-new-buffer-name " *ebox-fixed-basis-round-trip* ")
          (ebox-commit-test--fixed-basis-selection-root
           "[x] row 1" "[ ] row 2"))))
    (unwind-protect
        (let* ((root-id (ebox--buffer-root-node-id buffer))
               (panel-id
                (plist-get (ebox--host-ref-node buffer 'row-1) :node-id))
               reports)
          (setq panel-id
                (ebox-incremental--nearest-fixed-basis-flex-item-owner-id
                 buffer panel-id))
          (cl-letf (((symbol-function 'ebox--flex-item-slot-footprint-safe-p)
                     (lambda (&rest arguments)
                       (cl-incf slot-proof-count)
                       (apply original-slot-proof arguments))))
            (dolist (contents '(("[ ] row 1" "[x] row 2")
                                ("[x] row 1" "[ ] row 2")))
              (let* ((report
                      (ebox-commit
                       buffer
                       (ebox-commit-test--fixed-basis-selection-candidate
                        buffer (car contents) (cadr contents))))
                   (surface (with-current-buffer
                                buffer ebox-surface--buffer-surface))
                   (tp-report (tp-surface-report surface))
                   (object-count
                    (plist-get (tp-surface-inspect surface) :object-count))
                   (snapshots
                    (plist-get (ebox--buffer-render-state buffer)
                               :layout-snapshots))
                   (panel-snapshot (and snapshots
                                        (gethash panel-id snapshots))))
              (push report reports)
              (should (eq (plist-get report :projection-kind)
                          'owner-scoped))
              (should-not (member root-id (plist-get report :owner-ids)))
              (should-not (plist-get report :tp-full-root))
              (should-not (plist-get report :tp-scope-fallback))
              (should (< (plist-get tp-report :reconciled-objects)
                         object-count))
              (should (<= (plist-get tp-report :reconciled-objects) 4))
              ;; Successful publication leaves the fixed-basis owner ready
              ;; to recapture geometry from the committed TP mounts.
              (should panel-snapshot)
              (should-not (plist-member panel-snapshot :buffer-spans))
                (with-current-buffer buffer
                  (should
                   (equal
                    (buffer-substring-no-properties (point-min) (point-max))
                    (substring-no-properties
                     (ebox-render (ebox--buffer-root-node buffer)))))))))
          (should (= (length reports) 2))
          (should (= slot-proof-count 2)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(defun ebox-commit-test--mixed-owner-candidate
    (buffer left right paint-a paint-b paint-c)
  "Return BUFFER candidate replacing all mixed fixture owners."
  (let ((candidate (ebox-candidate-begin buffer)))
    (ebox-candidate-replace-host-ref
     candidate 'left
     (ebox-create :key 'left :host-ref 'left
                  :content left :font 'bold))
    (ebox-candidate-replace-host-ref
     candidate 'right
     (ebox-create :key 'right :host-ref 'right
                  :content right))
    (ebox-candidate-replace-host-ref
     candidate 'paint-a
     (ebox-create :key 'paint-a :host-ref 'paint-a
                  :content "paint-a" :color paint-a))
    (ebox-candidate-replace-host-ref
     candidate 'paint-b
     (ebox-create :key 'paint-b :host-ref 'paint-b
                  :content "paint-b" :bgcolor paint-b))
    (ebox-candidate-replace-host-ref
     candidate 'paint-c
     (ebox-create :key 'paint-c :host-ref 'paint-c
                  :content "paint-c" :color paint-c))
    candidate))

(ert-deftest ebox-commit-mixed-owner-reflow-is-atomic-and-round-trips ()
  "Geometry and color owners publish once without duplicating face layers."
  (let ((buffer
         (ebox-render-to-buffer
          (generate-new-buffer-name " *ebox-mixed-owner* ")
          (ebox-commit-test--mixed-owner-root
           "left-old" "right-old" "#111111" "#222222" "#333333"))))
    (unwind-protect
        (progn
          (let ((candidate (ebox-candidate-begin buffer)))
            (ebox-candidate-replace-host-ref
             candidate 'left
             (ebox-create :key 'left :host-ref 'left
                          :content "left-new" :font 'bold))
            (ebox-candidate-replace-host-ref
             candidate 'right
             (ebox-create :key 'right :host-ref 'right
                          :content "right-new"))
            (ebox-candidate-replace-host-ref
             candidate 'paint-a
             (ebox-create :key 'paint-a :host-ref 'paint-a
                          :content "paint-a" :color "#AAAAAA"))
            (ebox-candidate-replace-host-ref
             candidate 'paint-b
             (ebox-create :key 'paint-b :host-ref 'paint-b
                          :content "paint-b" :bgcolor "#BBBBBB"))
            (ebox-candidate-replace-host-ref
             candidate 'paint-c
             (ebox-create :key 'paint-c :host-ref 'paint-c
                          :content "paint-c" :color "#CCCCCC"))
            (let ((report (ebox-commit buffer candidate)))
              (should (eq (plist-get report :projection-kind)
                          'mixed-owner-reflow))
              (should-not (plist-get report :tp-full-root))
              (should-not (plist-get report :tp-scope-fallback))
              (should-not
               (member (ebox--buffer-root-node-id buffer)
                       (plist-get report :owner-ids)))
              (should (= (plist-get report :created-objects) 0))
              (should (= (plist-get report :removed-objects) 0))
              (with-current-buffer buffer
                (should
                 (equal-including-properties
                  (buffer-substring (point-min) (point-max))
                  (ebox-render (ebox--buffer-root-node buffer)))))))
          (let ((candidate (ebox-candidate-begin buffer)))
            (ebox-candidate-replace-host-ref
             candidate 'left
             (ebox-create :key 'left :host-ref 'left
                          :content "left-old" :font 'bold))
            (ebox-candidate-replace-host-ref
             candidate 'right
             (ebox-create :key 'right :host-ref 'right
                          :content "right-old"))
            (ebox-candidate-replace-host-ref
             candidate 'paint-a
             (ebox-create :key 'paint-a :host-ref 'paint-a
                          :content "paint-a" :color "#111111"))
            (ebox-candidate-replace-host-ref
             candidate 'paint-b
             (ebox-create :key 'paint-b :host-ref 'paint-b
                          :content "paint-b" :bgcolor "#222222"))
            (ebox-candidate-replace-host-ref
             candidate 'paint-c
             (ebox-create :key 'paint-c :host-ref 'paint-c
                          :content "paint-c" :color "#333333"))
            (let ((report (ebox-commit buffer candidate)))
              (should (eq (plist-get report :projection-kind)
                          'mixed-owner-reflow))
              (with-current-buffer buffer
                (should
                 (equal-including-properties
                  (buffer-substring (point-min) (point-max))
                  (ebox-render (ebox--buffer-root-node buffer))))))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-commit-mixed-owner-reflow-rolls-back-and-retries ()
  "Mixed publication restores the old pair after final-accept failure."
  (let* ((buffer
          (ebox-render-to-buffer
           (generate-new-buffer-name " *ebox-mixed-owner-rollback* ")
           (ebox-commit-test--mixed-owner-root
            "left-old" "right-old" "#111111" "#222222" "#333333")))
         (old-buffer (ebox-commit-test--buffer-string buffer))
         (candidate
          (ebox-commit-test--mixed-owner-candidate
           buffer "left-new" "right-new" "#AAAAAA" "#BBBBBB" "#CCCCCC")))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'accept-change-group)
                     (lambda (_group) (error "mixed final accept"))))
            (should-error (ebox-commit buffer candidate)))
          (should (equal-including-properties
                   (ebox-commit-test--buffer-string buffer) old-buffer))
          (let ((retry
                 (ebox-commit-test--mixed-owner-candidate
                  buffer "left-new" "right-new"
                  "#AAAAAA" "#BBBBBB" "#CCCCCC")))
            (let ((report (ebox-commit buffer retry)))
              (should (eq (plist-get report :projection-kind)
                          'mixed-owner-reflow))
              (with-current-buffer buffer
                (should
                 (equal-including-properties
                  (buffer-substring (point-min) (point-max))
                  (ebox-render (ebox--buffer-root-node buffer))))))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-commit-mixed-owner-reflow-reuses-unchanged-fragments ()
  "Delegate affected face composition to TP and retain fragment topology."
  (let* ((buffer
          (ebox-render-to-buffer
           (generate-new-buffer-name " *ebox-mixed-owner-reuse* ")
           (ebox-commit-test--mixed-owner-root
            "left-old" "right-old" "#111111" "#222222" "#333333")))
         (surface (with-current-buffer buffer ebox-surface--buffer-surface))
         (old-state (tp-surface-client-state surface))
         (fragment-count (length (plist-get old-state :surface-fragments)))
         (repaints 0)
         (metadata-calls 0)
         (original
          (symbol-function 'ebox-surface--repaint-output-fragment!))
         (original-metadata
          (symbol-function 'ebox-surface--fragment-metadata)))
    (unwind-protect
        (progn
          (should
           (cl-every
            (lambda (fragment)
              (or (null (plist-get fragment :paint-role-ids))
                  (plist-get fragment :paint-node-chain)))
            (plist-get old-state :surface-fragments)))
          (should (plist-get old-state :surface-owned-ranges))
          (cl-letf (((symbol-function 'ebox-surface--repaint-output-fragment!)
                     (lambda (&rest args)
                       (cl-incf repaints)
                       (apply original args)))
                    ((symbol-function 'ebox-surface--fragment-metadata)
                     (lambda (&rest args)
                       (cl-incf metadata-calls)
                       (apply original-metadata args))))
            (should (eq (plist-get
                         (ebox-commit
                          buffer
                          (ebox-commit-test--mixed-owner-candidate
                           buffer "left-new" "right-new"
                           "#AAAAAA" "#BBBBBB" "#CCCCCC"))
                         :projection-kind)
                        'mixed-owner-reflow)))
          (should (> fragment-count 0))
          (should (zerop repaints))
          (should
           (plist-get (tp-surface-client-state surface)
                      :paint-property-contributions))
          (let ((fragments
                 (plist-get (tp-surface-client-state surface)
                            :surface-fragments))
                (offset 0))
            (should fragments)
            (dolist (fragment fragments)
              (should (= offset (plist-get fragment :start)))
              (setq offset (plist-get fragment :end)))
            (should (= offset
                       (with-current-buffer buffer (buffer-size)))))
          (should (= metadata-calls 0)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-surface-owned-range-index-rebases-exact-boundaries ()
  "Rebase retained ownership exactly and reject ambiguous inner boundaries."
  (let* ((patches '((:old-start 5 :old-end 10
                      :new-start 5 :new-end 12)))
         (ranges '((:object before :start 0 :end 5 :tags (:before t))
                   (:object changed :start 5 :end 10 :tags (:changed t))
                   (:object parent :start 0 :end 20 :tags (:parent t))
                   (:object after :start 10 :end 20 :tags (:after t))))
         (rebased (cdr (ebox-surface--rebase-owned-ranges
                        ranges patches 22))))
    (should
     (equal (mapcar (lambda (range)
                      (list (plist-get range :object)
                            (plist-get range :start)
                            (plist-get range :end)))
                    rebased)
            '((before 0 5) (changed 5 12) (parent 0 22) (after 12 22))))
    (should-not
     (ebox-surface--rebase-owned-ranges
      '((:object ambiguous :start 6 :end 9)) patches 22))))

(ert-deftest ebox-commit-structure-skips-inapplicable-paint-span-proofs ()
  "A structural transaction must not run proofs whose domain excludes it."
  (let* ((buffer
          (ebox-render-to-buffer
           (generate-new-buffer-name " *ebox-structure-proof-domain* ")
           (ebox-column
            (ebox-create
             :key 'target :host-ref 'target
             :ebox-content-node
             (ebox-column (ebox-create :key 'first :content "first"))))))
         (span-calls 0)
         (mixed-calls 0)
         (old-span
          (symbol-function 'ebox-incremental--span-patch-projection-proof))
         (old-mixed
          (symbol-function 'ebox-incremental--mixed-owner-proof)))
    (unwind-protect
        (let ((candidate (ebox-candidate-begin buffer)))
          (ebox-candidate-replace-host-ref
           candidate 'target
           (ebox-create
            :key 'target :host-ref 'target
            :ebox-content-node
            (ebox-column (ebox-create :key 'first :content "first")
                         (ebox-create :key 'second :content "second"))))
          (cl-letf
              (((symbol-function 'ebox-incremental--span-patch-projection-proof)
                (lambda (&rest arguments)
                  (cl-incf span-calls)
                  (apply old-span arguments)))
               ((symbol-function 'ebox-incremental--mixed-owner-proof)
                (lambda (&rest arguments)
                  (cl-incf mixed-calls)
                  (apply old-mixed arguments))))
            (ebox-commit buffer candidate))
          (should (zerop span-calls))
          (should (zerop mixed-calls))
          (should (string-match-p "second"
                                  (ebox-commit-test--buffer-string buffer))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-candidate-range-structure-stops-at-range-parent ()
  "A Range child identity change must not mark copied ancestors structural."
  (let* ((buffer
          (ebox-render-to-buffer
           (generate-new-buffer-name " *ebox-range-dirty-boundary* ")
           (ebox-column
            (ebox-child-range
             'rows (ebox-create :key 'old :content "old")))))
         (state (ebox--buffer-render-state buffer))
         (parent-id
          (plist-get (gethash 'rows (plist-get state :range-ref-table))
                     :parent-node-id))
         captured)
    (unwind-protect
        (let ((candidate (ebox-candidate-begin buffer))
              (original
               (symbol-function 'ebox-incremental--surface-commit-input)))
          (ebox-candidate-replace-range-ref
           candidate 'rows (list (ebox-create :key 'new :content "new")))
          (cl-letf
              (((symbol-function 'ebox-incremental--surface-commit-input)
                (lambda (target old-state prepared)
                  (setq captured (copy-tree (plist-get prepared :dirty-set)))
                  (funcall original target old-state prepared))))
            (ebox-commit buffer candidate))
          (should
           (equal
            (mapcar (lambda (entry)
                      (list (plist-get entry :node-id)
                            (plist-get entry :dirty-kind)
                            (plist-get entry :changed-keys)))
                    captured)
            (list (list parent-id 'structure '(:children)))))
          (should (string-match-p "new"
                                  (ebox-commit-test--buffer-string buffer))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-commit-mixed-owner-reflow-skips-full-owner-planner ()
  "A proven mixed union should not also plan the complete dirty set."
  (let* ((buffer
          (ebox-render-to-buffer
           (generate-new-buffer-name " *ebox-mixed-owner-plan* ")
           (ebox-commit-test--mixed-owner-root
            "left-old" "right-old" "#111111" "#222222" "#333333")))
         (calls 0)
         (axis-scans 0)
         (original
          (symbol-function 'ebox-incremental--layout-owner-plan))
         (original-context-axes
          (symbol-function 'ebox-surface--context-axes)))
    (unwind-protect
        (cl-letf
            (((symbol-function 'ebox-incremental--layout-owner-plan)
              (lambda (&rest arguments)
                (cl-incf calls)
                (apply original arguments)))
             ((symbol-function 'ebox-surface--context-axes)
              (lambda (&rest arguments)
                (cl-incf axis-scans)
                (apply original-context-axes arguments))))
          (let* ((report
                  (ebox-commit
                   buffer
                   (ebox-commit-test--mixed-owner-candidate
                    buffer "left-new" "right-new"
                    "#AAAAAA" "#BBBBBB" "#CCCCCC")))
                 (owner-ids (plist-get report :owner-ids)))
            (should (eq (plist-get report :projection-kind)
                        'mixed-owner-reflow))
            (should (= calls 0))
            (should (= axis-scans 0))
            (should (= (plist-get report :tp-scope-count)
                       (length owner-ids)))
            (should-not (plist-get report :tp-scope-fallback))
            (with-current-buffer buffer
              (should
               (equal-including-properties
                (buffer-substring (point-min) (point-max))
                (ebox-render (ebox--buffer-root-node buffer)))))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(defun ebox-commit-test--allocation-closure-root
    (toast paint-a paint-b &optional width footer-overflow root-overflow)
  "Return a generic whole-line Flex allocation-closure fixture."
  (ebox-create
   :key 'root :width (list (or width 800))
   :height (and root-overflow 1) :overflow root-overflow
   :ebox-content-node
   (ebox-column
    (ebox-create :key 'status :host-ref 'status
                 :content "Theme: Light" :width '(200))
    (ebox-create :key 'paint-a :host-ref 'paint-a
                 :content "paint-a" :color paint-a)
    (ebox-create :key 'paint-b :host-ref 'paint-b
                 :content "paint-b" :bgcolor paint-b)
    (ebox-create
     :key 'footer-owner :width (list (or width 800))
     :ebox-content-node
     (ebox-column
      (ebox-flex
       :key 'footer :width (list (or width 800)) :flex-wrap 'wrap
       :overflow footer-overflow :gap '(1 (4))
       (ebox-create
        :key 'toast-slot :width 'stretch :min-width 0
        :flex-grow 1 :flex-shrink 1 :flex-basis '(0)
        :ebox-content-node
        (ebox-column
         (ebox-create :key 'toast :host-ref 'toast :content toast)))
       (ebox-create :key 'peer :content "database.sqlite")))))))

(defun ebox-commit-test--allocation-closure-candidate
    (buffer toast paint-a paint-b)
  "Return BUFFER candidate changing one Flex content and two paints."
  (let ((candidate (ebox-candidate-begin buffer)))
    (ebox-candidate-replace-host-ref
     candidate 'toast
     (ebox-create :key 'toast :host-ref 'toast :content toast))
    (ebox-candidate-replace-host-ref
     candidate 'paint-a
     (ebox-create :key 'paint-a :host-ref 'paint-a
                  :content "paint-a" :color paint-a))
    (ebox-candidate-replace-host-ref
     candidate 'paint-b
     (ebox-create :key 'paint-b :host-ref 'paint-b
                  :content "paint-b" :bgcolor paint-b))
    candidate))

(defun ebox-commit-test--two-geometry-allocation-candidate
    (buffer status toast paint-a paint-b)
  "Return BUFFER candidate with one span and one allocation geometry owner."
  (let ((candidate
         (ebox-commit-test--allocation-closure-candidate
          buffer toast paint-a paint-b)))
    (ebox-candidate-replace-host-ref
     candidate 'status
     (ebox-create :key 'status :host-ref 'status
                  :content status :width '(200)))
    candidate))

(ert-deftest ebox-commit-allocation-closure-round-trips-exactly ()
  "Stable Flex allocation closes one content damage plus external paint."
  (let* ((buffer
          (ebox-render-to-buffer
           (generate-new-buffer-name " *ebox-allocation-closure* ")
         (ebox-commit-test--allocation-closure-root
            "Light" "#111111" "#222222")))
         (surface (with-current-buffer buffer ebox-surface--buffer-surface))
         (full-renders 0)
         (original-full-render
          (symbol-function 'ebox-surface--render-candidate)))
    (unwind-protect
        (cl-letf (((symbol-function 'ebox-surface--render-candidate)
                   (lambda (&rest arguments)
                     (cl-incf full-renders)
                     (apply original-full-render arguments))))
          (dolist (values '(("A longer dark notification"
                             "#AAAAAA" "#BBBBBB")
                            ("Light" "#111111" "#222222")))
            (let* ((before (tp-surface-revision surface))
                   (candidate
                    (apply #'ebox-commit-test--allocation-closure-candidate
                           buffer values))
                   (report (ebox-commit buffer candidate))
                   (state (tp-surface-client-state surface))
                   (owner-proof
                    (car (plist-get
                          (plist-get (plist-get state :mixed-owner-proof)
                                     :geometry-proof)
                          :owner-proofs))))
              (should (eq (plist-get report :projection-kind)
                          'mixed-owner-reflow))
              (should (plist-get owner-proof :allocation-closure-p))
              (should (= (tp-surface-revision surface) (1+ before)))
              (should-not (plist-get report :tp-full-root))
              (should-not (plist-get report :tp-scope-fallback))
              (should (= (plist-get report :created-objects) 0))
              (should (= (plist-get report :removed-objects) 0))
              (should (= (or (plist-get report :moved-objects) 0) 0))
              (with-current-buffer buffer
                (should
                 (equal-including-properties
                  (buffer-substring (point-min) (point-max))
                  (ebox-render (ebox--buffer-root-node buffer)))))))
          (should (= full-renders 0)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-commit-allocation-closure-rolls-back-and-retries ()
  "Failed allocation-closure publication restores state before retry."
  (let* ((buffer
          (ebox-render-to-buffer
           (generate-new-buffer-name " *ebox-allocation-rollback* ")
           (ebox-commit-test--allocation-closure-root
            "Light" "#111111" "#222222")))
         (surface (with-current-buffer buffer ebox-surface--buffer-surface))
         (state (tp-surface-client-state surface))
         (revision (tp-surface-revision surface))
         (text (ebox-commit-test--buffer-string buffer)))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'accept-change-group)
                     (lambda (_group) (error "allocation final accept"))))
            (should-error
             (ebox-commit
              buffer
              (ebox-commit-test--allocation-closure-candidate
               buffer "A longer dark notification" "#AAAAAA" "#BBBBBB"))))
          (should (= (tp-surface-revision surface) revision))
          (should (eq (tp-surface-client-state surface) state))
          (should (equal-including-properties
                   (ebox-commit-test--buffer-string buffer) text))
          (should (eq (plist-get
                       (ebox-commit
                        buffer
                        (ebox-commit-test--allocation-closure-candidate
                         buffer "A longer dark notification"
                         "#AAAAAA" "#BBBBBB"))
                       :projection-kind)
                      'mixed-owner-reflow)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-commit-two-geometry-allocation-closure-round-trips ()
  "Combine one ordinary span with one allocation closure after global miss."
  (let* ((buffer
          (ebox-render-to-buffer
           (generate-new-buffer-name " *ebox-two-geometry-closure* ")
           (ebox-commit-test--allocation-closure-root
            "Light" "#111111" "#222222")))
         (surface (with-current-buffer buffer ebox-surface--buffer-surface))
         (full-renders 0)
         (original-full-render
          (symbol-function 'ebox-surface--render-candidate)))
    (unwind-protect
        (cl-letf (((symbol-function 'ebox-surface--render-candidate)
                   (lambda (&rest arguments)
                     (cl-incf full-renders)
                     (apply original-full-render arguments))))
          (dolist (values '(("Theme: Dark" "A longer dark notification"
                             "#AAAAAA" "#BBBBBB")
                            ("Theme: Light" "Light"
                             "#111111" "#222222")))
            (let* ((before (tp-surface-revision surface))
                   (report
                    (ebox-commit
                     buffer
                     (apply
                      #'ebox-commit-test--two-geometry-allocation-candidate
                      buffer values)))
                   (state (tp-surface-client-state surface))
                   (proofs
                    (plist-get
                     (plist-get (plist-get state :mixed-owner-proof)
                                :geometry-proof)
                     :owner-proofs)))
              (should (eq (plist-get report :projection-kind)
                          'mixed-owner-reflow))
              (should (= 2 (length proofs)))
              (should (cl-some (lambda (proof)
                                 (plist-get proof :allocation-closure-p))
                               proofs))
              (should (= (tp-surface-revision surface) (1+ before)))
              (should-not (plist-get report :tp-full-root))
              (should-not (plist-get report :tp-scope-fallback))
              (with-current-buffer buffer
                (should
                 (equal-including-properties
                  (buffer-substring (point-min) (point-max))
                  (ebox-render (ebox--buffer-root-node buffer)))))))
          (should (= full-renders 0)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-allocation-closure-allows-recomposable-ancestor-paint ()
  "Allow ancestor paint but reject paint at/below an allocation owner."
  (let ((parents (make-hash-table :test #'eql)))
    ;; 1(root) -> 2(paint ancestor) -> 3(geometry) -> 4(paint descendant)
    (puthash 2 1 parents)
    (puthash 3 2 parents)
    (puthash 4 3 parents)
    (let ((state (list :parent-table parents)))
      (should
       (ebox-incremental--allocation-closure-paint-disjoint-p
        state '(3) '(2)))
      (should-not
       (ebox-incremental--allocation-closure-paint-disjoint-p
        state '(3) '(3)))
      (should-not
       (ebox-incremental--allocation-closure-paint-disjoint-p
        state '(3) '(4))))))

(ert-deftest ebox-commit-allocation-closure-unsafe-shapes-fallback ()
  "Wrap/width, overflow, and scroll changes cannot use allocation closure."
  (dolist (case '((120 nil nil) (800 visible nil) (800 nil scroll)))
    (pcase-let ((`(,width ,footer-overflow ,root-overflow) case))
      (let ((buffer
             (ebox-render-to-buffer
              (generate-new-buffer-name " *ebox-allocation-fallback* ")
              (ebox-commit-test--allocation-closure-root
               "Light" "#111111" "#222222"
               width footer-overflow root-overflow))))
        (unwind-protect
            (let ((report
                   (ebox-commit
                    buffer
                    (ebox-commit-test--allocation-closure-candidate
                     buffer (make-string 200 ?X) "#AAAAAA" "#BBBBBB"))))
              (should-not (eq (plist-get report :projection-kind)
                              'mixed-owner-reflow)))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest ebox-commit-allocation-closure-proof-misses-fallback ()
  "Topology, selector, cascade, and role misses reject allocation closure."
  (dolist (kind '(topology selector cascade))
    (let ((buffer
           (ebox-render-to-buffer
            (generate-new-buffer-name " *ebox-allocation-proof-miss* ")
            (ebox-commit-test--allocation-closure-root
             "Light" "#111111" "#222222"))))
      (unwind-protect
          (let ((candidate (ebox-candidate-begin buffer)))
            (ebox-candidate-replace-host-ref
             candidate 'toast
             (if (eq kind 'topology)
                 (ebox-create
                  :key 'toast :host-ref 'toast
                  :ebox-content-node
                  (ebox-column
                   (ebox-create :key 'nested-toast
                                :content "A longer notification")))
               (ebox-create :key 'toast :host-ref 'toast
                            :class (and (eq kind 'selector) "changed")
                            :content "A longer notification")))
            (ebox-candidate-replace-host-ref
             candidate 'paint-a
             (ebox-create :key 'paint-a :host-ref 'paint-a
                          :content "paint-a" :color "#AAAAAA"))
            (let ((report
                   (if (eq kind 'cascade)
                       (cl-letf
                           (((symbol-function 'ebox-style-cascade-active-p)
                             (lambda () t))
                            ((symbol-function
                              'ebox-surface--cascade-local-owner-proof-p)
                             (lambda (&rest _) nil)))
                         (ebox-commit buffer candidate))
                     (ebox-commit buffer candidate))))
              (should-not (eq (plist-get report :projection-kind)
                              'mixed-owner-reflow))))
        (when (buffer-live-p buffer) (kill-buffer buffer)))))
  (let* ((buffer
          (ebox-render-to-buffer
           (generate-new-buffer-name " *ebox-allocation-role-miss* ")
           (ebox-commit-test--allocation-closure-root
            "Light" "#111111" "#222222")))
         (original-output
          (symbol-function 'ebox-surface--mixed-owner-output))
         mixed-output)
    (unwind-protect
        (progn
          (ebox--refresh-buffer-layout-snapshots buffer t)
          (cl-letf
              (((symbol-function
                 'ebox-surface--rendered-role-topology-signature)
                (lambda (&rest _) '(:roles (mismatched))))
               ((symbol-function 'ebox-surface--mixed-owner-output)
                (lambda (&rest arguments)
                  (setq mixed-output (apply original-output arguments)))))
            (ebox-commit
             buffer
             (ebox-commit-test--allocation-closure-candidate
              buffer "A longer notification" "#AAAAAA" "#BBBBBB"))
            (should-not mixed-output)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(provide 'ebox-commit-tests)

;;; ebox-commit-tests.el ends here
