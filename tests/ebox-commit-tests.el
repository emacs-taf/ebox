;;; ebox-commit-tests.el --- Declarative commit smoke tests -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)
(require 'ebox)
(require 'ebox-native-commit)
(require 'ebox-native-reflow)

;; These tests lock the named Elisp projection proofs.  Native commit has its
;; own focused contract tests below; disable runtime module discovery here so
;; a locally built optional module cannot silently replace paint/span/mixed
;; plans with `native-frame' and make this suite environment-dependent.
(defvar ebox-native-reflow-module-path)
(setq ebox-native-reflow-module-path nil)

(defun ebox-commit-test--buffer-string (buffer)
  "Return BUFFER's complete propertized contents."
  (with-current-buffer buffer
    (save-restriction
      (widen)
      (buffer-substring (point-min) (point-max)))))

(defun ebox-commit-test--face-value (face key)
  "Return KEY from FACE whether FACE is one plist or a face stack."
  (cond
   ((null face) nil)
   ((and (listp face) (keywordp (car face)))
    (plist-get face key))
   ((listp face)
    (cl-some (lambda (entry)
               (ebox-commit-test--face-value entry key))
             face))))

(defun ebox-commit-test--owner-proofs (proof)
  "Return the uniform leaf-owner proof list represented by PROOF."
  (or (plist-get proof :owner-proofs)
      (and proof (list proof))))

(defun ebox-commit-test--observed-root (content)
  "Return one stable declarative root containing CONTENT."
  (ebox-test-box :key 'root (ebox-test-text content)))

(defun ebox-commit-test--scroll-sibling-root (content &optional nested)
  "Return CONTENT beside an active scroll box, or inside it when NESTED."
  (let ((label (ebox-test-text content :key 'label :source-identity 'label)))
    (ebox-test-column :key 'root :width '(120)
      (unless nested label)
      (ebox-test-box :key 'scroll :id "scroll" :height 2 :width '(80)
        :overflow 'scroll
        (ebox-test-column
          (when nested label)
          (ebox-test-text "line-a\nline-b\nline-c\nline-d"
                          :key 'scroll-lines :source-identity 'scroll-lines
                          :color "#123456"))))))

(defun ebox-commit-test--replace-scroll-sibling-label (buffer content)
  "Commit CONTENT into BUFFER's stable label host."
  (let ((candidate (ebox-candidate-begin buffer)))
    (ebox-candidate-replace-host-ref
     candidate 'label
     (ebox-test-text content :key 'label :source-identity 'label))
    (ebox-commit buffer candidate)))

(ert-deftest ebox-commit-local-content-retains-disjoint-scroll ()
  "An unrelated scroll box keeps its caches and registry across a local edit."
  (with-temp-buffer
    (ebox-render-to-buffer
     (current-buffer) (ebox-commit-test--scroll-sibling-root "old"))
    (let* ((before (ebox--buffer-render-state (current-buffer)))
           (scroll-id (car (plist-get before :scroll-region-ids)))
           (old-scroll (gethash scroll-id ebox--scroll-global-state))
           (raw (plist-get old-scroll :content-lines))
           (rendered (plist-get old-scroll :rendered-content-lines))
           (region-count (hash-table-count (plist-get before :region-box-table)))
           (root-render (symbol-function 'ebox-surface--render-candidate))
           (root-renders 0)
           report)
      (should scroll-id)
      (cl-letf (((symbol-function 'ebox-surface--render-candidate)
                 (lambda (state)
                   (cl-incf root-renders)
                   (funcall root-render state))))
        (setq report
              (ebox-commit-test--replace-scroll-sibling-label
               (current-buffer) "new")))
      (should (memq (plist-get report :projection-kind) '(span-patch owner-scoped)))
      (should (zerop root-renders))
      (should-not (plist-get report :tp-full-root))
      (let* ((after (ebox--buffer-render-state (current-buffer)))
             (scroll (gethash scroll-id ebox--scroll-global-state)))
        (should (= region-count (hash-table-count (plist-get after :region-box-table))))
        (should (eq (plist-get scroll :box) (gethash scroll-id ebox--region-box-table)))
        (should (eq raw (plist-get scroll :content-lines)))
        (should (eq rendered (plist-get scroll :rendered-content-lines))))
      (should (= 1 (ebox--scroll-region-by scroll-id 1)))
      (should (string-match-p "new" (buffer-string)))
      (should (string-match-p "line-c" (buffer-string)))
      (should (= -1 (ebox--scroll-region-by scroll-id -1)))
      (should (string-match-p "new" (buffer-string)))
      (should (string-match-p "line-a" (buffer-string))))))

(ert-deftest ebox-commit-disjoint-scroll-rolls-back-with-local-content ()
  "Late rejection restores both the local content and the scroll registry."
  (with-temp-buffer
    (ebox-render-to-buffer
     (current-buffer) (ebox-commit-test--scroll-sibling-root "old"))
    (let* ((state (ebox--buffer-render-state (current-buffer)))
           (scroll-id (car (plist-get state :scroll-region-ids)))
           (scroll (gethash scroll-id ebox--scroll-global-state))
           (box (gethash scroll-id ebox--region-box-table))
           (before (buffer-string)))
      (cl-letf (((symbol-function 'accept-change-group)
                 (lambda (_) (error "Reject local content publication"))))
        (should-error
         (ebox-commit-test--replace-scroll-sibling-label (current-buffer) "new")))
      (should (eq state (ebox--buffer-render-state (current-buffer))))
      (should (eq scroll (gethash scroll-id ebox--scroll-global-state)))
      (should (eq box (gethash scroll-id ebox--region-box-table)))
      (should (equal-including-properties before (buffer-string)))
      (should (= 1 (ebox--scroll-region-by scroll-id 1)))
      (should (string-match-p "old" (buffer-string)))
      (ebox-commit-test--replace-scroll-sibling-label (current-buffer) "new")
      (should (= -1 (ebox--scroll-region-by scroll-id -1)))
      (should (string-match-p "new" (buffer-string))))))

(ert-deftest ebox-commit-local-content-inside-scroll-keeps-full-cache-update ()
  "A scrolling ancestor still needs its retained content regenerated."
  (with-temp-buffer
    (ebox-render-to-buffer
     (current-buffer) (ebox-commit-test--scroll-sibling-root "old" t))
    (let* ((state (ebox--buffer-render-state (current-buffer)))
           (scroll-id (car (plist-get state :scroll-region-ids)))
           (report (ebox-commit-test--replace-scroll-sibling-label
                    (current-buffer) "new")))
      (should-not (memq (plist-get report :projection-kind) '(span-patch owner-scoped)))
      (should (= 1 (ebox--scroll-region-by scroll-id 1)))
      (should (= -1 (ebox--scroll-region-by scroll-id -1)))
      (should (string-match-p "new" (buffer-string)))
      (should-not (string-match-p "old" (buffer-string))))))

(ert-deftest ebox-commit-disjoint-scroll-proof-rejects-incomplete-or-overlapping-state ()
  "Missing mappings, changed membership and either ancestor direction reject."
  (with-temp-buffer
    (ebox-render-to-buffer
     (current-buffer) (ebox-commit-test--scroll-sibling-root "old"))
    (let* ((state (ebox--buffer-render-state (current-buffer)))
           (owner (plist-get (ebox--host-ref-node (current-buffer) 'label) :node-id))
           (root (plist-get (plist-get state :root-node) :node-id))
           (region (car (plist-get state :scroll-region-ids)))
           (scroll (gethash region ebox--scroll-global-state))
           (scroll-id (plist-get (plist-get scroll :box) :node-id))
           (table (make-hash-table :test 'equal))
           (prepared (list :scroll-state-table table))
           (candidate (copy-sequence state)))
      (puthash region scroll table)
      (should (ebox-incremental--span-owner-disjoint-from-scroll-p
               (current-buffer) state prepared candidate owner))
      (should-not (ebox-incremental--span-owner-disjoint-from-scroll-p
                   (current-buffer) state prepared candidate root))
      (should-not (ebox-incremental--span-owner-disjoint-from-scroll-p
                   (current-buffer) state prepared candidate scroll-id))
      (remhash region table)
      (should-not (ebox-incremental--span-owner-disjoint-from-scroll-p
                   (current-buffer) state prepared candidate owner))
      (puthash 'different-region scroll table)
      (should-not (ebox-incremental--span-owner-disjoint-from-scroll-p
                   (current-buffer) state prepared candidate owner))
      (clrhash table)
      (puthash region scroll table)
      (let ((regions (copy-hash-table (plist-get state :region-box-table))))
        (remhash region regions)
        (plist-put candidate :region-box-table regions)
        (should-not (ebox-incremental--span-owner-disjoint-from-scroll-p
                     (current-buffer) state prepared candidate owner)))
      (plist-put candidate :region-box-table (plist-get state :region-box-table))
      (let ((parents (copy-hash-table (plist-get state :parent-table))))
        (puthash scroll-id owner parents)
        (plist-put candidate :parent-table parents)
        (should-not (ebox-incremental--span-owner-disjoint-from-scroll-p
                     (current-buffer) state prepared candidate owner))))))

(ert-deftest ebox-commit-content-shift-preserves-later-scroll-targets ()
  "Longer and shorter local text retain the later scroll widget's targets."
  (with-temp-buffer
    (ebox-render-to-buffer
     (current-buffer) (ebox-commit-test--scroll-sibling-root "old"))
    (let ((scroll-id (car (plist-get (ebox--buffer-render-state (current-buffer))
                                    :scroll-region-ids))))
      (dolist (value '("longer" "x"))
        (ebox-commit-test--replace-scroll-sibling-label (current-buffer) value)
        (should (= 1 (ebox--scroll-region-by scroll-id 1)))
        (should (string-match-p (concat "\\`" value) (buffer-string)))
        (should (string-match-p "line-c" (buffer-string)))
        (should (= -1 (ebox--scroll-region-by scroll-id -1)))
        (should (string-match-p (concat "\\`" value) (buffer-string)))
        (should (string-match-p "line-a" (buffer-string)))))))

(ert-deftest ebox-commit-mixed-content-and-scroll-paint-refreshes-cache ()
  "An unrelated label edit cannot authorize stale paint in a scroll cache."
  (with-temp-buffer
    (ebox-render-to-buffer
     (current-buffer) (ebox-commit-test--scroll-sibling-root "old"))
    (let* ((scroll-id (car (plist-get (ebox--buffer-render-state (current-buffer))
                                     :scroll-region-ids)))
           (candidate (ebox-candidate-begin (current-buffer))))
      (ebox-candidate-replace-host-ref
       candidate 'label (ebox-test-text "new" :key 'label :source-identity 'label))
      (ebox-candidate-replace-host-ref
       candidate 'scroll-lines
       (ebox-test-text "line-a\nline-b\nline-c\nline-d"
                       :key 'scroll-lines :source-identity 'scroll-lines
                       :color "#654321"))
      (let ((report (ebox-commit (current-buffer) candidate)))
        (should-not (eq (plist-get report :projection-kind) 'mixed-owner-reflow)))
      (dotimes (_ 2)
        (goto-char (point-min))
        (search-forward "line-a")
        (should (equal "#654321"
                       (ebox-commit-test--face-value
                        (get-text-property (1- (point)) 'face) :foreground)))
        (should (= 1 (ebox--scroll-region-by scroll-id 1)))
        (should (= -1 (ebox--scroll-region-by scroll-id -1)))))))

(ert-deftest ebox-commit-disjoint-scroll-validates-rendered-font-extent ()
  "Equal raw widths do not authorize changed rendered glyph widths."
  (let ((measure (symbol-function 'ebox--string-pixel-width)))
    ;; Model an unchanged proportional font: raw WWW/iii both measure three
    ;; units, but styled iii is narrower.  The final painted line must still
    ;; include exactly the filler required by its 120px parent allocation.
    (cl-letf (((symbol-function 'ebox--string-pixel-width)
               (lambda (string)
                 (let ((width (funcall measure string)) (start 0))
                   (while (string-match "iii" string start)
                     (when (get-text-property (match-beginning 0) 'face string)
                       (cl-decf width))
                     (setq start (match-end 0)))
                   width))))
      (with-temp-buffer
        (ebox-render-to-buffer
         (current-buffer)
         (ebox-test-column :key 'root :width '(120)
           (ebox-test-text "WWW" :font-size 16 :key 'label :source-identity 'label)
           (ebox-test-box :height 1 :overflow 'scroll
             (ebox-test-text "first\nsecond"))))
        (let ((candidate (ebox-candidate-begin (current-buffer))))
          (ebox-candidate-replace-host-ref
           candidate 'label
           (ebox-test-text "iii" :font-size 16 :key 'label :source-identity 'label))
          (ebox-commit (current-buffer) candidate))
        (goto-char (point-min))
        (should (looking-at "iii"))
        (should (= 120 (ebox--string-pixel-width
                        (buffer-substring (point) (line-end-position)))))))))

(defun ebox-commit-test--hash-facts (table &optional values)
  "Return sorted TABLE keys, or key/value pairs when VALUES is non-nil."
  (let (facts)
    (maphash (lambda (key value)
               (push (if values (cons key value) key) facts))
             table)
    (sort facts
          (lambda (left right)
            (string< (prin1-to-string left)
                     (prin1-to-string right))))))

(defun ebox-commit-test--runtime-facts (buffer)
  "Return stable retained runtime facts for BUFFER equivalence checks."
  (let* ((surface (with-current-buffer buffer
                    ebox-surface--buffer-surface))
         (state (tp-surface-client-state surface)))
    (list :surface-revision (tp-surface-revision surface)
          :runtime-revision (plist-get state :runtime-revision)
          :last-update-report (plist-get state :last-update-report)
          :viewport-width (plist-get state :viewport-width)
          :viewport-height (plist-get state :viewport-height)
          :projection-kind (plist-get state :projection-kind)
          :node-ids
          (ebox-commit-test--hash-facts (plist-get state :node-table))
          :region-ids
          (ebox-commit-test--hash-facts (plist-get state :region-id-set))
          :parents
          (ebox-commit-test--hash-facts (plist-get state :parent-table) t)
          :type-counts
          (ebox-commit-test--hash-facts
           (plist-get state :runtime-type-count-table) t)
          :scroll-region-ids (copy-sequence
                              (plist-get state :scroll-region-ids)))))

(defun ebox-commit-test--participant-v2-count ()
  "Return the structured participant registration count for mount and commit."
  (let ((buffer (generate-new-buffer " *ebox-participant-v2*"))
        (v2-register (symbol-function 'tp-transaction-participate-v2))
        (v2-count 0))
    (unwind-protect
        (cl-letf (((symbol-function 'tp-transaction-participate-v2)
                   (lambda (&rest arguments)
                     (cl-incf v2-count)
                     (apply v2-register arguments))))
          (ebox-render-to-buffer
           buffer (ebox-test-box :key 'root (ebox-test-text "old")
                                 :width '(80)))
          (ebox-commit
           buffer (ebox-test-box :key 'root (ebox-test-text "new")
                                 :width '(80)))
          (with-current-buffer buffer
            (should (string-match-p "new" (buffer-string))))
          v2-count)
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-source-index-promotes-and-rolls-back-atomically ()
  "Candidate source indexes promote once and never corrupt retained state."
  (let ((buffer (generate-new-buffer " *ebox-source-index-lifecycle*")))
    (unwind-protect
        (let* ((old-root
                (ebox-build
                 '(column :key root :id "root" :class "old"
                   (box :key row :class "row" "Old"))))
               (candidate
                (ebox-build
                 '(column :key root :id "root" :class "new"
                   (box :key row :class "row" "New")))))
          (ebox-render-to-buffer buffer old-root)
          (let* ((old-state (ebox--buffer-render-state buffer))
                 (old-index (plist-get old-state :source-index))
                 (old-node-id
                  (plist-get (plist-get old-state :root-node) :node-id))
                 (before (ebox-commit-test--buffer-string buffer)))
            (should (ebox-source-index-p old-index))
            (cl-letf (((symbol-function 'accept-change-group)
                       (lambda (_group) (error "source accept failed"))))
              (should-error (ebox-commit buffer candidate) :type 'error))
            (let ((retained (ebox--buffer-render-state buffer)))
              (should (eq old-index (plist-get retained :source-index)))
              (should (equal-including-properties
                       before (ebox-commit-test--buffer-string buffer))))
            (ebox-commit buffer candidate)
            (let* ((new-state (ebox--buffer-render-state buffer))
                   (new-index (plist-get new-state :source-index))
                   (new-root (plist-get new-state :root-node))
                   (record
                    (ebox-source-index-record
                     new-index (ebox-node-source-handle new-root))))
              (should (ebox-source-index-p new-index))
              (should-not (eq old-index new-index))
              (should (= old-node-id (plist-get new-root :node-id)))
              (should (equal '("new")
                             (ebox-source-record-classes record))))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))
    (should-not (ebox--buffer-render-state buffer))))

(defun ebox-commit-test--assert-observer-pair (events stage)
  "Assert reversed EVENTS contain one TP/Ebox pair for STAGE."
  (should (= (length events) 2))
  (let ((ordered (nreverse events)))
    (should (equal (mapcar (lambda (report)
                             (plist-get report :provider))
                           ordered)
                   '(tp ebox)))
    (should (equal (mapcar (lambda (report)
                             (plist-get report :stage))
                           ordered)
                   (list 'publication stage)))
    (should (equal (plist-get (car ordered) :correlation-id)
                   (plist-get (cadr ordered) :correlation-id)))))

(ert-deftest ebox-observer-initial-mount-preserves-state-and-report-contract ()
  "Observed mount is equivalent and does not retain its transient report."
  (let ((plain (generate-new-buffer " *ebox-observer-plain*"))
        (observed (generate-new-buffer " *ebox-observer-mounted*"))
        events)
    (unwind-protect
        (progn
          (let ((ebox--region-id-counter 0)
                (ebox--runtime-node-id-counter 0))
            (ebox-render-to-buffer
             plain (ebox-commit-test--observed-root "same")))
          (let ((ebox--region-id-counter 0)
                (ebox--runtime-node-id-counter 0))
            (ebox-render-to-buffer
             observed (ebox-commit-test--observed-root "same")
             (list :observer
                   (lambda (buffer report)
                     (push (list buffer report) events)))))
          (should
           (equal-including-properties
            (ebox-commit-test--buffer-string plain)
            (ebox-commit-test--buffer-string observed)))
          (should (equal (ebox-commit-test--runtime-facts plain)
                         (ebox-commit-test--runtime-facts observed)))
          (should-not (ebox-buffer-update-report plain))
          (should-not (ebox-buffer-update-report observed))
          (should (= (length events) 2))
          (let* ((ordered (nreverse events))
                 (tp-report (cadar ordered))
                 (ebox-report (cadadr ordered)))
            (should (eq (caar ordered) observed))
            (should (eq (caadr ordered) observed))
            (should (eq (plist-get tp-report :provider) 'tp))
            (should (eq (plist-get tp-report :stage) 'publication))
            (should (eq (plist-get ebox-report :provider) 'ebox))
            (should (eq (plist-get ebox-report :stage) 'mount))
            (should (equal (plist-get tp-report :correlation-id)
                           (plist-get ebox-report :correlation-id)))
            (dolist (key '(:duration-ms :gc-count :gc-duration-ms
                           :tp-duration-ms))
              (should (plist-member ebox-report key)))))
      (when (buffer-live-p plain) (kill-buffer plain))
      (when (buffer-live-p observed) (kill-buffer observed)))))

(ert-deftest ebox-observer-covers-public-update-boundaries-once ()
  "Viewport, region, selector, batch, and scroll each emit one flat pair."
  (let ((buffer (generate-new-buffer " *ebox-observer-operations*"))
        (scroll-buffer (generate-new-buffer " *ebox-observer-scroll*"))
        events)
    (unwind-protect
        (progn
          (ebox-render-to-buffer
           buffer
           (ebox-build
            '(column :width (viewport)
              (box :id first :class card "One")
              (box :id second :class card "Two")))
           (list :observer
                 (lambda (_buffer report) (push report events))))
          (setq events nil)
          (ebox-rerender-buffer-with-context buffer 80)
          (ebox-commit-test--assert-observer-pair events 'viewport)

          (setq events nil)
          (ebox-region-update
           (ebox-region-resolve buffer 'first) :color "#123456")
          (ebox-commit-test--assert-observer-pair events 'region)

          (setq events nil)
          (ebox-selector-update-buffer buffer ".card" :bgcolor "#eeeeee")
          (ebox-commit-test--assert-observer-pair events 'selector)

          (setq events nil)
          (ebox-incremental-begin-batch buffer)
          (ebox-region-update
           (ebox-region-resolve buffer 'first) :color "#654321")
          (should-not events)
          (ebox-incremental-flush buffer)
          (ebox-commit-test--assert-observer-pair events 'batch)

          (setq events nil)
          (ebox-incremental-begin-batch buffer)
          (ebox-incremental-flush buffer)
          (should-not events)

          (let* ((root
                  (ebox-build
                   '(box :id scroll-root :height 1 :overflow scroll
                     "A\nB\nC")))
                 (scroll-id
                  (car
                   (ebox-region-ids
                    (ebox-canonical-input--single-root
                     root "Ebox observer scroll fixture")))))
            (ebox-render-to-buffer
             scroll-buffer root
             (list :observer
                   (lambda (_buffer report) (push report events))))
            (setq events nil)
            (should (= (ebox--scroll-region-by scroll-id 1) 1))
            (ebox-commit-test--assert-observer-pair events 'scroll)))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (when (buffer-live-p scroll-buffer) (kill-buffer scroll-buffer)))))

(ert-deftest ebox-observer-commit-emits-one-flat-pair-after-completion ()
  "One accepted commit emits TP then the completed Ebox report exactly once."
  (let (events
        (buffer (generate-new-buffer " *ebox-observer-commit*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer
           buffer (ebox-commit-test--observed-root "old")
           (list :observer
                 (lambda (_buffer report) (push report events))))
          (setq events nil)
          (let ((report
                 (ebox-commit
                  buffer (ebox-commit-test--observed-root "new"))))
            (should (eq (plist-get report :framework-participant-state)
                        'completed)))
          (should (= (length events) 2))
          (let ((ordered (nreverse events)))
            (should (equal (mapcar (lambda (report)
                                     (plist-get report :provider))
                                   ordered)
                           '(tp ebox)))
            (should (equal (mapcar (lambda (report)
                                     (plist-get report :stage))
                                   ordered)
                           '(publication commit)))
            (should (equal (plist-get (car ordered) :correlation-id)
                           (plist-get (cadr ordered) :correlation-id)))
            (should (eq (plist-get (cadr ordered)
                                   :framework-participant-state)
                        'completed))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-observer-disabled-path-does-no-instrumentation-work ()
  "An unobserved mount and commit bypass every Ebox instrumentation helper."
  (let ((calls 0)
        (buffer (generate-new-buffer " *ebox-observer-disabled*")))
    (unwind-protect
        (cl-letf (((symbol-function 'ebox-surface--make-observation)
                   (lambda (&rest _args) (cl-incf calls)))
                  ((symbol-function 'ebox-surface--observation-clock)
                   (lambda () (cl-incf calls)))
                  ((symbol-function 'ebox-surface--observation-gc-snapshot)
                   (lambda () (cl-incf calls)))
                  ((symbol-function 'ebox-surface--decorate-observation-report)
                   (lambda (&rest _args) (cl-incf calls))))
          (ebox-render-to-buffer
           buffer (ebox-commit-test--observed-root "old"))
          (ebox-commit buffer (ebox-commit-test--observed-root "new"))
          (should (= calls 0)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-buffer-observer-setter-keeps-one-stable-tp-bridge ()
  "Add and replacement reuse one bridge; nil removes it from TP."
  (let ((buffer (generate-new-buffer " *ebox-observer-setter*"))
        first-events second-events)
    (unwind-protect
        (progn
          (ebox-render-to-buffer
           buffer (ebox-commit-test--observed-root "zero"))
          (let ((first
                 (lambda (_buffer report) (push report first-events))))
            (should (eq (ebox-buffer-set-observer buffer first) first)))
          (should-error (ebox-buffer-set-observer buffer 'not-a-function)
                        :type 'wrong-type-argument)
          (let ((bridge (with-current-buffer buffer
                          ebox-surface--tp-observer))
                (surface (with-current-buffer buffer
                           ebox-surface--buffer-surface)))
            (should (memq bridge (tp--surface-observers surface)))
            (ebox-buffer-set-observer
             buffer (lambda (_buffer report) (push report second-events)))
            (should (eq bridge (with-current-buffer buffer
                                 ebox-surface--tp-observer)))
            (should (= (length (tp--surface-observers surface)) 1))
            (ebox-commit buffer (ebox-commit-test--observed-root "one"))
            (should-not first-events)
            (should (= (length second-events) 2))
            (should-not (ebox-buffer-set-observer buffer nil))
            (should-not (memq bridge (tp--surface-observers surface)))
            (setq second-events nil)
            (ebox-commit buffer (ebox-commit-test--observed-root "two"))
            (should-not second-events)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-observer-render-failure-releases-new-observation-state ()
  "A failed observed first mount leaves no observer, bridge, or context."
  (let ((buffer (generate-new-buffer " *ebox-observer-mount-failure*")))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'ebox-surface-mount-buffer)
                     (lambda (&rest _args) (error "mount failed"))))
            (should-error
             (ebox-render-to-buffer
              buffer (ebox-commit-test--observed-root "never")
              (list :observer (lambda (&rest _args))))
             :type 'error))
          (with-current-buffer buffer
            (should-not ebox-surface--buffer-observer)
            (should-not ebox-surface--tp-observer)
            (should-not ebox-surface--observation-contexts)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-observer-boundary-rejects-outer-tp-before-operation ()
  "A public observation boundary cannot finish before an outer TP accept."
  (let ((buffer (generate-new-buffer " *ebox-observer-outer-tp*"))
        events)
    (unwind-protect
        (progn
          (ebox-render-to-buffer
           buffer (ebox-build '(box :id target "old"))
           (list :observer
                 (lambda (_buffer report) (push report events))))
          (setq events nil)
          (let ((before (ebox-commit-test--buffer-string buffer)))
            (tp-with-transaction
              (let ((failure
                     (condition-case condition
                         (progn
                           (ebox-region-update
                            (ebox-region-resolve buffer 'target)
                            :color "#123456")
                           nil)
                       (error condition))))
                (should
                 (equal
                  (cdr failure)
                  '("Ebox public operation cannot join an outer TP transaction")))))
            (should (equal-including-properties
                     before (ebox-commit-test--buffer-string buffer))))
          (should-not events)
          (should-not (ebox-buffer-update-report buffer))
          (should-not (with-current-buffer buffer
                        ebox-surface--observation-contexts)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-observer-reentrant-publication-gets-a-new-context ()
  "A publication started by an observer emits its own correlated pair."
  (let ((buffer (generate-new-buffer " *ebox-observer-reentrant*"))
        events allow nested)
    (unwind-protect
        (progn
          (ebox-render-to-buffer
           buffer (ebox-commit-test--observed-root "initial")
           (list
            :observer
            (lambda (_buffer report)
              (push report events)
              (when (and allow
                         (not nested)
                         (eq (plist-get report :provider) 'tp))
                (setq nested t)
                (ebox-commit
                 buffer (ebox-commit-test--observed-root "nested"))))))
          (setq events nil allow t)
          (ebox-commit buffer (ebox-commit-test--observed-root "outer"))
          (let* ((ordered (nreverse events))
                 (outer-correlation
                  (plist-get (nth 0 ordered) :correlation-id))
                 (nested-correlation
                  (plist-get (nth 1 ordered) :correlation-id)))
            (should (= (length ordered) 4))
            (should (equal (mapcar (lambda (report)
                                     (plist-get report :provider))
                                   ordered)
                           '(tp tp ebox ebox)))
            (should (equal outer-correlation
                           (plist-get (nth 3 ordered) :correlation-id)))
            (should (equal nested-correlation
                           (plist-get (nth 2 ordered) :correlation-id)))
            (should-not (equal outer-correlation nested-correlation)))
          (should
           (equal (substring-no-properties
                   (ebox-commit-test--buffer-string buffer))
                  "nested"))
          (should-not (with-current-buffer buffer
                        ebox-surface--observation-contexts)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-observer-error-cannot-roll-back-publication ()
  "Each observer failure is contained after the accepted state is visible."
  (let ((buffer (generate-new-buffer " *ebox-observer-error*"))
        (calls 0))
    (unwind-protect
        (progn
          (ebox-render-to-buffer
           buffer (ebox-commit-test--observed-root "old")
           (list :observer
                 (lambda (_buffer _report)
                   (cl-incf calls)
                   (error "observer failure"))))
          (setq calls 0)
          (let ((report
                 (ebox-commit
                  buffer (ebox-commit-test--observed-root "committed"))))
            (should (eq (plist-get report :framework-participant-state)
                        'completed)))
          (should (= calls 2))
          (should (equal (substring-no-properties
                          (ebox-commit-test--buffer-string buffer))
                         "committed")))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-commit-rejects-outer-tp-transaction-before-mutation ()
  "Observed and plain commits reject an outer TP transaction before mutation."
  (dolist (observed '(nil t))
    (let ((buffer (generate-new-buffer " *ebox-outer-transaction*"))
          events)
      (unwind-protect
          (progn
            (ebox-render-to-buffer
             buffer (ebox-commit-test--observed-root "old")
             (and observed
                  (list :observer
                        (lambda (_buffer report) (push report events)))))
            (setq events nil)
            (let ((failure
                   (condition-case condition
                       (progn
                         (tp-with-transaction
                           (ebox-commit
                            buffer (ebox-commit-test--observed-root "new")))
                         nil)
                     (error condition))))
              (should (equal (cdr failure)
                             '("Ebox public operation cannot join an outer TP transaction"))))
            (should-not events)
            (should (equal (substring-no-properties
                            (ebox-commit-test--buffer-string buffer))
                           "old"))
            (should-not (with-current-buffer buffer
                          ebox-surface--observation-contexts)))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

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

(ert-deftest ebox-native-session-isolation-bootstraps-or-forks-privately ()
  "Session isolation creates the first candidate and forks later candidates."
  (let ((created (list 'created-session))
        (forked (list 'forked-session))
        create-arguments fork-argument)
    (cl-letf (((symbol-function 'ebox-native-reflow-create-session)
               (lambda (&rest arguments)
                 (setq create-arguments arguments)
                 created))
              ((symbol-function 'ebox-native-reflow-fork-session)
               (lambda (session &rest _options)
                 (setq fork-argument session)
                 forked)))
      (let ((candidate (list :native-sync-pending 'stale
                             :native-sync-confirmed-p t)))
        (should (ebox-native-commit--isolate-session nil candidate))
        (should (eq (plist-get candidate :native-sync-session) created))
        (should (equal create-arguments
                       '(:workers 1 :max-jobs 4 :max-results 4)))
        (should-not fork-argument)
        (should-not (plist-get candidate :native-sync-pending))
        (should-not (plist-get candidate :native-sync-confirmed-p)))
      (let* ((committed (list 'committed-session))
             (candidate (list :native-sync-pending 'stale
                              :native-sync-confirmed-p t)))
        (setq create-arguments nil)
        (should
         (ebox-native-commit--isolate-session
          (list :native-sync-session committed) candidate))
        (should (eq fork-argument committed))
        (should (eq (plist-get candidate :native-sync-session) forked))
        (should-not create-arguments)
        (should-not (plist-get candidate :native-sync-pending))
        (should (plist-get candidate :native-sync-confirmed-p))))))

(ert-deftest ebox-native-published-frame-confirms-exact-runtime-revision ()
  "A pending frame is confirmed only at the installed runtime revision."
  (let ((session (list 'candidate-session))
        confirmed)
    (cl-letf (((symbol-function 'ebox-native-reflow-confirm-native-frame)
               (lambda (&rest arguments)
                 (setq confirmed arguments)
                 t)))
      (let ((state (list :native-sync-session session
                         :native-sync-pending
                         '(:generation 3 :key 7 :confirmed-revision 11)
                         :native-sync-confirmed-p nil
                         :runtime-revision 11)))
        (should (eq (ebox-native-commit-confirm-published-frame state 11)
                    state))
        (should (equal confirmed (list session 3 7 11)))
        (should (plist-get state :native-sync-confirmed-p))
        (should-not (plist-member state :native-sync-pending)))
      (let ((state (list :native-sync-session session
                         :native-sync-pending
                         '(:generation 3 :key 7 :confirmed-revision 11)
                         :runtime-revision 10)))
        (should-error (ebox-native-commit-confirm-published-frame state 10))
        (should (plist-member state :native-sync-pending))))))

(ert-deftest ebox-native-session-isolation-rejects-create-and-fork-errors ()
  "A failed private-session operation preserves state and its diagnosis."
  (dolist (previous
           (list nil (list :native-sync-session (list 'committed-session))))
    (let ((candidate (list :native-sync-pending 'unchanged
                           :native-sync-confirmed-p t)))
      (cl-letf (((symbol-function 'ebox-native-reflow-create-session)
                 (lambda (&rest _) (error "create failed")))
                ((symbol-function 'ebox-native-reflow-fork-session)
                 (lambda (&rest _) (error "fork failed"))))
        (should-not
         (ebox-native-commit--isolate-session
          previous candidate))
        (should-not (plist-member candidate :native-sync-session))
        (should (eq (plist-get candidate :native-sync-pending) 'unchanged))
        (should (plist-get candidate :native-sync-confirmed-p))
        (let ((failure (plist-get candidate :native-session-setup-failure)))
          (should (eq (plist-get failure :phase)
                      (if previous 'fork 'create)))
          (should (eq (car (plist-get failure :condition)) 'error)))))))

(ert-deftest ebox-native-session-setup-failure-enters-public-report ()
  "Ordinary fallback reports and consumes a native setup failure."
  (let* ((failure '(:phase create :condition (error "setup failed")))
         (state (list :runtime-revision 2
                      :native-session-setup-failure failure))
         report)
    (cl-letf (((symbol-function 'tp-surface-report-summary)
               (lambda (_surface)
                 '(:transaction-id 7 :text-operations 1
                   :property-operations 0 :full-root t :scope-count 0)))
              ((symbol-function 'tp-surface-revision)
               (lambda (_surface) 3)))
      (setq report
            (ebox-surface--commit-report
             'surface state
             '(:strategy native-frame :publication-scope layout-owners))))
    (should (eq (plist-get report :strategy) 'ordinary-fallback))
    (should (equal (plist-get report :native-fallback-reason) failure))
    (should-not (plist-member state :native-session-setup-failure))))

(ert-deftest ebox-native-session-retirement-contains-release-failures ()
  "Losing native sessions all retire and return diagnostics after commit."
  (let ((old (list 'old-session))
        (candidate (list 'candidate-session))
        (committed (list 'committed-session))
        released)
    (cl-letf (((symbol-function 'tp-surface-client-state)
               (lambda (_surface)
                 (list :native-sync-session committed)))
              ((symbol-function 'ebox-surface--release-native-session)
               (lambda (session)
                 (push session released)
                 (when (eq session old)
                   (error "release failed")))))
      (let ((diagnostics
             (ebox-surface--settle-native-session
              (list :native-sync-session old)
              (list :native-sync-session candidate)
              'surface t)))
        (should (equal (nreverse released) (list old candidate)))
        (should (= 1 (length diagnostics)))
        (should (eq (plist-get (car diagnostics) :phase)
                    'native-session-retirement))
        (should (eq (car (plist-get (car diagnostics) :condition))
                    'error))))))

(ert-deftest ebox-native-object-delta-orders-moved-and-new-nodes ()
  "A topology delta names parents before moved and introduced children."
  (let* ((old-input
          (ebox-test-column (ebox-test-box :key 'a (ebox-test-text "A"))
                            (ebox-test-box :key 'b (ebox-test-text "B"))))
         (old-root (ebox-test-root old-input))
         (_old-ids (ebox--runtime-node-ids old-root))
         (old-index
          (ebox--runtime-index old-root t (ebox-test-source-index old-input)))
         (old-objects (make-hash-table :test 'equal))
         (new-input
          (ebox-test-column (ebox-test-box :key 'b (ebox-test-text "B"))
                            (ebox-test-box :key 'a (ebox-test-text "A"))
                            (ebox-test-box :key 'c (ebox-test-text "C"))))
         (new-root (ebox-test-root new-input))
         (new-source-index
          (ebox-tree-source-index
           new-root nil nil (ebox-test-source-index new-input)))
         (_reconciled
          (ebox-tree-reconcile-runtime
           old-root (plist-get old-index :source-index)
           new-root new-source-index))
         (new-index (ebox--runtime-index new-root t new-source-index))
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
           (children (ebox-tree--children-raw new-root))
           (introduced (car (last children))))
      (should
       (equal delta
              (append
               (list root-id
                     (plist-get (car children) :node-id)
                     (plist-get (cadr children) :node-id))
               (ebox--runtime-node-ids introduced)))))))

(ert-deftest ebox-native-object-delta-requires-complete-removal-proof ()
  "An unreported disappeared object rejects the native topology delta."
  (let* ((old-input
          (ebox-test-column (ebox-test-box :key 'a (ebox-test-text "A"))
                            (ebox-test-box :key 'tail (ebox-test-text "T"))
                            (ebox-test-box :key 'b (ebox-test-text "B"))))
         (old-root (ebox-test-root old-input))
         (_old-ids (ebox--runtime-node-ids old-root))
         (old-index
          (ebox--runtime-index old-root t (ebox-test-source-index old-input)))
         (old-objects (make-hash-table :test 'equal))
         (removed-node (car (last (ebox-tree--children-raw old-root))))
         (new-input
          (ebox-test-column (ebox-test-box :key 'a (ebox-test-text "A"))
                            (ebox-test-box :key 'tail (ebox-test-text "T"))))
         (new-root (ebox-test-root new-input))
         (new-source-index
          (ebox-tree-source-index
           new-root nil nil (ebox-test-source-index new-input)))
         (_reconciled
          (ebox-tree-reconcile-runtime
           old-root (plist-get old-index :source-index)
           new-root new-source-index))
         (new-index (ebox--runtime-index new-root t new-source-index))
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
               (ebox--runtime-node-ids removed-node))))))))

(ert-deftest ebox-native-frame-spec-patches-only-stable-topology ()
  "Only a topology-stable candidate may request a confirmed native patch."
  (let* ((node
          (ebox-test-box :key 'root (ebox-test-text "Frame") :width '(100)))
         (state
          (list :viewport-width 120 :viewport-height 10
                :runtime-revision 3 :display-signature '(display)
                :native-sync-confirmed-p t
                :native-base-viewport-width 80
                :native-base-viewport-height 10
                :native-base-root-width 80
                :native-topology-stable-p nil))
         (full (ebox-native-commit--frame-spec state node)))
    (should full)
    (should-not (plist-member full :base-viewport-width))
    (plist-put state :native-topology-stable-p t)
    (let ((patch (ebox-native-commit--frame-spec state node)))
      (should (= (plist-get patch :base-viewport-width) 80))
      (should (= (plist-get patch :base-viewport-height) 10))
      (should (= (plist-get patch :base-root-width) 80)))))

(ert-deftest ebox-style-schema-composition-is-not-per-node-work ()
  "Repeated node construction must not rebuild the immutable schema domain."
  (let ((package-calls 0)
        (compose-calls 0)
        (original-package (symbol-function 'ecss-schema-package-create))
        (original-compose (symbol-function 'ecss-schema-set-compose)))
    (cl-letf (((symbol-function 'ecss-schema-package-create)
               (lambda (&rest arguments)
                 (cl-incf package-calls)
                 (apply original-package arguments)))
              ((symbol-function 'ecss-schema-set-compose)
               (lambda (&rest arguments)
                 (cl-incf compose-calls)
                 (apply original-compose arguments))))
      (dotimes (_ 24)
        (ebox-test-box (ebox-test-text "schema-hot-path") :color "#111111")))
    (should (= package-calls 0))
    (should (= compose-calls 0))))

(ert-deftest ebox-style-declaration-compilation-is-memoized ()
  "Repeated equivalent style declarations compile through ECSS once."
  (clrhash ebox-style--declaration-cache)
  (let ((calls 0)
        (original (symbol-function 'ecss-expand-declarations)))
    (cl-letf (((symbol-function 'ecss-expand-declarations)
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
                  (ebox-test-box :key 'root (ebox-test-text "Before") :width '(80))))
         (report (ebox-commit
                  buffer
                  (ebox-test-box :key 'root (ebox-test-text "After") :width '(80)))))
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

(ert-deftest ebox-commit-ignores-caller-narrowing ()
  "A full Ebox surface commit must not inherit caller narrowing."
  (let ((buffer
         (ebox-render-to-buffer
          (generate-new-buffer-name " *ebox-commit-narrowing*")
          (ebox-test-box :key 'root (ebox-test-text "Before")
                         :width '(80))))
        report)
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (goto-char (1+ (point-min)))
            (narrow-to-region (point) (point-max))
            (setq report
                  (ebox-commit
                   buffer
                   (ebox-test-box :key 'root (ebox-test-text "After!")
                                  :width '(80)))))
          (should (plist-get report :runtime-published))
          (should
           (string-prefix-p
            "After!"
            (string-trim-right
             (substring-no-properties
              (ebox-commit-test--buffer-string buffer))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-commit-preserves-keyed-sibling-identity ()
  "Keyed siblings should remain addressable after a reorder commit."
  (let* ((buffer (ebox-render-to-buffer
                  (generate-new-buffer-name " *ebox-commit-keyed*")
                  (ebox-test-column
                   (ebox-test-box :key 'a :source-identity 'a (ebox-test-text "A") :width '(40))
                   (ebox-test-box :key 'b :source-identity 'b (ebox-test-text "B") :width '(40)))))
         (old-b (ebox-host-ref-position buffer 'b))
         (report (ebox-commit
                  buffer
                  (ebox-test-column
                   (ebox-test-box :key 'b :source-identity 'b (ebox-test-text "B2") :width '(40))
                   (ebox-test-box :key 'a :source-identity 'a (ebox-test-text "A") :width '(40))))))
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
           (ebox-test-column
            (ebox-test-box :key 'a :source-identity 'a (ebox-test-text "A") :width '(40))
            (ebox-test-box :key 'b :source-identity 'b (ebox-test-text "B") :width '(40)))))
         (surface (with-current-buffer buffer ebox-surface--buffer-surface))
         (revision (tp-surface-revision surface))
         (candidate (ebox-candidate-begin buffer)))
    (unwind-protect
        (progn
          (ebox-candidate-replace-host-ref
           candidate 'a (ebox-test-box :key 'a (ebox-test-text "ignored-before")))
          (ebox-candidate-replace-root
           candidate
           (ebox-test-box :key 'root :source-identity 'a (ebox-test-text "first-root")
                        :width '(80)))
          (ebox-candidate-replace-host-ref
           candidate 'b (ebox-test-box :key 'b (ebox-test-text "ignored-after")))
          (ebox-candidate-replace-root
           candidate
           (ebox-test-box :key 'root :source-identity 'b (ebox-test-text "final-root")
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
            candidate (ebox-test-box :key 'root (ebox-test-text "sealed")))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-commit-framework-participant-completes-and-rolls-back ()
  "Framework publication is paired, diagnosed, and completed exactly once."
  (let ((buffer (generate-new-buffer " *ebox-framework-participant*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer
              buffer (ebox-test-box :key 'root (ebox-test-text "old") :width '(80)))
          (let (trace)
            (let ((report
                   (ebox-commit
                    buffer (ebox-test-box :key 'root (ebox-test-text "new") :width '(80))
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
                         (ebox-test-box :key 'root (ebox-test-text "rejected")
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

(ert-deftest ebox-transaction-participant-is-v2-only ()
  "Mount and commit register only through TP's structured participant API."
  (should (= (ebox-commit-test--participant-v2-count) 2)))

(ert-deftest ebox-transaction-participant-accepts-structured-protocols ()
  "Both consumer-first and final TP manifests satisfy Ebox's v2 contract."
  (dolist (protocol '(tp-transaction-protocol-v1+v2
                      tp-transaction-protocol-v2))
    (should
     (ebox-surface--validate-tp-v2-capability
      (list :transaction-protocol protocol
            :structured-participant-api
            'tp-transaction-participate-v2)))))

(ert-deftest ebox-transaction-participant-rejects-missing-or-malformed-v2 ()
  "Missing or incompatible structured capabilities fail closed."
  (should-error
   (ebox-surface--validate-tp-v2-capability
    '(:transaction-protocol tp-transaction-protocol-v1+v2))
   :type 'ebox-surface-tp-protocol-error)
  (should-error
   (ebox-surface--validate-tp-v2-capability
    '(:transaction-protocol tp-transaction-protocol-v1+v2
      :structured-participant-api ignore))
   :type 'ebox-surface-tp-protocol-error)
  (should-error
   (ebox-surface--validate-tp-v2-capability
    '(:transaction-protocol incompatible
      :structured-participant-api tp-transaction-participate-v2))
   :type 'ebox-surface-tp-protocol-error))

(ert-deftest ebox-commit-framework-publish-failure-rolls-back-full-and-scoped ()
  "A framework publish failure invokes its pair once on both commit paths."
  (dolist (mode '(full scoped))
    (let ((buffer (generate-new-buffer " *ebox-framework-publish-fail*")))
      (unwind-protect
          (progn
            (ebox-render-to-buffer
                buffer
              (ebox-test-column
               (ebox-test-box :key 'a :source-identity 'a (ebox-test-text "old-a") :width '(40))
               (ebox-test-box :key 'b :source-identity 'b (ebox-test-text "old-b") :width '(40))))
            (let ((before (ebox-commit-test--buffer-string buffer))
                  (candidate (ebox-candidate-begin buffer))
                  trace captured)
              (when (eq mode 'scoped)
                (ebox-candidate-replace-host-ref
                 candidate 'a
                 (ebox-test-box :key 'a :source-identity 'a (ebox-test-text "new-a")
                              :width '(40))))
              (should-error
               (ebox-commit
                buffer
                (if (eq mode 'scoped)
                    candidate
                  (ebox-test-box :key 'root (ebox-test-text "new-root") :width '(80)))
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
        (root (ebox-test-box :key 'root (ebox-test-text "x"))))
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
          (ebox-test-column
           (ebox-test-box :key 'panel :padding '(1 (2))
                        :border "#687386" :bgcolor "#FFFDF8"
                        (ebox-test-text "Panel"))
           (ebox-test-box :key 'payload :padding '(0 (1))
                        :border "#AAA" (ebox-test-text "No payload yet."))
           (ebox-test-box :key 'later :padding '(0 (1))
                        :border "#BBB" (ebox-test-text "Later sibling"))))
         (new-root
          (ebox-test-column
           (ebox-test-box :key 'panel :padding '(1 (2))
                        :border "#687386" :bgcolor "#FFFDF8"
                        (ebox-test-text "Panel"))
           (ebox-test-box :key 'payload :padding '(0 (1))
                        :border "#AAA"
                        (ebox-test-text "Payload received: payload=42"))
           (ebox-test-box :key 'later :padding '(0 (1))
                        :border "#BBB" (ebox-test-text "Later sibling"))))
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
                 (ebox-test-column
                  (ebox-test-box :key 'first :class "card" (ebox-test-text "Before")
                               :width '(40))
                  (ebox-test-box :key 'second :class "card" (ebox-test-text "Stable")
                               :width '(40)))))
          (setq calls 0)
          (cl-letf (((symbol-function 'ecss-compute-style)
                     (lambda (&rest arguments)
                       (cl-incf calls)
                       (apply original arguments))))
            (ebox-commit
             buffer
             (ebox-test-column
              (ebox-test-box :key 'first :class "card" (ebox-test-text "After")
                           :width '(40))
              (ebox-test-box :key 'second :class "card" (ebox-test-text "Stable")
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
                 (ebox-test-column
                  (ebox-test-box :key 'first :class "card" (ebox-test-text "Before")
                               :width '(40))
                  (ebox-test-box :key 'second :class "card" (ebox-test-text "Stable")
                               :width '(40)))))
          (cl-letf (((symbol-function 'ebox-surface--subject-signature)
                     (lambda (&rest arguments)
                       (cl-incf calls)
                       (apply original arguments))))
            (ebox-commit
             buffer
             (ebox-test-column
              (ebox-test-box :key 'first :class "card" (ebox-test-text "After")
                           :width '(40))
              (ebox-test-box :key 'second :class "card" (ebox-test-text "Stable")
                           :width '(40))))
            (should (= calls 1))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-commit-reuses-local-selector-styles-across-tree-change ()
  "A subject-local stylesheet should compute only the new Box and Text facts."
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
                 (ebox-test-column
                  (ebox-test-box :key 'first :class "card" (ebox-test-text "First")
                               :width '(40))
                  (ebox-test-box :key 'second :class "card" (ebox-test-text "Second")
                               :width '(40)))))
          (cl-letf (((symbol-function 'ecss-compute-style)
                     (lambda (&rest arguments)
                       (cl-incf calls)
                       (apply original arguments))))
            (ebox-commit
             buffer
             (ebox-test-column
              (ebox-test-box :key 'first :class "card" (ebox-test-text "First")
                           :width '(40))
              (ebox-test-box :key 'second :class "card" (ebox-test-text "Second")
                           :width '(40))
              (ebox-test-box :key 'third :class "card" (ebox-test-text "Third")
                           :width '(40)))))
          (should (= calls 2))
          (let* ((text (ebox-commit-test--buffer-string buffer))
                 (position (string-match "Third" text)))
            (should position)
            (should (equal (ebox-commit-test--face-value
                            (get-text-property position 'face text)
                            :foreground)
                           "#2255AA"))))
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
                 (ebox-test-column
                  (ebox-test-box :key 'state :class "inactive" (ebox-test-text "State")
                               :width '(40))
                  (ebox-test-box :key 'target :class "target" (ebox-test-text "Target")
                               :width '(40)))))
          (let* ((before (ebox-commit-test--buffer-string buffer))
                 (position (string-match "Target" before)))
            (should position)
            (should-not (get-text-property position 'face before)))
          (ebox-commit
           buffer
           (ebox-test-column
            (ebox-test-box :key 'state :class "active" (ebox-test-text "State")
                         :width '(40))
            (ebox-test-box :key 'target :class "target" (ebox-test-text "Target")
                         :width '(40))))
          (let* ((after (ebox-commit-test--buffer-string buffer))
                 (position (string-match "Target" after)))
            (should position)
            (should (equal (ebox-commit-test--face-value
                            (get-text-property position 'face after)
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
                 (ebox-test-box :key 'card :class "card" (ebox-test-text "Stable")
                              :width '(40))))
          (should (equal (ebox-commit-test--face-value
                          (get-text-property (point-min) 'face buffer)
                          :foreground)
                         "#111111"))
          (ebox-style-add-rule ".card" '(:color "#222222") :layer 'components)
          (ebox-commit
           buffer
           (ebox-test-box :key 'card :class "card" (ebox-test-text "Stable")
                        :width '(40)))
          (should (equal (ebox-commit-test--face-value
                          (get-text-property (point-min) 'face buffer)
                          :foreground)
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
                 (ebox-test-box :key 'card :class "card" (ebox-test-text "Before")
                              :width '(40))))
          (should-not (get-text-property (point-min) 'face buffer))
          (ebox-style-add-rule ".card" '(:color "#2255AA")
                               :layer 'components)
          (let ((report
                 (ebox-commit
                  buffer
                  (ebox-test-box :key 'card :class "card" (ebox-test-text "After")
                               :width '(40)))))
            (should (string-prefix-p
                     "After"
                     (string-trim-right
                      (substring-no-properties
                       (ebox-commit-test--buffer-string buffer)))))
            (should-not (eq (plist-get report :strategy) 'span-patch))
            (should (equal (ebox-commit-test--face-value
                            (get-text-property (point-min) 'face buffer)
                            :foreground)
                           "#2255AA"))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))


(ert-deftest ebox-commit-formatting-context-reflow-owns-variable-line-siblings ()
  "Two variable-line owners should publish through their nearest stack context.
The context owns the complete local block; the root and untouched header/footer
remain retained identities."
  (let* ((old-root
          (ebox-test-column
           (ebox-test-box :key 'header (ebox-test-text "Header") :width '(160))
           (ebox-test-box
            :key 'shell :width '(160)
            (ebox-test-column
             (ebox-test-box :key 'message :source-identity 'message
                          (ebox-test-text "Callback action pending"))
             (ebox-test-flex :width '(120) :height 1
                        (ebox-test-box :key 'toggle :source-identity 'toggle
                                     (ebox-test-text "Behavior: off")))))
           (ebox-test-box :key 'footer (ebox-test-text "Footer") :width '(160))))
         (new-message
          (ebox-test-box :key 'message :source-identity 'message
                       (ebox-test-text "Behavior toggle: on / callback active / a longer status line")))
         (new-toggle
          (ebox-test-box :key 'toggle :source-identity 'toggle
                       (ebox-test-text "Behavior: on")))
         (new-root
          (ebox-test-column
           (ebox-test-box :key 'header (ebox-test-text "Header") :width '(160))
           (ebox-test-box
            :key 'shell :width '(160)
            (ebox-test-column
             new-message
             (ebox-test-flex :width '(120) :height 1 new-toggle)))
           (ebox-test-box :key 'footer (ebox-test-text "Footer") :width '(160))))
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
                               (parent-table (plist-get state :parent-table))
                               (node-id (and region-node-table
                                             (gethash value region-node-table)))
                               (source-node-id node-id)
                               (root-node-id
                                (plist-get (plist-get state :root-node)
                                           :node-id))
                               key)
                          (while (and node-id (not key))
                            (when-let* ((node (gethash node-id node-table)))
                              (setq key
                                    (ebox-tree-node-key
                                     (plist-get state :source-index) node)))
                            (setq node-id
                                  (and (not key)
                                       (gethash node-id parent-table))))
                          (or key
                              (and (equal source-node-id root-node-id) 'root)
                              value))
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
         (ebox-test-column
          (ebox-test-box :key 'header (ebox-test-text "Header") :width '(160))
          (ebox-test-box
           :key 'shell :width '(160)
           (ebox-test-column
            (ebox-test-box :key 'message :source-identity 'message (ebox-test-text message))
            (ebox-test-flex :width '(120) :height 1
                       (ebox-test-box :key 'toggle :source-identity 'toggle
                                    (ebox-test-text toggle)))))
          (ebox-test-box :key 'footer (ebox-test-text "Footer") :width '(160)))))
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
                 (ebox-test-box
                  :key 'message :source-identity 'message
                  (ebox-test-text "Behavior toggle: on / callback active / a longer status line")))
                (ebox-candidate-replace-host-ref
                 candidate 'toggle
                 (ebox-test-box :key 'toggle :source-identity 'toggle
                              (ebox-test-text "Behavior: on")))
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
                   (ebox-test-box
                    :key 'message :source-identity 'message
                    (ebox-test-text "Behavior toggle: on / callback active / a longer status line")))
                  (ebox-candidate-replace-host-ref
                   retry 'toggle
                   (ebox-test-box :key 'toggle :source-identity 'toggle
                                (ebox-test-text "Behavior: on")))
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
          (ebox-test-box :key 'left :source-identity 'left
                       (ebox-test-text "L")))
         (new-right
          (ebox-test-box :key 'right :source-identity 'right (ebox-test-text "R")))
         (old-root
          (ebox-test-grid :key 'grid :width '(80) :grid-template-columns
		'((36) (36)) :column-gap '(8)
		(ebox-test-box :key 'left :source-identity 'left (ebox-test-text "left-old"))
		(ebox-test-box :key 'right :source-identity 'right (ebox-test-text "right-old"))))
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
          ;; The 8px Grid gap keeps the two changed slots disjoint.  TP still
          ;; publishes one scoped transaction, with one exact text operation
          ;; per changed slot instead of replacing the unchanged gap.
          (should (= 2 (plist-get report :tp-text-operations)))
          (should (string-match-p "L"
                                  (ebox-commit-test--buffer-string buffer)))
          (setq fresh
                (ebox-render-to-buffer
                 (generate-new-buffer-name
                  " *ebox-multi-owner-variable-slots-fresh*")
                 (ebox-test-grid :key 'grid :width '(80) :grid-template-columns
		'((36) (36)) :column-gap '(8)
		(ebox-test-box :key 'left :source-identity 'left (ebox-test-text "L"))
		(ebox-test-box :key 'right :source-identity 'right (ebox-test-text "R")))))
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
         (ebox-test-grid :key 'grid :width '(80)
                    :grid-template-columns '((36) (36))
                    :column-gap '(8)
                    (ebox-test-box :key 'left :source-identity 'left (ebox-test-text left))
                    (ebox-test-box :key 'right :source-identity 'right (ebox-test-text right))))
       (candidate (buffer)
         (let ((candidate (ebox-candidate-begin buffer)))
           (ebox-candidate-replace-host-ref
            candidate 'left
            (ebox-test-box :key 'left :source-identity 'left (ebox-test-text "L")))
           (ebox-candidate-replace-host-ref
            candidate 'right
            (ebox-test-box :key 'right :source-identity 'right (ebox-test-text "R")))
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

(ert-deftest ebox-commit-updates-selector-type-counts ()
  "A structural candidate should publish exact author selector-type counts."
  (let* ((buffer
          (ebox-render-to-buffer
           (generate-new-buffer-name " *ebox-commit-types*")
           (ebox-build
            '(flex :key root :width (80)
                   (box :key child :width (40) "A")))))
         (before (gethash buffer ebox--buffer-render-state-table)))
    (unwind-protect
        (progn
          (should (= (gethash
                      'box (plist-get before :runtime-type-count-table))
                     1))
          (should (= (gethash
                      'flex (plist-get before :runtime-type-count-table))
                     1))
          (should (= (gethash
                      'text (plist-get before :runtime-type-count-table))
                     1))
          (ebox-commit
           buffer (ebox-build '(box :key root :width (80) "B")))
          (let ((after (gethash buffer ebox--buffer-render-state-table)))
            (should-not
             (gethash 'item (plist-get after :runtime-type-count-table)))
            (should-not
             (gethash 'flex (plist-get after :runtime-type-count-table)))
            (should (= (gethash
                        'box (plist-get after :runtime-type-count-table))
                       1))
            (should (= (gethash
                        'text (plist-get after :runtime-type-count-table))
                       1))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-commit-rolls-back-on-invalid-root ()
  "A failed candidate must leave the previously published buffer intact."
  (let ((buffer (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-commit-rollback*")
                 (ebox-test-box :key 'root (ebox-test-text "Stable") :width '(80)))))
    (unwind-protect
        (progn
          (should-error
           (ebox-commit buffer (ebox-test-box :key 'root (ebox-test-text nil)
                                             :width 'invalid)))
          (should (string-prefix-p
                   "Stable"
                   (string-trim-right
                    (substring-no-properties
                     (ebox-commit-test--buffer-string buffer))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-candidate-rejects-invalid-final-parent-participation ()
  "A detached replacement must be revalidated after its final graft."
  (let* ((buffer
          (ebox-render-to-buffer
           (generate-new-buffer-name " *ebox-participation-rollback*")
           (ebox-test-column
            (ebox-test-box :key 'target :source-identity 'target
                         (ebox-test-text "Stable") :width '(80)))))
         (surface (with-current-buffer buffer ebox-surface--buffer-surface))
         (revision (tp-surface-revision surface))
         (before (ebox-commit-test--buffer-string buffer))
         (candidate (ebox-candidate-begin buffer)))
    (unwind-protect
        (progn
          ;; Detached subtrees do not know their parent yet, so recording the
          ;; replacement is legal.  The final Column graft is authoritative.
          (ebox-candidate-replace-host-ref
           candidate 'target
           (ebox-test-box :key 'target :source-identity 'target
                        (ebox-test-text "Invalid") :width '(80) :flex-grow 1))
          (should-error (ebox-commit buffer candidate) :type 'error)
          (should (= (tp-surface-revision surface) revision))
          (should (equal (ebox-commit-test--buffer-string buffer) before)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-candidate-participation-validation-stays-changed-local ()
  "One replacement must not participation-validate every sibling."
  (let* ((children
          (cl-loop for index below 200
                   collect
                   (if (= index 99)
                       (ebox-test-box :key index :source-identity 'target
                                    (ebox-test-text (number-to-string index)))
                     (ebox-test-box :key index
                                  (ebox-test-text (number-to-string index))))))
         (buffer
          (ebox-render-to-buffer
           (generate-new-buffer-name " *ebox-participation-local*")
           (apply #'ebox-test-column children)))
         (candidate (ebox-candidate-begin buffer))
         (original
          (symbol-function 'ebox-tree-validate-indexed-participation))
         validation-frontiers)
    (unwind-protect
        (progn
          (ebox-candidate-replace-host-ref
           candidate 'target
           (ebox-test-box :key 99 :source-identity 'target (ebox-test-text "changed")))
          (cl-letf
              (((symbol-function 'ebox-tree-validate-indexed-participation)
                (lambda (node-table parent-table node-ids
                         &optional source source-index)
                  (push (cons source (length node-ids))
                        validation-frontiers)
                  (funcall original node-table parent-table node-ids
                           source source-index))))
            (ebox-commit buffer candidate))
          ;; The changed Box, its Text leaf, and direct parent context are the
          ;; complete validation frontier; 197 siblings remain untouched.
          (should (equal validation-frontiers '((computed . 3)))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-candidate-root-replacement-reuses-candidate-validity-contract ()
  "Root replacement rejects invalid, other-buffer, stale, and sealed use."
  (let ((first (generate-new-buffer " *ebox-root-valid-first*"))
        (second (generate-new-buffer " *ebox-root-valid-second*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer first (ebox-test-box :key 'root (ebox-test-text "one")))
          (ebox-render-to-buffer second (ebox-test-box :key 'root (ebox-test-text "two")))
          (let ((candidate (ebox-candidate-begin first)))
            (should-error (ebox-candidate-replace-root candidate "invalid"))
            (ebox-candidate-replace-root
             candidate (ebox-test-box :key 'root (ebox-test-text "candidate")))
            (should-error (ebox-commit second candidate))
            (should-error
             (ebox-candidate-replace-root
              candidate (ebox-test-box :key 'root (ebox-test-text "sealed")))))
          (let ((candidate (ebox-candidate-begin first)))
            (ebox-candidate-replace-root
             candidate (ebox-test-box :key 'root (ebox-test-text "stale")))
            (ebox-commit first (ebox-test-box :key 'root (ebox-test-text "new-base")))
            (should-error (ebox-commit first candidate))))
      (dolist (buffer (list first second))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest ebox-commit-two-and-three-argument-compatibility ()
  "Two-argument commits complete and legacy callbacks receive one same report."
  (let ((buffer (generate-new-buffer " *ebox-framework-compat*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer buffer (ebox-test-box :key 'root (ebox-test-text "0")))
          (should (eq (plist-get
                       (ebox-commit buffer (ebox-test-box :key 'root (ebox-test-text "1")))
                       :framework-participant-state)
                      'completed))
          (let ((calls 0) seen)
            (let ((report
                   (ebox-commit
                    buffer (ebox-test-box :key 'root (ebox-test-text "2"))
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
              (ebox-test-column
               (ebox-test-box :key 'a :source-identity 'a (ebox-test-text "old-a"))
               (ebox-test-box :key 'b :source-identity 'b (ebox-test-text "old-b"))))
            (let* ((before (ebox-commit-test--buffer-string buffer))
                   (candidate (ebox-candidate-begin buffer))
                   trace captured failure)
              (ebox-candidate-replace-host-ref
               candidate 'a (ebox-test-box :key 'a :source-identity 'a (ebox-test-text "new-a")))
              (cl-letf (((symbol-function 'accept-change-group)
                         (lambda (_group) (error "accept failed"))))
                (setq failure
                      (condition-case condition
                          (ebox-commit
                           buffer
                           (if (eq mode 'scoped)
                               candidate
                             (ebox-test-box :key 'root (ebox-test-text "new-root")))
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
                            buffer (ebox-test-box :key 'root (ebox-test-text "next")))
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
          (ebox-render-to-buffer buffer (ebox-test-box :key 'root (ebox-test-text "0")))
          (cl-letf
              (((symbol-function
                 'ebox-incremental--finalize-declarative-scroll-publication)
                (lambda (&rest _arguments) diagnostics)))
            (let ((report
                   (ebox-commit
                    buffer (ebox-test-box :key 'root (ebox-test-text "1")))))
              (should (eq (plist-get report :framework-participant-state)
                          'completed))
              (should (equal
                       (plist-get report :scroll-finalization-diagnostics)
                       diagnostics))))
          (should (eq (plist-get
                       (ebox-commit buffer
                                    (ebox-test-box :key 'root (ebox-test-text "2")))
                       :framework-participant-state)
                      'completed)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-commit-restores-ebox-after-participant-owner-failure ()
  "A rollback-owner failure cannot skip restoration of Ebox runtime state."
  (let ((buffer (generate-new-buffer " *ebox-participant-owner-failure*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer buffer (ebox-test-box :key 'root (ebox-test-text "old")))
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
                         buffer (ebox-test-box :key 'root (ebox-test-text "new"))
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
  (ebox-test-column
   (ebox-test-box
    :key 'geometry-context :width '(80)
    (ebox-test-column
     (ebox-test-box :key 'left :source-identity 'left
                  (ebox-test-text left) :font-weight 'bold)
     (ebox-test-box :key 'right :source-identity 'right
                  (ebox-test-text right))))
   (ebox-test-box :key 'paint-a :source-identity 'paint-a
                (ebox-test-text "paint-a") :color paint-a)
   (ebox-test-box :key 'paint-b :source-identity 'paint-b
                (ebox-test-text "paint-b") :bgcolor paint-b)
   (ebox-test-box :key 'paint-c :source-identity 'paint-c
                (ebox-test-text "paint-c") :color paint-c)
   (ebox-test-box :key 'untouched :source-identity 'untouched
                (ebox-test-text "untouched"))))

(ert-deftest ebox-candidate-host-paint-patch-preserves-subtree-identity ()
  "Patch one Host's paint without copying or reconciling its descendants."
  (let* ((buffer
          (ebox-render-to-buffer
           (generate-new-buffer-name " *ebox-host-paint-patch* ")
           (ebox-test-box
            :key 'target :source-identity 'target :bgcolor "#111111"
            (ebox-test-column
             (ebox-test-box :key 'child :source-identity 'child (ebox-test-text "child"))))))
         (child-id (plist-get (ebox--host-ref-node buffer 'child) :node-id)))
    (unwind-protect
        (progn
          (let ((candidate (ebox-candidate-begin buffer)))
            (ebox-candidate-patch-host-paint
             candidate 'target
             (ebox-test-box
              :key 'target :source-identity 'target :bgcolor "#111111"
              (ebox-test-column
               (ebox-test-box :key 'child :source-identity 'child (ebox-test-text "child"))))
             (ebox-test-box
              :key 'target :source-identity 'target :bgcolor "#EEEEEE"
              (ebox-test-column
               (ebox-test-box :key 'child :source-identity 'child (ebox-test-text "child")))))
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
              (ebox-test-box
               :key 'target :source-identity 'target :bgcolor "#EEEEEE"
               (ebox-test-text "child"))
              (ebox-test-box
               :key 'target :source-identity 'target :bgcolor "#EEEEEE"
               :width '(40) (ebox-test-text "child")))))
          (let ((candidate (ebox-candidate-begin buffer)))
            (should
             (ebox-candidate-patch-host-paint
              candidate 'target
              (ebox-test-box
               :key 'target :source-identity 'target :bgcolor "#EEEEEE"
               (ebox-test-column
                (ebox-test-box :key 'child :source-identity 'child (ebox-test-text "child"))))
              (ebox-test-box
               :key 'target :source-identity 'target :bgcolor "#EEEEEE"
               :color "#FFFFFF"
               (ebox-test-column
                (ebox-test-box :key 'child :source-identity 'child (ebox-test-text "child"))))))
            (ebox-commit buffer candidate)
            (should
             (equal "#FFFFFF"
                    (ebox-style-node-specified-value
                     (ebox--host-ref-node buffer 'target) :color nil
                     (plist-get (ebox--buffer-render-state buffer)
                                :source-index))))
            (let* ((rendered (ebox-commit-test--buffer-string buffer))
                   (position (string-match "child" rendered)))
              (should position)
              (should
               (equal "#FFFFFF"
                      (ebox-commit-test--face-value
                       (get-text-property position 'face rendered)
                       :foreground))))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(defun ebox-commit-test--fixed-basis-selection-root (row-1 row-2)
  "Return a stretched fixed-basis panel containing two selectable rows."
  (let ((panel
         (ebox-test-box
          :key 'selection-panel :width 'stretch :min-width 0 :min-height 24
          :flex-grow 2 :flex-shrink 1 :flex-basis '(340)
          (ebox-test-column
           (ebox-test-box :key 'row-1 :source-identity 'row-1 (ebox-test-text row-1))
           (ebox-test-box :key 'row-2 :source-identity 'row-2 (ebox-test-text row-2))))))
    (ebox-test-flex
     :key 'fixed-basis-selection-root
     :width '(900) :height 24
     :flex-flow '(row nowrap) :align-items 'stretch
     (ebox-test-box :key 'peer (ebox-test-text "peer") :width 'stretch
                  :min-width 0 :min-height 24
                  :flex-grow 4 :flex-shrink 1 :flex-basis '(620))
     panel)))

(defun ebox-commit-test--fixed-basis-selection-candidate
    (buffer row-1 row-2)
  "Return BUFFER candidate replacing both fixed-basis selection rows."
  (let ((candidate (ebox-candidate-begin buffer)))
    (ebox-candidate-replace-host-ref
     candidate 'row-1
     (ebox-test-box :key 'row-1 :source-identity 'row-1 (ebox-test-text row-1)))
    (ebox-candidate-replace-host-ref
     candidate 'row-2
     (ebox-test-box :key 'row-2 :source-identity 'row-2 (ebox-test-text row-2)))
    candidate))

(ert-deftest ebox-commit-fixed-basis-selection-round-trip-stays-local ()
  "Continuous row-1 -> row-2 -> row-1 publication keeps local TP scope."
  (let ((planner-render-count 0)
        (surface-render-count 0)
        (original-planner-render
         (symbol-function 'ebox--flex-item-slot-footprint-safe-p))
        (original-surface-render
         (symbol-function 'ebox-surface--render-candidate-node))
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
          (cl-letf
              (((symbol-function 'ebox--flex-item-slot-footprint-safe-p)
                (lambda (&rest arguments)
                  (cl-incf planner-render-count)
                  (apply original-planner-render arguments)))
               ((symbol-function 'ebox-surface--render-candidate-node)
                (lambda (&rest arguments)
                  (cl-incf surface-render-count)
                  (apply original-surface-render arguments))))
            (dolist (contents '(("[ ] row 1" "[x] row 2")
                                ("[x] row 1" "[ ] row 2")))
              (let* ((report
                    (ebox-commit
                     buffer
                     (ebox-commit-test--fixed-basis-selection-candidate
                      buffer (car contents) (cadr contents))))
                   (surface
                    (with-current-buffer buffer ebox-surface--buffer-surface))
                   (tp-report (tp-surface-report surface))
                   (object-count
                    (plist-get (tp-surface-inspect surface) :object-count))
                   (snapshots
                    (plist-get (ebox--buffer-render-state buffer)
                               :layout-snapshots))
                   (panel-snapshot
                    (and snapshots (gethash panel-id snapshots))))
              (push report reports)
              (should (memq (plist-get report :projection-kind)
                            '(span-patch owner-scoped)))
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
                   (let ((state (ebox--buffer-render-state buffer)))
                     (ebox--render-node
                      (plist-get state :root-node)
                      (plist-get state :source-index))))))))))
          (should (= (length reports) 2))
          (should (zerop planner-render-count))
          (should (= surface-render-count 2)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(defun ebox-commit-test--mixed-owner-candidate
    (buffer left right paint-a paint-b paint-c)
  "Return BUFFER candidate replacing all mixed fixture owners."
  (let ((candidate (ebox-candidate-begin buffer)))
    (ebox-candidate-replace-host-ref
     candidate 'left
     (ebox-test-box :key 'left :source-identity 'left
                  (ebox-test-text left) :font-weight 'bold))
    (ebox-candidate-replace-host-ref
     candidate 'right
     (ebox-test-box :key 'right :source-identity 'right
                  (ebox-test-text right)))
    (ebox-candidate-replace-host-ref
     candidate 'paint-a
     (ebox-test-box :key 'paint-a :source-identity 'paint-a
                  (ebox-test-text "paint-a") :color paint-a))
    (ebox-candidate-replace-host-ref
     candidate 'paint-b
     (ebox-test-box :key 'paint-b :source-identity 'paint-b
                  (ebox-test-text "paint-b") :bgcolor paint-b))
    (ebox-candidate-replace-host-ref
     candidate 'paint-c
     (ebox-test-box :key 'paint-c :source-identity 'paint-c
                  (ebox-test-text "paint-c") :color paint-c))
    candidate))




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
           (ebox-test-column
            (ebox-test-box
             :key 'target :source-identity 'target
             (ebox-test-column (ebox-test-box :key 'first (ebox-test-text "first")))))))
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
           (ebox-test-box
            :key 'target :source-identity 'target
            (ebox-test-column (ebox-test-box :key 'first (ebox-test-text "first"))
                         (ebox-test-box :key 'second (ebox-test-text "second")))))
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
           (ebox-test-column
            (ebox-test-child-range
             'rows (ebox-test-box :key 'old (ebox-test-text "old"))))))
         (state (ebox--buffer-render-state buffer))
         (parent-id
          (plist-get (gethash 'rows (plist-get state :range-ref-table))
                     :parent-node-id))
         captured)
    (unwind-protect
        (let ((candidate (ebox-candidate-begin buffer))
              (next-input (ebox-test-box :key 'new (ebox-test-text "new")))
              (original
               (symbol-function 'ebox-incremental--surface-commit-input)))
          (ebox-candidate-replace-range-ref
           candidate 'rows next-input)
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


(defun ebox-commit-test--allocation-closure-root
    (toast paint-a paint-b &optional width footer-overflow root-overflow)
  "Return a generic whole-line Flex allocation-closure fixture."
  (let* ((footer
          (apply
           #'ebox-test-flex
           (append
            (list :key 'footer :width (list (or width 800))
                  :flex-wrap 'wrap :gap '(1 (4)))
            (when footer-overflow (list :overflow footer-overflow))
            (list
             (ebox-test-box
              :key 'toast-slot :width 'stretch :min-width 0
              :flex-grow 1 :flex-shrink 1 :flex-basis '(0)
              (ebox-test-column
               (ebox-test-box :key 'toast :source-identity 'toast
                              (ebox-test-text toast))))
             (ebox-test-box :key 'peer
                            (ebox-test-text "database.sqlite"))))))
         (content
          (ebox-test-column
           (ebox-test-box :key 'status :source-identity 'status
                          (ebox-test-text "Theme: Light") :width '(200))
           (ebox-test-box :key 'paint-a :source-identity 'paint-a
                          (ebox-test-text "paint-a") :color paint-a)
           (ebox-test-box :key 'paint-b :source-identity 'paint-b
                          (ebox-test-text "paint-b") :bgcolor paint-b)
           (ebox-test-box
            :key 'footer-owner :width (list (or width 800))
            (ebox-test-column footer)))))
    (apply
     #'ebox-test-box
     (append
      (list :key 'root :width (list (or width 800)))
      (when root-overflow (list :height 1 :overflow root-overflow))
      (list content)))))

(defun ebox-commit-test--allocation-closure-candidate
    (buffer toast paint-a paint-b)
  "Return BUFFER candidate changing one Flex content and two paints."
  (let ((candidate (ebox-candidate-begin buffer)))
    (ebox-candidate-replace-host-ref
     candidate 'toast
     (ebox-test-box :key 'toast :source-identity 'toast (ebox-test-text toast)))
    (ebox-candidate-replace-host-ref
     candidate 'paint-a
     (ebox-test-box :key 'paint-a :source-identity 'paint-a
                  (ebox-test-text "paint-a") :color paint-a))
    (ebox-candidate-replace-host-ref
     candidate 'paint-b
     (ebox-test-box :key 'paint-b :source-identity 'paint-b
                  (ebox-test-text "paint-b") :bgcolor paint-b))
    candidate))

(defun ebox-commit-test--two-geometry-allocation-candidate
    (buffer status toast paint-a paint-b)
  "Return BUFFER candidate with one span and one allocation geometry owner."
  (let ((candidate
         (ebox-commit-test--allocation-closure-candidate
          buffer toast paint-a paint-b)))
    (ebox-candidate-replace-host-ref
     candidate 'status
     (ebox-test-box :key 'status :source-identity 'status
                  (ebox-test-text status) :width '(200)))
    candidate))




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


(ert-deftest ebox-commit-allocation-closure-proof-misses-fallback ()
  "Topology, selector, cascade, and role misses reject allocation closure."
  (dolist (kind '(topology selector cascade))
    (ebox-style-reset-rules)
    (when (eq kind 'selector)
      (ebox-style-add-rule "box:has(.changed)" '(:color "#EF4444")))
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
                 (ebox-test-box
                  :key 'toast :source-identity 'toast
                  (ebox-test-column
                   (ebox-test-box :key 'nested-toast
                                (ebox-test-text "A longer notification"))))
               (ebox-test-box :key 'toast :source-identity 'toast
                            :class (and (eq kind 'selector) "changed")
                            (ebox-test-text "A longer notification"))))
            (ebox-candidate-replace-host-ref
             candidate 'paint-a
             (ebox-test-box :key 'paint-a :source-identity 'paint-a
                          (ebox-test-text "paint-a") :color "#AAAAAA"))
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
              (ert-info ((format "proof miss kind: %S" kind))
                (should-not (eq (plist-get report :projection-kind)
                                'mixed-owner-reflow)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (ebox-style-reset-rules))))
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

(ert-deftest ebox-native-inherited-dirty-domain-is-schema-owned ()
  "Native invalidation derives inherited propagation from the style schema."
  (should
   (equal '(7)
          (ebox-native-commit-inherited-dirty-node-ids
           '(:dirty-set
             ((:node-id 7 :dirty-kind paint :changed-keys (:color)))))))
  (should-not
   (ebox-native-commit-inherited-dirty-node-ids
    '(:dirty-set
      ((:node-id 7 :dirty-kind paint
                  :changed-keys (:background-color)))))))

(ert-deftest ebox-native-retained-compiler-refreshes-inherited-descendants ()
  "An inherited parent paint change cannot reuse a stale child fragment."
  (require 'ebox-native-reflow)
  (let* ((input
          (ebox-test-box
           :color "#111111"
           (ebox-test-text "Paint" :color "#111111")))
         (root (ebox-test-root input))
         (_ids (ebox--runtime-node-ids root))
         (source-index (ebox-test-source-index input))
         (session
          (ebox-native-reflow--make-session
           :handle 'test :generation 0 :styles nil :layout-package nil
           :layout-fragment-cache (make-hash-table :test 'equal)
           :layout-fragment-revision 0))
         (initial-state
          (list :native-node-postorder
                (ebox-native-reflow--retained-layout-postorder root)
                :native-topology-stable-p nil
                :source-index source-index))
         (initial-package
          (ebox-native-reflow--compile-retained-layout-package
           session initial-state root))
         (next (copy-tree root))
         (next-child (car (ebox-tree-node-children next))))
    (let ((bootstrap-root
           (plist-get (plist-get initial-package :document) :root)))
      (should (= (plist-get root :node-id)
                 (plist-get bootstrap-root :node-id)))
      (should (integerp (plist-get bootstrap-root :node-revision)))
      ;; The Text is fused into its owner and therefore has no addressable
      ;; child entry in the full wire document.
      (should (eq :null (plist-get bootstrap-root :child))))
    (setf (ebox-native-reflow-session-styles session)
          (plist-get initial-package :styles)
          (ebox-native-reflow-session-layout-package session)
          initial-package)
    ;; Model a candidate computed-style projection: the child source record is
    ;; unchanged, while its inherited runtime color follows the parent.
    (plist-put next :color "#222222")
    (plist-put next-child :color "#222222")
    (let* ((root-id (plist-get next :node-id))
           (next-state
            (list :native-node-postorder
                  (ebox-native-reflow--retained-layout-postorder next)
                  :native-topology-stable-p t
                  :native-touched-node-ids (list root-id)
                  :native-inherited-dirty-node-ids (list root-id)
                  :source-index source-index))
           (package
            (ebox-native-reflow--compile-retained-layout-package
             session next-state next))
           (document-root (plist-get (plist-get package :document) :root))
           (style-id (plist-get document-root :content-foreground-style))
           (styles (plist-get package :styles)))
      (should (integerp style-id))
      (should
       (equal '(:foreground "#222222")
              (plist-get (aref styles style-id) :face))))))

(ert-deftest ebox-native-retained-package-reuse-requires-exact-ir-identity ()
  "Only an identity-preserving compile may reuse the confirmed package."
  (let* ((root (list :type "row" :children []))
         (style (list :mode 'face :face '(:foreground "red")))
         (template (list :mouse-face 'highlight))
         (old
          (list :document
                (list :version 2 :space-width 8 :style-count 1
                      :property-template-count 1
                      :styles (vector style) :root root)
                :document-revision 7
                :styles (vector style)
                :property-templates (vector template)))
         (same
          (list :document
                (list :version 2 :space-width 8 :style-count 1
                      :property-template-count 1
                      :styles (vector style) :root root)
                :styles (vector style)
                :property-templates (vector template))))
    (should (eq old
                (ebox-native-reflow--reuse-exact-layout-package old same)))
    (dolist (candidate
             (list
              (copy-tree same)
              (let ((copy (copy-tree same)))
                (plist-put (plist-get copy :document) :space-width 9)
                copy)
              (let ((copy (copy-tree same)))
                (plist-put (plist-get copy :document) :root (copy-tree root))
                copy)
              (let ((copy (copy-tree same)))
                (plist-put copy :styles
                           (vector (copy-tree style)))
                copy)
              (let ((copy (copy-tree same)))
                (plist-put copy :property-templates
                           (vector (copy-tree template)))
                copy)))
      ;; COPY-TREE deliberately destroys the required root/style/template
      ;; object identity even when values remain equal.
      (should-not
       (eq old (ebox-native-reflow--reuse-exact-layout-package old candidate))))))

(ert-deftest ebox-native-retained-sync-omits-an-exactly-reused-document ()
  "A retained frame sends only revisions and context for unchanged IR."
  (let* ((document (list :version 2 :space-width 8 :style-count 0
                         :property-template-count 0 :styles []
                         :root (list :type "row" :children [])))
         (package (list :document document :document-revision 4
                        :styles [] :property-templates []))
         (session
          (ebox-native-reflow--make-session
           :handle 'test :generation 3 :styles [] :layout-package package
           :layout-fragment-cache (make-hash-table :test 'equal)
           :layout-fragment-revision 0))
         control)
    (cl-letf (((symbol-function
                'ebox-native-reflow--compile-retained-layout-package)
               (lambda (&rest _) package))
              ((symbol-function 'ebox-native--module-render-session-frame)
               (lambda (_handle _generation payload)
                 (setq control
                       (json-parse-string payload :object-type 'plist
                                          :array-type 'array))
                 'native-frame))
              ((symbol-function 'ebox-native-reflow--materialize-module-frame)
               (lambda (&rest _) '(:rendered "ok"))))
      (should
       (equal
        '(:rendered "ok")
        (ebox-native-reflow-execute-session-sync
         session 'node
         '(:key 1 :viewport-width 80 :viewport-height 10
           :runtime-revision 9)
         nil 'state)))
      (should-not (plist-member control :document))
      (should (= (plist-get control :document-base-revision) 4))
      (should (= (plist-get control :document-target-revision) 4)))))

(ert-deftest ebox-native-session-input-normalizes-every-replacement-revision ()
  "Compiled and explicit replacement packages both advance at the boundary."
  (let* ((styles [])
         (templates [])
         (old
          (list :document
                (list :version 2 :space-width 8 :style-count 0
                      :property-template-count 0 :styles []
                      :root (list :type "row" :children []))
                :document-revision 4
                :styles styles :property-templates templates))
         (compiled
          (list :document
                (list :version 2 :space-width 8 :style-count 0
                      :property-template-count 0 :styles []
                      :root (list :type "column" :children []))
                :document-revision 1
                :styles styles :property-templates templates))
         (explicit
          (list :document
                (list :version 2 :space-width 8 :style-count 0
                      :property-template-count 0 :styles []
                      :root (list :type "box"))
                :document-revision 1
                :styles styles :property-templates templates))
         (session
          (ebox-native-reflow--make-session
           :handle 'test :generation 0 :styles styles :layout-package old
           :layout-fragment-cache (make-hash-table :test 'equal)
           :layout-fragment-revision 0))
         (other-old (copy-tree old))
         (other-session
          (progn
            (plist-put other-old :document-revision 10)
            (ebox-native-reflow--make-session
             :handle 'other :generation 0 :styles styles
             :layout-package other-old
             :layout-fragment-cache (make-hash-table :test 'equal)
             :layout-fragment-revision 0)))
         controls)
    (cl-letf (((symbol-function 'ebox-native-reflow--compile-layout-package)
               (lambda (&rest _) compiled))
              ((symbol-function 'ebox-native--module-render-session-frame)
               (lambda (_handle _generation payload)
                 (push (json-parse-string payload :object-type 'plist
                                          :array-type 'array)
                       controls)
                 'native-frame))
              ((symbol-function 'ebox-native-reflow--materialize-module-frame)
               (lambda (&rest _) '(:rendered "ok"))))
      (ebox-native-reflow-execute-session-sync
       session 'node
       '(:key 1 :viewport-width 80 :viewport-height 10
         :runtime-revision 9))
      (should (= (plist-get (ebox-native-reflow-session-layout-package session)
                            :document-revision)
                 5))
      (ebox-native-reflow-execute-session-sync
       session 'node
       '(:key 1 :viewport-width 90 :viewport-height 10
         :runtime-revision 10)
       explicit)
      (setq controls (nreverse controls))
      (should (plist-member (car controls) :document))
      (should (= (plist-get (car controls) :document-base-revision) 4))
      (should (= (plist-get (car controls) :document-target-revision) 5))
      (should (plist-member (cadr controls) :document))
      (should (= (plist-get (cadr controls) :document-base-revision) 5))
      (should (= (plist-get (cadr controls) :document-target-revision) 6))
      (should (= (plist-get (ebox-native-reflow-session-layout-package session)
                            :document-revision)
                 6))
      (ebox-native-reflow-execute-session-sync
       other-session 'node
       '(:key 1 :viewport-width 100 :viewport-height 10
         :runtime-revision 20)
       explicit)
      (should (= (plist-get explicit :document-revision) 1))
      (should (= (plist-get (ebox-native-reflow-session-layout-package session)
                            :document-revision)
                 6))
      (should (= (plist-get
                  (ebox-native-reflow-session-layout-package other-session)
                  :document-revision)
                 11))
      (should (= (plist-get (car controls) :document-base-revision) 10))
      (should (= (plist-get (car controls) :document-target-revision) 11)))))

(ert-deftest ebox-native-persistent-index-path-copies-without-changing-base ()
  "A retained index update shares the base and leaves its values immutable."
  (require 'ebox-native-reflow)
  (let* ((base (ebox-native-reflow--persistent-index-put nil 1 'one))
         (next (ebox-native-reflow--persistent-index-put base 17 'seventeen)))
    (should (eq 'one (ebox-native-reflow--persistent-index-get base 1)))
    (should-not (ebox-native-reflow--persistent-index-get base 17))
    (should (eq 'one (ebox-native-reflow--persistent-index-get next 1)))
    (should (eq 'seventeen
                (ebox-native-reflow--persistent-index-get next 17)))
    (should-not (eq base next))))

(ert-deftest ebox-native-session-fork-shares-immutable-compiler-roots ()
  "Forking does not clone the retained fragment map or persistent indexes."
  (require 'ebox-native-reflow)
  (let* ((cache (make-hash-table :test 'equal))
         (index (ebox-native-reflow--persistent-index-put nil 1 'entry))
         (edge-index
          (ebox-native-reflow--persistent-index-put
           nil '(rule . 1) '(:kind direct-axis)))
         (styles (vector 'style))
         (session
          (ebox-native-reflow--make-session
           :handle 'parent :generation 4 :styles styles
           :layout-package 'package :layout-fragment-cache cache
           :layout-fragment-index index :layout-fragment-revision 8
           :layout-style-index index :layout-property-template-index index
           :layout-edge-index edge-index)))
    (cl-letf (((symbol-function 'ebox-native--module-fork-confirmed)
               (lambda (_handle) 'child)))
      (let ((fork (ebox-native-reflow-fork-session session)))
        (should (eq cache
                    (ebox-native-reflow-session-layout-fragment-cache fork)))
        (should (eq index
                    (ebox-native-reflow-session-layout-fragment-index fork)))
        (should (eq edge-index
                    (ebox-native-reflow-session-layout-edge-index fork)))
        (should (eq styles (ebox-native-reflow-session-styles fork)))
        (should (= 8
                   (ebox-native-reflow-session-layout-fragment-revision
                    fork)))))))

(ert-deftest ebox-native-failed-delta-keeps-fork-and-parent-indexes-unchanged ()
  "A rejected candidate cannot publish its path-copied compiler index."
  (require 'ebox-native-reflow)
  (let* ((cache (make-hash-table :test 'equal))
         (base-index (ebox-native-reflow--persistent-index-put nil 1 'old))
         (next-index
          (ebox-native-reflow--persistent-index-put base-index 1 'new))
         (edge-index
          (ebox-native-reflow--persistent-index-put
           nil '(child . 1) '(:parent-id 9)))
         (old (list :document '(:version 2) :document-revision 4
                    :styles [] :property-templates []))
         (next (copy-sequence old))
         (parent
         (ebox-native-reflow--make-session
           :handle 'parent :layout-package old :styles []
           :layout-fragment-cache cache :layout-fragment-index base-index
           :layout-edge-index edge-index)))
    (plist-put next :document-revision 5)
    (plist-put next :document-delta
               '(:style-base-count 0 :styles-append []
                 :property-template-base-count 0
                 :property-template-target-count 0 :entries []))
    (plist-put next :native-fragment-index next-index)
    (cl-letf (((symbol-function 'ebox-native--module-fork-confirmed)
               (lambda (_handle) 'child)))
      (let ((fork (ebox-native-reflow-fork-session parent)))
        (cl-letf (((symbol-function
                    'ebox-native-reflow--compile-retained-layout-package)
                   (lambda (&rest _) next))
                  ((symbol-function 'ebox-native--module-render-session-frame)
                   (lambda (&rest _) (error "reject delta"))))
          (should-error
           (ebox-native-reflow-execute-session-sync
            fork 'node '(:key 1 :viewport-width 80 :viewport-height 10)
            nil 'state))
          (should (eq base-index
                      (ebox-native-reflow-session-layout-fragment-index fork)))
          (should (eq base-index
                      (ebox-native-reflow-session-layout-fragment-index parent)))
          (should (eq edge-index
                      (ebox-native-reflow-session-layout-edge-index fork)))
          (should (eq edge-index
                      (ebox-native-reflow-session-layout-edge-index parent)))
          (should (eq cache
                      (ebox-native-reflow-session-layout-fragment-cache fork))))))))

(ert-deftest ebox-native-accepted-delta-invalidates-stale-full-cache ()
  "A later full fallback cannot resurrect pre-delta legacy fragments."
  (require 'ebox-native-reflow)
  (let* ((cache (make-hash-table :test 'equal))
         (base-index (ebox-native-reflow--persistent-index-put nil 1 'old))
         (next-index
          (ebox-native-reflow--persistent-index-put base-index 1 'new))
         (old (list :document '(:version 2) :document-revision 4
                    :styles [] :property-templates []))
         (next (copy-sequence old))
         (session
          (ebox-native-reflow--make-session
           :handle 'test :generation 0 :layout-package old :styles []
           :layout-fragment-cache cache :layout-fragment-index base-index)))
    (puthash 1 'stale-fragment cache)
    (plist-put next :document-revision 5)
    (plist-put next :document-delta
               '(:style-base-count 0 :styles-append []
                 :property-template-base-count 0
                 :property-template-target-count 0 :entries []))
    (plist-put next :native-fragment-index next-index)
    (plist-put next :native-fragment-revision 9)
    (cl-letf (((symbol-function
                'ebox-native-reflow--compile-retained-layout-package)
               (lambda (&rest _) next))
              ((symbol-function 'ebox-native--module-render-session-frame)
               (lambda (&rest _) 'native-frame))
              ((symbol-function 'ebox-native-reflow--materialize-module-frame)
               (lambda (&rest _) '(:rendered "ok"))))
      (ebox-native-reflow-execute-session-sync
       session 'node '(:key 1 :viewport-width 80 :viewport-height 10)
       nil 'state)
      (should-not
       (ebox-native-reflow-session-layout-fragment-cache session))
      (should (eq next-index
                  (ebox-native-reflow-session-layout-fragment-index session)))
      (should (= 9
                 (ebox-native-reflow-session-layout-fragment-revision
                  session)))
      ;; Model the next unsupported B update.  The current source contains A's
      ;; accepted value while the persistent index is deliberately stale; the
      ;; invalidated legacy cache forces a complete compile from current state.
      (let* ((input
              (ebox-test-box (ebox-test-text "A") :bgcolor "#00ff00"))
             (root (ebox-test-root input))
             (_ids (ebox--runtime-node-ids root))
             (full
              (ebox-native-reflow--compile-retained-layout-package-full
               session
               (list :native-node-postorder
                     (ebox-native-reflow--retained-layout-postorder root)
                     :native-topology-stable-p nil
                     :source-index (ebox-test-source-index input))
               root))
             (document-root (plist-get (plist-get full :document) :root))
             (style-id (plist-get document-root :background-style)))
        (should
         (equal '(:background "#00ff00")
                (plist-get (aref (plist-get full :styles) style-id)
                           :face)))))))

(ert-deftest ebox-native-node-delta-is-local-and-bumps-ancestors ()
  "A local change patches one owner and only revises its retained ancestor."
  (require 'ebox-native-reflow)
  (let* ((leaf-fragment
          '(:type "box" :background-style :null :child :null
            :node-id 2 :node-revision 3))
         (root-fragment
          (list :type "box" :background-style :null :child leaf-fragment
                :node-id 1 :node-revision 4))
         (leaf-entry (list :fragment leaf-fragment :revision 3))
         (root-entry (list :fragment root-fragment :revision 4))
         (index (ebox-native-reflow--persistent-index-put nil 1 root-entry))
         (_index (setq index
                       (ebox-native-reflow--persistent-index-put
                        index 2 leaf-entry)))
         (style-index
          (ebox-native-reflow--persistent-index-put
           nil '(:mode add :face (:background "red")) 0))
         (package
          (list :document '(:version 2) :document-revision 7
                :styles [] :property-templates []))
         (session
          (ebox-native-reflow--make-session
           :handle 'test :generation 0 :styles [] :layout-package package
           :layout-fragment-index index :layout-fragment-revision 4
           :layout-style-index style-index))
         (nodes (make-hash-table :test 'equal))
         (parents (make-hash-table :test 'equal))
         (state
          (list :node-table nodes :parent-table parents
                :native-topology-stable-p t
                :native-touched-node-ids '(2 1)
                :native-local-dirty-entries
                '((:node-id 2 :dirty-kind paint
                            :changed-keys (:background-color))))))
    (puthash 1 '(:node-id 1) nodes)
    (puthash 2 '(:node-id 2) nodes)
    (puthash 2 1 parents)
    (cl-letf (((symbol-function 'ebox--current-display-signature)
               (lambda () 'display))
              ((symbol-function 'ebox-native-reflow--compile-delta-slots)
               (lambda (_node _old)
                 (vector
                  '(:type "box" :background-style 0 :child :null)))))
      (let* ((next
              (ebox-native-reflow--compile-retained-layout-delta
               session state 'root))
             (delta (plist-get next :document-delta))
             (entries (plist-get delta :entries))
             (leaf (aref entries 0))
             (root (aref entries 1)))
        (should (= 8 (plist-get next :document-revision)))
        (should (= 0 (plist-get delta :style-base-count)))
        (should (= 2 (length entries)))
        (should (equal [(:slot 0 :local (:background-style 0))]
                       (plist-get leaf :slot-patches)))
        (should-not (plist-member root :slot-patches))
        (should (= 5 (plist-get leaf :target-revision)))
        (should (= 6 (plist-get root :target-revision)))))))

(ert-deftest ebox-native-node-delta-deduplicates-multiple-leaf-closures ()
  "Multiple changed leaves produce one entry each and one shared ancestor."
  (require 'ebox-native-reflow)
  (let ((index nil)
        (nodes (make-hash-table :test 'equal))
        (parents (make-hash-table :test 'equal)))
    (dolist (pair '((1 . 3) (2 . 1) (3 . 2)))
      (setq index
            (ebox-native-reflow--persistent-index-put
             index (car pair)
             (list :fragment
                   '(:type "box" :background-style :null :child :null)
                   :revision (cdr pair))))
      (puthash (car pair) (list :node-id (car pair)) nodes))
    (puthash 2 1 parents)
    (puthash 3 1 parents)
    (let* ((package (list :document '(:version 2) :document-revision 2
                          :styles [] :property-templates []))
           (session
            (ebox-native-reflow--make-session
             :handle 'test :layout-package package
             :layout-fragment-index index :layout-fragment-revision 3))
           (state
            (list :node-table nodes :parent-table parents
                  :native-topology-stable-p t
                  :native-touched-node-ids '(2 1 3 1)
                  :native-local-dirty-entries
                  '((:node-id 2 :changed-keys (:background-color))
                    (:node-id 3 :changed-keys (:background-color))))))
      (cl-letf (((symbol-function 'ebox--current-display-signature)
                 (lambda () 'display))
                ((symbol-function 'ebox-native-reflow--compile-delta-slots)
                 (lambda (node _old)
                   (vector
                    (list :type "box" :background-style
                          (plist-get node :node-id) :child :null)))))
        (let* ((next
                (ebox-native-reflow--compile-retained-layout-delta
                 session state 'root))
               (entries
                (plist-get (plist-get next :document-delta) :entries)))
          (should (= 3 (length entries)))
          (should (equal '(2 1 3)
                         (mapcar (lambda (entry)
                                   (plist-get entry :node-id))
                                 (append entries nil))))
          (should (plist-member (aref entries 0) :slot-patches))
          (should-not (plist-member (aref entries 1) :slot-patches))
          (should (plist-member (aref entries 2) :slot-patches)))))))

(ert-deftest ebox-native-fused-text-delta-resolves-to-box-owner ()
  "A fused text id addresses its containing Box rather than a hidden node."
  (require 'ebox-native-reflow)
  (let ((nodes (make-hash-table :test 'equal))
        (parents (make-hash-table :test 'equal))
        (index (ebox-native-reflow--persistent-index-put nil 10 'owner)))
    (puthash 10
             (list :node-id 10 :ebox-kind 'box
                   :ebox-layout-config
                   (ebox-normal-layout-create))
             nodes)
    (puthash 11 '(:node-id 11 :ebox-kind text) nodes)
    (puthash 11 10 parents)
    (should (= 10
               (ebox-native-reflow--delta-owner-id
                (list :node-table nodes :parent-table parents) 11 index)))))

(ert-deftest ebox-native-flex-item-metadata-change-uses-full-input ()
  "N1 does not misrepresent Flex item metadata as a local scalar patch."
  (require 'ebox-native-reflow)
  (let ((session
         (ebox-native-reflow--make-session
          :handle 'test :layout-package 'old
          :layout-fragment-index
          (ebox-native-reflow--persistent-index-put
           nil 1 '(:fragment (:type "box" :child :null) :revision 1))))
        (state
         '(:native-topology-stable-p t :native-touched-node-ids (1)
           :native-local-dirty-entries
           ((:node-id 1 :dirty-kind geometry
                      :changed-keys (:flex-grow)))))
        full-called)
    (cl-letf (((symbol-function
                'ebox-native-reflow--compile-retained-layout-package-full)
               (lambda (&rest _)
                 (setq full-called t)
                 'full))
              ((symbol-function 'ebox-native-reflow--compile-delta-slots)
               (lambda (&rest _)
                 (ert-fail "Flex item metadata reached local delta"))))
      (should (eq 'full
                  (ebox-native-reflow--compile-retained-layout-package
                   session state 'node)))
      (should full-called))))

(ert-deftest ebox-native-flex-child-content-change-uses-full-input ()
  "Child content may alter retained Flex edge measurement in N1."
  (require 'ebox-native-reflow)
  (let ((nodes (make-hash-table :test 'equal))
        (parents (make-hash-table :test 'equal))
        (index
         (ebox-native-reflow--persistent-index-put
          nil 2 '(:fragment (:type "box" :content [] :child :null)
                  :revision 3)))
        full-called)
    (puthash 1 '(:node-id 1 :ebox-type flex) nodes)
    (puthash 2
             (list :node-id 2 :ebox-type 'box :ebox-kind 'box
                   :ebox-layout-config (ebox-normal-layout-create))
             nodes)
    (puthash 3 '(:node-id 3 :ebox-type box :ebox-kind text) nodes)
    (puthash 2 1 parents)
    (puthash 3 2 parents)
    (let ((session
           (ebox-native-reflow--make-session
            :handle 'test :layout-package 'old
            :layout-fragment-index index))
          (state
           (list :node-table nodes :parent-table parents
                 :native-topology-stable-p t
                 :native-touched-node-ids '(3 2 1)
                 :native-local-dirty-entries
                 '((:node-id 3 :dirty-kind content
                             :changed-keys (:content))))))
      (cl-letf (((symbol-function
                  'ebox-native-reflow--compile-retained-layout-package-full)
                 (lambda (&rest _)
                   (setq full-called t)
                   'full))
                ((symbol-function 'ebox-native-reflow--compile-delta-slots)
                 (lambda (&rest _)
                   (ert-fail "Flex child content reached local delta"))))
        (should (eq 'full
                    (ebox-native-reflow--compile-retained-layout-package
                     session state 'node)))
        (should full-called)))))

(ert-deftest ebox-native-default-axis-child-change-keeps-local-input ()
  "Default Row/Column edges carry no derived Flex item metadata."
  (require 'ebox-native-reflow)
  (let ((nodes (make-hash-table :test 'equal))
        (parents (make-hash-table :test 'equal))
        (index (ebox-native-reflow--persistent-index-put nil 2 'owner)))
    (puthash 1
             (list :node-id 1 :ebox-type 'box :ebox-kind 'box
                   :ebox-layout-config (ebox-column-layout-create))
             nodes)
    (puthash 2
             (list :node-id 2 :ebox-type 'box :ebox-kind 'box
                   :ebox-layout-config (ebox-normal-layout-create))
             nodes)
    (puthash 3 '(:node-id 3 :ebox-type box :ebox-kind text) nodes)
    (puthash 2 1 parents)
    (puthash 3 2 parents)
    (should-not
     (ebox-native-reflow--delta-edge-change-p
      (ebox-native-reflow--make-session
       :layout-edge-index
       (ebox-native-reflow--persistent-index-put
        nil '(rule . 1)
        '(:parent-id 1 :slot 1 :kind direct-axis :axis column)))
      (list :node-table nodes :parent-table parents
            :native-local-dirty-entries
            '((:node-id 3 :dirty-kind geometry
                        :changed-keys (:content))))
      index))))

(ert-deftest ebox-native-flex-fused-paint-proves-retained-edge-unchanged ()
  "A fused paint edit under Flex uses its exact retained item fact."
  (require 'ebox-native-reflow)
  (let* ((text '(:node-id 3 :ebox-type box :ebox-kind text))
         (owner
          (list :node-id 2 :ebox-type 'box :ebox-kind 'box
                :ebox-layout-config (ebox-normal-layout-create)
                :children (list text)))
         (parent
          (list :node-id 1 :ebox-type 'box :ebox-kind 'box
                :ebox-layout-config (ebox-flex-layout-create)
                :children (list owner)))
         (item (ebox-native-reflow--compile-flex-item
                owner 'row '(:type "box") t 17 t))
         (fragment
          (list :type "box"
                :child (list :type "flex" :items (vector item))))
         (cache (make-hash-table :test 'equal))
         (nodes (make-hash-table :test 'equal))
         (parents (make-hash-table :test 'equal))
         (widths (make-hash-table :test 'eq))
         (owner-fragment
          '(:type "box" :background-style :null :child :null
            :node-id 2 :node-revision 1))
         (index
          (ebox-native-reflow--persistent-index-put
           nil 2 (list :fragment owner-fragment :revision 1)))
         (_index
          (setq index
                (ebox-native-reflow--persistent-index-put
                 index 1 (list :fragment fragment :revision 2)))))
    (puthash 1 (list :fragment fragment :revision 1) cache)
    (puthash 1 parent nodes)
    (puthash 2 owner nodes)
    (puthash 3 text nodes)
    (puthash 2 1 parents)
    (puthash 3 2 parents)
    (puthash owner 17 widths)
    (let* ((session
           (ebox-native-reflow--make-session
            :layout-package
            '(:document (:version 2) :document-revision 1
              :styles [] :property-templates [])
            :layout-fragment-index index :layout-fragment-revision 2
            :layout-edge-index
            (ebox-native-reflow--retained-edge-index
             (vector owner parent) cache)))
           (state
            (list :node-table nodes :parent-table parents
                  :flex-content-min-widths widths
                  :native-topology-stable-p t
                  :native-touched-node-ids '(3 2 1)
                  :native-local-dirty-entries
                  '((:node-id 3 :dirty-kind paint
                              :changed-keys (:background-color))))))
      (cl-letf (((symbol-function 'ebox-tree-node-children)
                 (lambda (&rest _)
                   (ert-fail "delta edge proof enumerated siblings")))
                ((symbol-function 'ebox--current-display-signature)
                 (lambda () 'display))
                ((symbol-function 'ebox-native-reflow--compile-delta-slots)
                 (lambda (_node _old)
                   (vector
                    '(:type "box" :background-style 0 :child :null)))))
        (should-not
         (ebox-native-reflow--delta-edge-change-p
          session state index))
        (let ((package
               (ebox-native-reflow--compile-retained-layout-delta
                session state parent)))
          (should (plist-get package :document-delta))
          (should (= 2 (length
                        (plist-get (plist-get package :document-delta)
                                   :entries)))))))))

(ert-deftest ebox-native-flex-measurement-change-keeps-full-fallback ()
  "A changed exact Flex measurement still requires the future edge protocol."
  (require 'ebox-native-reflow)
  (let* ((owner
         (list :node-id 2 :ebox-type 'box :ebox-kind 'box
                :ebox-layout-config (ebox-normal-layout-create)
                :wrap-mode 'word))
         (parent
          (list :node-id 1 :ebox-type 'box :ebox-kind 'box
                :ebox-layout-config (ebox-flex-layout-create)
                :children (list owner)))
         (item (ebox-native-reflow--compile-flex-item
                owner 'row '(:type "box") t 17 t))
         (fragment
          (list :type "box"
                :child (list :type "flex" :items (vector item))))
         (cache (make-hash-table :test 'equal))
         (nodes (make-hash-table :test 'equal))
         (parents (make-hash-table :test 'equal))
         (widths (make-hash-table :test 'eq))
         (index (ebox-native-reflow--persistent-index-put nil 2 'owner)))
    (puthash 1 (list :fragment fragment :revision 1) cache)
    (puthash 1 parent nodes)
    (puthash 2 owner nodes)
    (puthash 2 1 parents)
    (puthash owner 23 widths)
    (should
     (ebox-native-reflow--delta-edge-change-p
      (ebox-native-reflow--make-session
       :layout-edge-index
       (ebox-native-reflow--retained-edge-index
        (vector owner parent) cache))
      (list :node-table nodes :parent-table parents
            :flex-content-min-widths widths
            :native-local-dirty-entries
            '((:node-id 2 :dirty-kind content :changed-keys (:content))))
      index))))

(ert-deftest ebox-native-nondefault-axis-fused-edit-uses-exact-edge-fact ()
  "A fused edit under nondefault Row reuses an unchanged align-self fact."
  (require 'ebox-native-reflow)
  (let* ((text '(:node-id 3 :ebox-type box :ebox-kind text))
         (owner
          (list :node-id 2 :ebox-type 'box :ebox-kind 'box
                :ebox-layout-config (ebox-normal-layout-create)
                :children (list text)))
         (parent
          (list :node-id 1 :ebox-type 'box :ebox-kind 'box
                :ebox-layout-config
                (ebox-row-layout-create :item-gap 2 :cross-align 'stretch)
                :children (list owner)))
         (item
          (list :node '(:type "box") :order 0 :grow 0 :shrink 0
                :basis '(:kind "auto") :align-self "stretch"))
         (fragment
          (list :type "box"
                :child (list :type "flex" :items (vector item))))
         (cache (make-hash-table :test 'equal))
         (nodes (make-hash-table :test 'equal))
         (parents (make-hash-table :test 'equal))
         (index (ebox-native-reflow--persistent-index-put nil 2 'owner)))
    (puthash 1 (list :fragment fragment :revision 1) cache)
    (puthash 1 parent nodes)
    (puthash 2 owner nodes)
    (puthash 3 text nodes)
    (puthash 2 1 parents)
    (puthash 3 2 parents)
    (should-not
     (ebox-native-reflow--delta-edge-change-p
      (ebox-native-reflow--make-session
       :layout-edge-index
       (ebox-native-reflow--retained-edge-index
        (vector owner parent) cache))
      (list :node-table nodes :parent-table parents
            :native-local-dirty-entries
            '((:node-id 3 :dirty-kind content :changed-keys (:content))))
      index))))

(ert-deftest ebox-native-surface-overrides-carry-local-dirty-entries ()
  "The incremental producer preserves exact local dirtiness to native input."
  (let* ((dirty '((:node-id 7 :dirty-kind paint
                            :changed-keys (:background-color))))
         (candidate (list :runtime-revision 3
                          :native-topology-stable-p t
                          :native-touched-node-ids '(7 1)
                          :native-local-dirty-entries dirty))
         (overrides
          (ebox-incremental--surface-state-overrides
           nil '(:display-signature display) candidate 'native-frame)))
    (should (equal dirty
                   (plist-get overrides :native-local-dirty-entries)))))

(ert-deftest ebox-native-wide-owner-local-compile-does-not-enumerate-children ()
  "A scalar slot update never walks a stable owner's unchanged children."
  (require 'ebox-native-reflow)
  (let ((node (list :ebox-type 'box :ebox-kind 'box
                    :ebox-layout-config (ebox-flex-layout-create)))
        (old '(:type "box" :child (:type "flex" :items [a b c]))))
    (cl-letf (((symbol-function 'ebox-tree-node-children)
               (lambda (&rest _)
                 (ert-fail "stable delta enumerated unchanged children")))
              ((symbol-function 'ebox-native-reflow--compile-flex-inner)
               (lambda (_props items &rest _)
                 (should-not items)
                 '(:type "flex" :items [])))
              ((symbol-function 'ebox-native-reflow--compile-box)
               (lambda (_box child &rest _)
                 (list :type "box" :child child))))
      (let ((slots (ebox-native-reflow--compile-delta-slots node old)))
        (should (= 2 (length slots)))
        (should (equal [] (plist-get (aref slots 1) :items)))))))

(ert-deftest ebox-native-retained-sync-sends-document-delta-without-document ()
  "A supported retained compile sends only its node delta and revisions."
  (require 'ebox-native-reflow)
  (let* ((old (list :document '(:version 2) :document-revision 4
                    :styles [] :property-templates []))
         (delta '(:style-base-count 0 :styles-append []
                  :property-template-base-count 0
                  :property-template-target-count 0 :entries []))
         (next (copy-sequence old))
         (session
          (ebox-native-reflow--make-session
           :handle 'test :generation 0 :styles [] :layout-package old))
         control)
    (plist-put next :document-revision 5)
    (plist-put next :document-delta delta)
    (cl-letf (((symbol-function
                'ebox-native-reflow--compile-retained-layout-package)
               (lambda (&rest _) next))
              ((symbol-function 'ebox-native--module-render-session-frame)
               (lambda (_handle _generation payload)
                 (setq control
                       (json-parse-string payload :object-type 'plist
                                          :array-type 'array))
                 'native-frame))
              ((symbol-function 'ebox-native-reflow--materialize-module-frame)
               (lambda (&rest _) '(:rendered "ok"))))
      (ebox-native-reflow-execute-session-sync
       session 'node
       '(:key 1 :viewport-width 80 :viewport-height 10) nil 'state)
      (should-not (plist-member control :document))
      (should (equal delta (plist-get control :document-delta)))
      (should (= 4 (plist-get control :document-base-revision)))
      (should (= 5 (plist-get control :document-target-revision)))
      (should-not
       (plist-member
        (ebox-native-reflow-session-layout-package session)
        :document-delta)))))

(provide 'ebox-commit-tests)

;;; ebox-commit-tests.el ends here
