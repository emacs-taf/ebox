;;; ebox-child-range-tests.el --- Persistent child sequence tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'ebox-child-range)
(require 'ebox)

;; This suite locks child-range and Elisp projection semantics.  Native frame
;; execution is verified separately and must not replace the named fallback
;; strategies merely because a developer has built the optional module.
(setq ebox-native-reflow-module-path nil)

(defconst ebox-child-range-test--root
  (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name)))
  "Ebox repository root for source audits.")

(defun ebox-child-range-test--item (key)
  "Return one declarative test item for KEY."
  (list :key key :value key))

(defun ebox-child-range-test--fixture (static-count range-items &optional hash)
  "Build STATIC-COUNT static segments followed by RANGE-ITEMS."
  (ebox-child-range--build
   (append
    (cl-loop for index below static-count
             collect (cons nil (list (ebox-child-range-test--item
                                      (list 'static index)))))
    (list (cons 'range
                (mapcar #'ebox-child-range-test--item range-items))))
   hash))

(ert-deftest ebox-child-range-reuse-map-rebinds-published-objects ()
  "Stable slots use published objects; moved slots re-enter normal indexing."
  (let* ((sequence (ebox-child-range-test--fixture 0 '(one two)))
         (segment (ebox-child-range--lookup-ref sequence 'range))
         (payload (ebox-child-range--segment-payload segment))
         (first (aref payload 0))
         (second (aref payload 1)))
    (plist-put first :node-id 1)
    (plist-put second :node-id 2)
    (plist-put first :ebox-sequence-location
               '(:parent-node-id 99 :segment-index 0 :offset 0))
    (plist-put second :ebox-sequence-location
               '(:parent-node-id 99 :segment-index 0 :offset 1))
    (pcase-let
        ((`(,items ,reuse-map)
          (ebox-incremental--candidate-canonical-range-reuse
           sequence 'range (list (copy-tree first) (copy-tree second))
           '((0 . 0) (1 . 1)) 99 0)))
      (should (eq (nth 0 items) first))
      (should (eq (nth 1 items) second))
      (should (equal reuse-map '((0 . 0) (1 . 1)))))
    (pcase-let
        ((`(,items ,reuse-map)
          (ebox-incremental--candidate-canonical-range-reuse
           sequence 'range (list second first)
           '((0 . 1) (1 . 0)) 99 0)))
      (should-not (eq (nth 0 items) second))
      (should-not (eq (nth 1 items) first))
      (should-not (plist-get (nth 0 items) :node-id))
      (should-not (plist-get (nth 1 items) :node-id))
      (should-not reuse-map))
    (should-error
     (ebox-incremental--candidate-canonical-range-reuse
      sequence 'range (list (copy-tree first)) '((1 . 0)) 99 0))))

(ert-deftest ebox-child-range-render-signature-snapshots-item-identities ()
  "A cached Range signature must not follow later runtime identity mutation."
  (let* ((item (ebox-create :content "item" :key 'item))
         (sequence (ebox-child-range--build (list (cons 'range (list item)))))
         (published
          (aref (ebox-child-range--segment-payload
                 (ebox-child-range--lookup-ref sequence 'range))
                0))
         (signature (ebox--render-cache-value-signature sequence)))
    (plist-put published :node-id 1)
    (plist-put published :region-id 10)
    (setq signature (ebox--render-cache-value-signature sequence))
    (plist-put published :region-id 20)
    (should-not
     (equal signature (ebox--render-cache-value-signature sequence)))
    (should (equal 10 (plist-get (cadr signature) :region-id)))))

(ert-deftest ebox-child-range-gate-a-exact-segment-and-payload-costs ()
  "Point replacement cost follows trie height, never parent child count."
  (dolist (case '((0 0 1) (10 1 2) (100 2 3) (500 2 3)))
    (pcase-let* ((`(,static-count ,height ,bound) case)
                 (old (ebox-child-range-test--fixture static-count '(old)))
                 (old-flat (ebox-child-range--flatten old))
                 (result (ebox-child-range--replace
                          old 'range
                          (mapcar #'ebox-child-range-test--item
                                  '(new-a new-b))))
                 (new (car result))
                 (metrics (cdr result)))
      (should (= (ebox-child-range--sequence-count old) (1+ static-count)))
      (should (= (ebox-child-range--sequence-height old) height))
      (should (= (ebox-child-range--segment-node-segment-count
                  (ebox-child-range--sequence-root old))
                 (1+ static-count)))
      (should (= (ebox-child-range--segment-node-weight
                  (ebox-child-range--sequence-root old))
                 (1+ static-count)))
      (should (= (ebox-child-range--prefix-weight old static-count)
                 static-count))
      (should (= (ebox-child-range--rank old static-count) static-count))
      (pcase-let ((`(,nodes . ,edges)
                   (ebox-child-range--segment-memory old)))
        (should (<= nodes (1+ (* (1+ static-count) (1+ height)))))
        (should (= edges (1- nodes))))
      (pcase-let ((`(,vectors . ,slots)
                   (ebox-child-range--segment-vector-memory old)))
        (should (= slots (* vectors 32)))
        (should (<= vectors (1+ (ceiling (/ (float (1+ static-count)) 32))))))
      (should (<= (ebox-child-range--metrics-segment-visits metrics) bound))
      (should (<= (ebox-child-range--metrics-segment-copies metrics) bound))
      (should (= (ebox-child-range--metrics-old-affected-payload-visits metrics)
                 1))
      (should (= (ebox-child-range--metrics-new-payload-visits metrics) 2))
      (should (= (ebox-child-range--metrics-new-payload-validations metrics) 2))
      (should (= (ebox-child-range--metrics-new-payload-copies metrics) 2))
      (should (= (ebox-child-range--segment-node-weight
                  (ebox-child-range--sequence-root new))
                 (+ static-count 2)))
      (should (= (ebox-child-range--rank new static-count) static-count))
      (should (= (ebox-child-range--metrics-ref-index-visits metrics) 1))
      (should (= (ebox-child-range--metrics-ref-index-copies metrics) 0))
      (dolist (accessor
               '(ebox-child-range--metrics-unaffected-payload-visits
                 ebox-child-range--metrics-unaffected-payload-validations
                 ebox-child-range--metrics-unaffected-payload-copies))
        (should (zerop (funcall accessor metrics))))
      (should (equal (ebox-child-range--flatten old) old-flat))
      (should (equal (mapcar (lambda (item) (plist-get item :key))
                             (ebox-child-range--flatten new))
                     (append
                      (cl-loop for index below static-count
                               collect (list 'static index))
                      '(new-a new-b)))))))

(ert-deftest ebox-child-range-gate-a-key-bound-collisions-and-sharing ()
  "Sparse hash work is bounded and unaffected segment branches remain shared."
  (let* ((old (ebox-child-range-test--fixture 100 '(old-a old-b)
                                              (lambda (_key) 0)))
         (result (ebox-child-range--replace
                  old 'range
                  (mapcar #'ebox-child-range-test--item
                          '(new-a new-b new-c))))
         (new (car result))
         (metrics (cdr result))
         (affected 2) (replacement 3)
         (old-key-root (ebox-child-range--sequence-key-root old))
         (old-first (aref (ebox-child-range--segment-node-children
                           (ebox-child-range--sequence-root old)) 0))
         (new-first (aref (ebox-child-range--segment-node-children
                           (ebox-child-range--sequence-root new)) 0)))
    (should (= (ebox-child-range--metrics-key-visits metrics) 35))
    (should (= (ebox-child-range--metrics-key-copies metrics) 35))
    (should (= (ebox-child-range--metrics-collision-visits metrics) 506))
    (should (= (ebox-child-range--metrics-collision-copies metrics) 506))
    (should (= (+ (ebox-child-range--metrics-key-visits metrics)
                  (ebox-child-range--metrics-collision-visits metrics))
               (+ 35 506)))
    (should (= (+ (ebox-child-range--metrics-key-copies metrics)
                  (ebox-child-range--metrics-collision-copies metrics))
               (+ 35 506)))
    (should (<= (+ (ebox-child-range--metrics-key-visits metrics)
                   (ebox-child-range--metrics-collision-visits metrics))
                (+ (* (+ affected replacement) 7) 506)))
    (should (<= (+ (ebox-child-range--metrics-key-copies metrics)
                   (ebox-child-range--metrics-collision-copies metrics))
                (+ (* (+ affected replacement) 7) 506)))
    (should (<= (ebox-child-range--metrics-key-visits metrics)
                (+ (* (+ affected replacement) 7) 506)))
    (should (<= (ebox-child-range--metrics-key-copies metrics)
                (+ (* (+ affected replacement) 7) 506)))
    (should (eq old-first new-first))
    (should (eq (ebox-child-range--sequence-ref-index old)
                (ebox-child-range--sequence-ref-index new)))
    (should (eq (ebox-child-range--sequence-key-root old) old-key-root))
    (should (equal (ebox-child-range--hash-lookup
                    (ebox-child-range--sequence-key-root new) 'new-b 0)
                   '(100 . 1)))
    (should-not (ebox-child-range--hash-lookup
                 (ebox-child-range--sequence-key-root new) 'old-a 0))
    (should (ebox-child-range--hash-lookup old-key-root 'old-a 0))
    (pcase-let ((`(,nodes . ,edges)
                 (ebox-child-range--hash-memory
                  (ebox-child-range--sequence-key-root old))))
      (should (<= nodes (1+ (* 7 102))))
      (should (= edges (1- nodes))))))

(ert-deftest ebox-child-range-gate-a-empty-order-and-duplicates ()
  "Empty ranges stay addressable and global ref/key uniqueness is exact."
  (let* ((empty (ebox-child-range-test--fixture 1 nil))
         (one (car (ebox-child-range--replace
                    empty 'range (list (ebox-child-range-test--item 'one)))))
         (many (car (ebox-child-range--replace
                     one 'range
                     (mapcar #'ebox-child-range-test--item '(two three)))))
         (empty-again (car (ebox-child-range--replace many 'range nil))))
    (should (= (length (ebox-child-range--segment-payload
                        (ebox-child-range--segment-at empty 1))) 0))
    (should (equal (mapcar (lambda (item) (plist-get item :key))
                           (ebox-child-range--flatten many))
                   '((static 0) two three)))
    (should-not (cdr (ebox-child-range--flatten empty-again)))
    (should-error
     (ebox-child-range--build
      (list (cons 'same nil) (cons 'same nil))))
    (should-error (ebox-child-range--build (list (cons nil nil))))
    (should-error (ebox-child-range--build nil))
    (should-error
     (ebox-child-range--build
      (list (cons nil (list (ebox-child-range-test--item 'a)
                            (ebox-child-range-test--item 'b))))))
    (should-error
     (ebox-child-range--build
      (list (cons nil (list (ebox-child-range-test--item 'duplicate)))
            (cons 'range (list (ebox-child-range-test--item 'duplicate))))))
    (should-error
     (ebox-child-range--build
      (list (cons 'left (list (ebox-child-range-test--item 'duplicate)))
            (cons 'right (list (ebox-child-range-test--item 'duplicate))))))
    (should-error
     (ebox-child-range--replace
      empty 'range
      (list (ebox-child-range--descriptor-create 'nested nil))))
    (should-error (ebox-child-range--descriptor-create nil nil))
    (should-error (ebox-child-range--descriptor-create 'bad '(one . two)))
    (should-error (ebox-child-range--replace empty 'range '(one . two)))
    (should-error
     (ebox-child-range--build (list (cons 'bad '(one . two)))))
    (should-error (ebox-child-range--replace empty 'missing nil))))

(ert-deftest ebox-child-range-gate-a-adjacent-refs-and-unkeyed-items ()
  "First, middle, and last Range refs stay O(1)-addressed and accept no key."
  (let* ((segments
          (list
           (cons 'first (list (list :value 'unkeyed-first)))
           (cons nil (list (ebox-child-range-test--item 'static-a)))
           (cons 'middle (list (ebox-child-range-test--item 'middle-old)))
           (cons 'adjacent (list (ebox-child-range-test--item 'adjacent)))
           (cons nil (list (list :value 'unkeyed-static)))
           (cons 'last nil)))
         (base (ebox-child-range--build segments)))
    (dolist (entry '((first first-new) (middle middle-new) (last last-new)))
      (let* ((result
              (ebox-child-range--replace
               base (car entry)
               (list (ebox-child-range-test--item (cadr entry)))))
             (new (car result))
             (metrics (cdr result)))
        (should (= (ebox-child-range--metrics-ref-index-visits metrics) 1))
        (should (= (ebox-child-range--metrics-ref-index-copies metrics) 0))
        (should (eq (ebox-child-range--sequence-ref-index base)
                    (ebox-child-range--sequence-ref-index new)))
        (should (equal
                 (ebox-child-range--hash-lookup
                  (ebox-child-range--sequence-key-root new)
                  (cadr entry)
                  (ebox-child-range--stable-hash (cadr entry)))
                 (cons (gethash (car entry)
                                (ebox-child-range--sequence-ref-index base))
                       0)))))
    (should (equal (plist-get (car (ebox-child-range--flatten base)) :value)
                   'unkeyed-first))
    (should (eq (ebox-child-range--segment-ref
                 (ebox-child-range--lookup-ref base 'middle))
                'middle))))

(ert-deftest ebox-child-range-integration-is-transparent-and-indexed ()
  "Compiled Range segments render as direct children and retain empty refs."
  (let* ((static (ebox-create :key 'a :class "a" :content "A" :width '(40)))
         (one (ebox-create :key 'b :class "b" :content "B" :width '(40)))
         (two (ebox-create :key 'c :class "c" :content "C" :width '(40)))
         (descriptor (ebox-child-range--descriptor-create 'items (list one two)))
         (empty (ebox-child-range--descriptor-create 'empty nil))
         (raw-items (ebox-child-range--descriptor-items descriptor))
         (ranged (ebox-column static empty descriptor))
         (direct (ebox-column
                  (ebox-create :key 'a :class "a" :content "A" :width '(40))
                  (ebox-create :key 'b :class "b" :content "B" :width '(40))
                  (ebox-create :key 'c :class "c" :content "C" :width '(40))))
         (left (generate-new-buffer " *ebox-range-direct*"))
         (right (generate-new-buffer " *ebox-range-compiled*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer left direct)
          (ebox-render-to-buffer right ranged)
          (should (equal
                   (with-current-buffer left
                     (substring-no-properties (buffer-string)))
                   (with-current-buffer right
                     (substring-no-properties (buffer-string)))))
          (should (equal
                   (mapcar #'ebox-string-pixel-width
                           (ebox-string-lines
                            (with-current-buffer left (buffer-string))))
                   (mapcar #'ebox-string-pixel-width
                           (ebox-string-lines
                            (with-current-buffer right (buffer-string))))))
          (should (eq raw-items (ebox-child-range--descriptor-items descriptor)))
          (should (equal (mapcar (lambda (node) (plist-get node :key)) raw-items)
                         '(b c)))
          (let* ((direct-state (ebox--buffer-render-state left))
                 (state (ebox--buffer-render-state right))
                 (range-table (plist-get state :range-ref-table))
                 (empty-record (gethash 'empty range-table))
                 (items-record (gethash 'items range-table))
                 (empty-resolved
                  (ebox-incremental--range-ref-resolve state 'empty))
                 (items-resolved
                  (ebox-incremental--range-ref-resolve state 'items)))
            (should empty-record)
            (should items-record)
            (should-not (plist-member empty-record :rank))
            (should-not (plist-member empty-record :sequence))
            (should (= (plist-get empty-resolved :rank) 1))
            (should (= (plist-get items-resolved :rank) 1))
            (should (= (hash-table-count (plist-get state :node-table))
                       (hash-table-count (plist-get direct-state :node-table))))
            (should (= (hash-table-count (plist-get state :region-id-set))
                       (hash-table-count
                        (plist-get direct-state :region-id-set))))
            (should (= (hash-table-count
                        (plist-get state :surface-node-object-table))
                       (hash-table-count
                        (plist-get direct-state :surface-node-object-table))))
            (should (equal (plist-get empty-record :parent-node-id)
                           (plist-get (plist-get state :root-node) :node-id))))
          (should (= (length (ebox-selector-query-buffer right ".a + .b")) 1))
          (should (= (length (ebox-selector-query-buffer right ".a ~ .c")) 1)))
      (dolist (buffer (list left right))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest ebox-child-range-integration-rejects-invalid-placement-atomically ()
  "Range refs, keys, nesting, roots, and scalar slots fail before publication."
  (let ((buffer (generate-new-buffer " *ebox-range-invalid*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer buffer (ebox-create :key 'root :content "old"))
          (let ((before (with-current-buffer buffer (buffer-string)))
                (state (ebox--buffer-render-state buffer)))
            (dolist
                (root
                 (list
                  (ebox-child-range--descriptor-create
                   'root (list (ebox-create :key 'x :content "x")))
                  (list :ebox-type 'box
                        :ebox-content-node
                        (ebox-child-range--descriptor-create 'scalar nil))
                  (ebox-column
                   (ebox-child-range--descriptor-create
                    'outer
                    (list (ebox-child-range--descriptor-create 'nested nil))))
                  (ebox-column
                   (ebox-child-range--descriptor-create 'same nil)
                   (ebox-column
                    (ebox-child-range--descriptor-create 'same nil)))
                  (ebox-column
                   (ebox-create :key 'duplicate :content "a")
                   (ebox-child-range--descriptor-create
                    'range (list (ebox-create :key 'duplicate :content "b"))))))
              (should-error (ebox-commit buffer root))
              (should (eq (ebox--buffer-render-state buffer) state))
              (should (equal (with-current-buffer buffer (buffer-string))
                             before)))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-child-range-production-readers-use-tree-accessor ()
  "Range-capable production consumers do not read node `:children' directly."
  (dolist (file '("ebox.el" "ebox-layout.el" "ebox-flex.el" "ebox-grid.el"
                  "ebox-incremental.el" "ebox-native-reflow.el"
                  "ebox-surface.el"))
    (with-temp-buffer
      (insert-file-contents
       (expand-file-name file ebox-child-range-test--root))
      (should-not (re-search-forward
                   "plist-get[[:space:]\n]+\\(?:node\\|flex-node\\)[[:space:]\n]+:children"
                   nil t)))))

(ert-deftest ebox-child-range-ecss-subjects-and-inheritance-are-transparent ()
  "Ranges add no ECSS subject and preserve child/sibling cascade semantics."
  (let* ((ebox-style-stylesheet (ecss-stylesheet-create))
         (direct-left
          (ebox-create :key 'left :host-ref 'left :class "left"
                       :content "L" :width '(40)))
         (direct-right
          (ebox-create :key 'right :host-ref 'right :class "right"
                       :content "R" :width '(40)))
         (range-left
          (ebox-create :key 'left :host-ref 'left :class "left"
                       :content "L" :width '(40)))
         (range-right
          (ebox-create :key 'right :host-ref 'right :class "right"
                       :content "R" :width '(40)))
         (left-range
          (ebox-child-range--descriptor-create 'left-range (list range-left)))
         (right-range
          (ebox-child-range--descriptor-create 'right-range (list range-right)))
         (direct (plist-put (ebox-column direct-left direct-right)
                            :class "parent"))
         (ranged (plist-put (ebox-column left-range right-range)
                            :class "parent"))
         (direct-buffer (generate-new-buffer " *ebox-range-ecss-direct*"))
         (range-buffer (generate-new-buffer " *ebox-range-ecss-range*"))
         (original (symbol-function 'ebox-style-compute-subject))
         direct-subjects range-subjects)
    (ebox-style-add-rule ".parent > .left" '(:color "#123456"))
    (ebox-style-add-rule ".left + .right" '(:background-color "#ABCDEF"))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'ebox-style-compute-subject)
                     (lambda (&rest arguments)
                       (cl-incf direct-subjects)
                       (apply original arguments))))
            (setq direct-subjects 0)
            (ebox-render-to-buffer direct-buffer direct))
          (cl-letf (((symbol-function 'ebox-style-compute-subject)
                     (lambda (&rest arguments)
                       (cl-incf range-subjects)
                       (apply original arguments))))
            (setq range-subjects 0)
            (ebox-render-to-buffer range-buffer ranged))
          (should (= direct-subjects range-subjects))
          (should (= (length (ebox-selector-query-buffer
                              range-buffer ".left + .right")) 1))
          (let ((direct-faces
                 (with-current-buffer direct-buffer
                   (cl-loop for position from (point-min) below (point-max)
                            collect (get-text-property position 'face))))
                (range-faces
                 (with-current-buffer range-buffer
                   (cl-loop for position from (point-min) below (point-max)
                            collect (get-text-property position 'face)))))
            (should (equal direct-faces range-faces)))
          (dolist (node (list range-left range-right))
            (should-not (plist-get node :node-id))
            (should-not (plist-get node :region-id))
            (should-not (plist-get node :surface-object)))
          (dolist (ref '(left right))
            (let* ((state (ebox--buffer-render-state range-buffer))
                   (node-id (gethash ref (plist-get state :host-ref-table)))
                   (node (gethash node-id (plist-get state :node-table))))
              (should node-id)
              (should (equal (plist-get node :key) ref)))))
      (dolist (buffer (list direct-buffer range-buffer))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest ebox-child-range-path-copy-replaces-compiled-material-child ()
  "Tree path copying cannot ignore a child stored in a compiled sequence."
  (let* ((source
         (ebox-column
           (ebox-create :key 'static :content "static")
           (ebox-child-range--descriptor-create
            'items (list (ebox-create :key 'old :content "old")))))
         (compiled (ebox-tree-copy-node-structure source))
         (old-child (cadr (ebox-tree-layout-children compiled)))
         (new-child (ebox-create :key 'new :content "new"))
         (unchanged (ebox-tree-copy-with-direct-child-replacements compiled nil))
         (copy (ebox-tree-copy-with-direct-child-replacements
                compiled (list (cons old-child new-child)))))
    (should (eq (plist-get unchanged :ebox-child-sequence)
                (plist-get compiled :ebox-child-sequence)))
    (should (equal (mapcar (lambda (node) (plist-get node :key))
                           (ebox-tree-layout-children copy))
                   '(static new)))
    (should (equal (mapcar (lambda (node) (plist-get node :key))
                           (ebox-tree-layout-children compiled))
                   '(static old)))))

(ert-deftest ebox-child-range-empty-sequence-is-authoritative ()
  "An all-empty sequence cannot fall through to legacy alias children."
  (let* ((sequence (ebox-child-range--build (list (cons 'empty nil))))
         (legacy (ebox-create :key 'legacy :content "legacy"))
         (node (list :ebox-type 'stack :ebox-child-sequence sequence
                     :top legacy :bottom legacy)))
    (should-not (ebox-tree-layout-children node))))

(ert-deftest ebox-child-range-validator-covers-wrapper-and-scalar-slots ()
  "Flat Range compilation cannot hide wrappers or admit scalar descriptors."
  (let* ((wrapper (ebox-create :key 'wrapper :host-ref 'wrapper :content "W"))
         (item (ebox-create :key 'item :host-ref 'item :content "I"))
         (descriptor (ebox-child-range--descriptor-create 'items (list item)))
         (source (list :ebox-type 'flex :display '(block flex)
                       :box wrapper :children (list descriptor))))
    (ebox-tree-validate-declarative-root source)
    (let* ((copy (ebox-tree-copy-node-structure source))
           (copy-wrapper (plist-get copy :box))
           (copy-item (car (ebox-tree-layout-children copy))))
      (should-not (eq wrapper copy-wrapper))
      (should-not (eq item copy-item))
      (dolist (node (list wrapper item))
        (should-not (plist-get node :node-id))
        (should-not (plist-get node :region-id))
        (should-not (plist-get node :surface-object))))
    (should-error
     (ebox-tree-validate-declarative-root
      (list :ebox-type 'stack :display '(block column)
            :top (ebox-child-range--descriptor-create 'bad nil)
            :bottom (ebox-create :key 'bottom :content "B"))))
    (should-error
     (ebox-tree-validate-declarative-root
      (list :ebox-type 'flex :display '(block flex)
            :box (ebox-create :key 'same :host-ref 'same :content "W")
            :children
            (list (ebox-child-range--descriptor-create
                   'items
                   (list (ebox-create :key 'item :host-ref 'same
                                      :content "I")))))))))

(ert-deftest ebox-child-range-public-candidate-splices-and-reports ()
  "Public child Ranges support empty and repeated last-wins candidate splices."
  (let* ((buffer (generate-new-buffer " *ebox-public-range*"))
         (source
          (ebox-column
           (ebox-create :key 'static :content "S")
           (ebox-child-range 'items)))
         report)
    (unwind-protect
        (progn
          (ebox-render-to-buffer buffer source)
          (dolist (items
                   (list
                    (list (ebox-create :key 'one :content "1"))
                    (list (ebox-create :key 'two :content "2")
                          (ebox-create :key 'three :content "3"))
                    (list (ebox-create :key 'final :content "F"))
                    nil))
            (let ((candidate (ebox-candidate-begin buffer)))
              (ebox-candidate-replace-range-ref candidate 'items items)
              (when items
                (ebox-candidate-replace-range-ref candidate 'items items))
              (setq report (ebox-commit buffer candidate))
              (should (plist-get report :range-metrics))))
          (should (gethash 'items
                           (plist-get (ebox--buffer-render-state buffer)
                                      :range-ref-table))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-child-range-stable-keyed-refresh-is-not-structural ()
  "Stable keyed Range refreshes must not become root structure updates."
  (let ((buffer (generate-new-buffer " *ebox-stable-range-dirty*")))
    (cl-labels
        ((rows (selected)
           (cl-loop for id from 1 to 12
                    collect
                    (ebox-create
                     :key id :content (format "row-%02d" id) :width '(420)
                     :color (and (= id selected) "#2F6B43"))))
         (root ()
           (ebox-create
            :width '(900) :color "#172033" :wrap-mode nil
            :ebox-content-node
            (ebox-flex
             :width '(900)
             (ebox-create
              :key 'list :width 'stretch :min-width 0 :wrap-mode nil
              :min-height 24 :padding '(2 2) :border "#687386"
              :flex-grow 2 :flex-shrink 1 :flex-basis '(600)
              :ebox-content-node
              (ebox-column
               (apply #'ebox-child-range 'items (rows 1))))
             (ebox-create :key 'detail :host-ref 'detail
                          :width 'stretch :min-width 0
                          :min-height 24 :padding '(2 2) :border "#687386"
                          :flex-grow 1 :flex-shrink 1 :flex-basis '(300)
                          :content "detail-1")))))
      (unwind-protect
          (progn
            (ebox-render-to-buffer buffer (root))
            (let ((root-id (ebox--buffer-root-node-id buffer)))
              (dolist (selected '(2 1 2))
                (let ((candidate (ebox-candidate-begin buffer)))
                  (ebox-candidate-replace-range-ref
                   candidate 'items (rows selected))
                  (ebox-candidate-replace-host-ref
                   candidate 'detail
                   (ebox-create :key 'detail :host-ref 'detail
                                :width 'stretch :min-width 0
                                :min-height 24 :padding '(2 2)
                                :border "#687386"
                                :flex-grow 1 :flex-shrink 1 :flex-basis '(300)
                                :content (format "detail-%d" selected)))
                  (let ((report (ebox-commit buffer candidate)))
                    (ert-info ((format "selected=%S report=%S"
                                       selected report))
                      (should-not (memq 'structure
                                        (plist-get report :dirty-kinds)))
                      (should-not (member root-id
                                          (plist-get report :owner-ids)))
                      (should (memq (plist-get report :strategy)
                                    '(span-patch owner-rerender
                                      mixed-owner-reflow)))
                      (should (= (plist-get report :tp-scope-count) 3))
                      (should (= (plist-get report :created-objects) 0))
                      (should (= (plist-get report :removed-objects) 0))))))))
      (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest ebox-child-range-does-not-reuse-disappeared-key-positionally ()
  "A new keyed item must not inherit a removed peer's runtime identity."
  (let ((buffer (generate-new-buffer " *ebox-range-key-reentry*")))
    (cl-labels
        ((rows (keys)
           (mapcar (lambda (key)
                     (ebox-create :key key
                                  :content (format "row-%s" key)))
                   keys))
         (row-id (key)
           (let* ((state (ebox--buffer-render-state buffer))
                  (resolved (ebox-incremental--range-ref-resolve
                             state 'items))
                  (segment (ebox-child-range--segment-at
                            (plist-get resolved :sequence)
                            (plist-get resolved :segment-index)))
                  (node (cl-find key
                                 (append
                                  (ebox-child-range--segment-payload segment)
                                  nil)
                                 :key (lambda (item)
                                        (plist-get item :key)))))
             (plist-get node :node-id))))
      (unwind-protect
          (progn
            (ebox-render-to-buffer
             buffer
             (ebox-column
              (apply #'ebox-child-range 'items (rows '(1 2 3 4)))))
            (let ((initial-1 (row-id 1))
                  (initial-4 (row-id 4)))
              (let ((candidate (ebox-candidate-begin buffer)))
                (ebox-candidate-replace-range-ref
                 candidate 'items (rows '(1 4)))
                (ebox-commit buffer candidate))
              (let ((candidate (ebox-candidate-begin buffer)))
                (ebox-candidate-replace-range-ref
                 candidate 'items (rows '(1 2 3 4)))
                (ebox-commit buffer candidate))
              (should (= initial-1 (row-id 1)))
              (should (= initial-4 (row-id 4)))
              (should-not (= initial-4 (row-id 2)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest ebox-child-range-sole-child-keeps-public-layout-parent ()
  "Keep row/column material parents for one empty or populated Range."
  (dolist (constructor '(ebox-row ebox-column))
    (dolist (items (list nil (list (ebox-create :key 'one :content "1"))))
      (let* ((range (apply #'ebox-child-range 'items items))
             (parent (funcall constructor range)))
        (should-not (ebox-child-range--descriptor-p parent))
        (should (eq (plist-get parent :ebox-type)
                    (if (eq constructor 'ebox-row) 'concat 'stack)))
        (should (equal (plist-get parent :children) (list range)))
        (should (stringp (ebox-render parent)))))))

(ert-deftest ebox-child-range-dsl-layout-child-keeps-props-wrapper ()
  "Pass a Range through row/column DSL children while retaining properties."
  (dolist (tag '(row column))
    (let* ((range (ebox-child-range 'items))
           (node (ebox-build (list tag :color "red" range))))
      (should (equal "red" (plist-get node :color)))
      (should (not (ebox-child-range--descriptor-p node)))
      (should-error (ebox-build range)))))

(ert-deftest ebox-child-range-empty-owner-falls-back-atomically ()
  "Publish empty sole Range through full surface fallback and rollback safely."
  (let ((buffer (generate-new-buffer " *ebox-empty-range-owner*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer buffer
                                 (ebox-column (ebox-child-range 'items)))
          (let ((candidate (ebox-candidate-begin buffer)))
            (ebox-candidate-replace-range-ref
             candidate 'items (list (ebox-create :key 'one :content "1")))
            (cl-letf (((symbol-function 'accept-change-group)
                       (lambda (&rest _) (error "injected empty accept"))))
              (should-error (ebox-commit buffer candidate) :type 'error)))
          (should (equal "" (with-current-buffer buffer (buffer-string))))
          (let ((candidate (ebox-candidate-begin buffer)))
            (ebox-candidate-replace-range-ref
             candidate 'items (list (ebox-create :key 'one :content "1")))
            (let ((report (ebox-commit buffer candidate)))
              (should (plist-get report :empty-range-owner-fallback))))
          (should (string-match-p "1" (with-current-buffer buffer
                                        (buffer-string))))
          (let ((candidate (ebox-candidate-begin buffer)))
            (ebox-candidate-replace-range-ref candidate 'items nil)
            (ebox-commit buffer candidate))
          (should (equal "" (with-current-buffer buffer (buffer-string)))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-child-range-candidate-derivation-never-flattens-parent ()
  "Range logical-root and local-index derivation never flatten parent payloads."
  (let* ((buffer (generate-new-buffer " *ebox-range-no-flatten*"))
         (static
          (cl-loop for index below 100
                   collect (ebox-create :key (list 'static index)
                                        :content (number-to-string index))))
         (root (apply #'ebox-column
                      (append static
                              (list (ebox-child-range
                                     'items
                                     (ebox-create :key 'old :content "old"))))))
         candidate logical trace deltas)
    (unwind-protect
        (progn
          (ebox-render-to-buffer buffer root)
          (setq candidate (ebox-candidate-begin buffer))
          (ebox-candidate-replace-range-ref
           candidate 'items (list (ebox-create :key 'new :content "new")))
          (setq trace (make-hash-table :test 'equal))
          (cl-letf (((symbol-function 'ebox-child-range--flatten)
                     (lambda (&rest _) (error "candidate flattened Range"))))
            (let ((ebox-incremental--candidate-path-copy-trace trace)
                  (ebox-incremental--candidate-range-index-deltas nil))
              (setq logical
                    (ebox-incremental--candidate-logical-root candidate nil)
                    deltas ebox-incremental--candidate-range-index-deltas))
            (ebox-incremental--candidate-local-index-delta
             (ebox-candidate--base-state candidate) logical trace deltas))
          (let ((metrics (car (ebox-candidate--range-metrics candidate))))
            (should (= (plist-get metrics :segment-visits) 3))
            (should (= (plist-get metrics :unaffected-payload-visits) 0))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-child-range-adjacent-key-move-is-two-phase ()
  "A key can move between adjacent Ranges in one logical candidate."
  (let ((buffer (generate-new-buffer " *ebox-range-key-move*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer
              buffer
            (ebox-column
             (ebox-child-range 'left (ebox-create :key 'move :content "L"))
             (ebox-child-range 'right (ebox-create :key 'stay :content "R"))))
          (let ((candidate (ebox-candidate-begin buffer)))
            (ebox-candidate-replace-range-ref candidate 'left nil)
            (ebox-candidate-replace-range-ref
             candidate 'right
             (list (ebox-create :key 'move :content "M")
                   (ebox-create :key 'stay :content "R")))
            (ebox-commit buffer candidate))
          (should (string-match-p "M" (with-current-buffer buffer
                                          (buffer-string)))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-child-range-public-gate-a-and-prepared-index ()
  "Public Range commits retain logarithmic metrics and a prepared local index."
  (dolist (static-count '(10 100 500))
    (let* ((buffer (generate-new-buffer " *ebox-range-public-gate*"))
           (root
            (apply #'ebox-column
                   (append
                    (cl-loop for index below static-count
                             collect (ebox-create :key (list 'static index)
                                                  :content "s"))
                    (list (ebox-child-range
                           'items (ebox-create :key 'old :content "o")))))))
      (unwind-protect
          (progn
            (ebox-render-to-buffer buffer root)
            (let* ((old-state (ebox--buffer-render-state buffer))
                   (old-table (plist-get old-state :range-ref-table))
                   (surface (with-current-buffer
                              buffer ebox-surface--buffer-surface))
                   (revision (tp-surface-revision surface))
                   (candidate (ebox-candidate-begin buffer))
                   report)
              (ebox-candidate-replace-range-ref
               candidate 'items
               (list (ebox-create :key 'new-a :content "a")
                     (ebox-create :key 'new-b :content "b")))
              (cl-letf (((symbol-function 'ebox--runtime-index)
                         (lambda (&rest _) (error "unexpected full index"))))
                (setq report (ebox-commit buffer candidate)))
              (let* ((parent-metrics
                      (car (plist-get (plist-get report :range-metrics)
                                      :parents)))
                     (bound (if (= static-count 10) 2 3)))
                (should (<= (plist-get parent-metrics :segment-visits) bound))
                (should (<= (plist-get parent-metrics :segment-copies) bound))
                (should (= (plist-get parent-metrics
                                      :unaffected-payload-visits) 0))
                (should (= (plist-get parent-metrics :new-payload-visits) 2)))
              (should (= (tp-surface-revision surface) (1+ revision)))
              (let* ((state (ebox--buffer-render-state buffer))
                     (resolved
                      (ebox-incremental--range-ref-resolve state 'items))
                     (segment
                      (ebox-child-range--segment-at
                       (plist-get resolved :sequence)
                       (plist-get resolved :segment-index))))
                (should (eq old-table (plist-get state :range-ref-table)))
                (dotimes (offset
                          (length (ebox-child-range--segment-payload segment)))
                  (let* ((node (aref
                                (ebox-child-range--segment-payload segment)
                                offset))
                         (node-id (plist-get node :node-id))
                         (object (gethash
                                  node-id
                                  (plist-get state
                                             :surface-node-object-table))))
                    (should (eq node (gethash node-id
                                              (plist-get state :node-table))))
                    (should object)
                    (should (eq object (plist-get node :surface-object))))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest ebox-child-range-candidate-introduced-ref-is-next-turn-only ()
  "A node replacement may introduce a Range address only for the next turn."
  (let ((buffer (generate-new-buffer " *ebox-range-introduced*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer
              buffer
            (ebox-column (ebox-create :key 'a :host-ref 'a :content "a")
                         (ebox-create :key 'b :content "b")))
          (let ((candidate (ebox-candidate-begin buffer)))
            (ebox-candidate-replace-host-ref
             candidate 'a
             (ebox-column
              (ebox-create :key 'a :host-ref 'a :content "a")
              (ebox-child-range 'introduced)))
            (should-error
             (ebox-candidate-replace-range-ref candidate 'introduced nil))
            (ebox-commit buffer candidate))
          (let ((candidate (ebox-candidate-begin buffer)))
            (ebox-candidate-replace-range-ref
             candidate 'introduced
             (list (ebox-create :key 'later :content "later")))
            (ebox-commit buffer candidate))
          (should (string-match-p "later" (with-current-buffer buffer
                                              (buffer-string)))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-child-range-coalescing-is-order-independent ()
  "Host ancestors win Range updates while Ranges win descendant Host updates."
  (dolist (order '(host-first range-first))
    (let ((buffer (generate-new-buffer " *ebox-range-coalesce*")))
      (unwind-protect
          (progn
            (ebox-render-to-buffer
                buffer
              (ebox-column
               (plist-put
                (ebox-column
                 (ebox-create :key 'static :content "s")
                 (ebox-child-range
                  'items (ebox-create :key 'child :host-ref 'child
                                      :content "old")))
                :host-ref 'parent)
               (ebox-create :key 'peer :content "peer")))
            (let ((candidate (ebox-candidate-begin buffer)))
              (dolist (operation (if (eq order 'host-first)
                                     '(host range) '(range host)))
                (pcase operation
                  ('host
                   (ebox-candidate-replace-host-ref
                    candidate 'parent
                    (ebox-create :key 'parent-new :content "HOST-WINS")))
                  ('range
                   (ebox-candidate-replace-range-ref
                    candidate 'items
                    (list (ebox-create :key 'range-new
                                       :content "range-loses"))))))
              (ebox-commit buffer candidate))
            (should (string-match-p "HOST-WINS"
                                    (with-current-buffer buffer
                                      (buffer-string)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest ebox-child-range-consecutive-host-updates-keep-point-location ()
  "Retained Host identity preserves its sequence point location across turns."
  (let ((buffer (generate-new-buffer " *ebox-range-host-location*")) node-id)
    (unwind-protect
        (progn
          (ebox-render-to-buffer
              buffer
            (ebox-column
             (ebox-create :key 'static :content "s")
             (ebox-child-range
              'items (ebox-create :key 'child :host-ref 'child :content "0"))))
          (dotimes (turn 2)
            (let ((candidate (ebox-candidate-begin buffer)))
              (ebox-candidate-replace-host-ref
               candidate 'child
               (ebox-create :key 'child :host-ref 'child
                            :content (number-to-string (1+ turn))))
              (ebox-commit buffer candidate))
            (let* ((state (ebox--buffer-render-state buffer))
                   (current-id (gethash 'child (plist-get state :host-ref-table)))
                   (node (gethash current-id (plist-get state :node-table))))
              (when node-id (should (equal node-id current-id)))
              (setq node-id current-id)
              (should (plist-get node :ebox-sequence-location))))
          (should (string-match-p "2" (with-current-buffer buffer
                                          (buffer-string)))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-child-range-three-way-coalescing-keeps-host-descendant ()
  "A losing Range cannot absorb a descendant Host under its winning ancestor."
  (let ((buffer (generate-new-buffer " *ebox-range-three-way*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer
              buffer
            (ebox-column
             (plist-put
              (ebox-column
               (ebox-create :key 'static :content "s")
               (ebox-child-range
                'items (ebox-create :key 'child :host-ref 'child
                                    :content "old")))
              :host-ref 'parent)
             (ebox-create :key 'peer :content "peer")))
          (let ((candidate (ebox-candidate-begin buffer)))
            (ebox-candidate-replace-host-ref
             candidate 'parent
             (plist-put
              (ebox-column
               (ebox-create :key 'static :content "s2")
               (ebox-child-range
                'items (ebox-create :key 'child :host-ref 'child
                                    :content "ancestor")))
              :host-ref 'parent))
            (ebox-candidate-replace-range-ref
             candidate 'items
             (list (ebox-create :key 'range :content "RANGE-LOSES")))
            (ebox-candidate-replace-host-ref
             candidate 'child
             (ebox-create :key 'child :host-ref 'child
                          :content "DESCENDANT-WINS"))
            (ebox-commit buffer candidate))
          (let ((text (with-current-buffer buffer (buffer-string))))
            (should (string-match-p "DESCENDANT-WINS" text))
            (should-not (string-match-p "RANGE-LOSES" text))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-child-range-large-payload-never-promotes-to-full-index ()
  "M=64 remains an affected-payload local delta under 500 static segments."
  (let* ((buffer (generate-new-buffer " *ebox-range-large-payload*"))
         (root
          (apply #'ebox-column
                 (append
                  (cl-loop for index below 500
                           collect (ebox-create :key (list 'static index)
                                                :content "s"))
                  (list (ebox-child-range 'items)))))
         report)
    (unwind-protect
        (progn
          (ebox-render-to-buffer buffer root)
          (let ((candidate (ebox-candidate-begin buffer)))
            (ebox-candidate-replace-range-ref
             candidate 'items
             (cl-loop for index below 64
                      collect (ebox-create :key (list 'new index)
                                           :content "n")))
            (cl-letf (((symbol-function
                        'ebox-incremental--candidate-full-index-preparation)
                       (lambda (&rest _) (error "unexpected full preparation")))
                      ((symbol-function 'ebox--runtime-index)
                       (lambda (&rest _) (error "unexpected full index"))))
              (setq report (ebox-commit buffer candidate))))
          (let ((metrics (car (plist-get (plist-get report :range-metrics)
                                         :parents))))
            (should (= (plist-get metrics :new-payload-visits) 64))
            (should (<= (plist-get metrics :segment-visits) 3))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-child-range-wins-descendant-host-in-both-orders ()
  "A surviving Range absorbs a descendant Host replacement independent of order."
  (dolist (order '(host-first range-first))
    (let ((buffer (generate-new-buffer " *ebox-range-wins-host*")))
      (unwind-protect
          (progn
            (ebox-render-to-buffer
                buffer
              (ebox-column
               (ebox-create :key 'static :content "s")
               (ebox-child-range
                'items (ebox-create :key 'child :host-ref 'child
                                    :content "old"))))
            (let ((candidate (ebox-candidate-begin buffer)))
              (dolist (operation (if (eq order 'host-first)
                                     '(host range) '(range host)))
                (if (eq operation 'host)
                    (ebox-candidate-replace-host-ref
                     candidate 'child
                     (ebox-create :key 'child :host-ref 'child
                                  :content "HOST-LOSES"))
                  (ebox-candidate-replace-range-ref
                   candidate 'items
                   (list (ebox-create :key 'range :content "RANGE-WINS")))))
              (ebox-commit buffer candidate))
            (let ((text (with-current-buffer buffer (buffer-string))))
              (should (string-match-p "RANGE-WINS" text))
              (should-not (string-match-p "HOST-LOSES" text))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest ebox-child-range-overlay-prunes-descendant-node-anchors ()
  "Ancestor/descendant node anchors install nested Range refs exactly once."
  (let ((buffer (generate-new-buffer " *ebox-range-overlay-prune*")))
    (unwind-protect
        (cl-labels
            ((child (static-text range-ref range-key range-text)
               (let ((node
                      (ebox-column
                       (ebox-create :key 'child-static :content static-text)
                       (if range-key
                           (ebox-child-range
                            range-ref
                            (ebox-create :key range-key :content range-text))
                         (ebox-child-range range-ref)))))
                 (plist-put node :key 'child)
                 (plist-put node :host-ref 'child)
                 node))
             (ancestor (child-node peer-text)
               (let ((node
                      (ebox-column
                       child-node
                       (ebox-create :key 'ancestor-peer :content peer-text))))
                 (plist-put node :key 'ancestor)
                 (plist-put node :host-ref 'ancestor)
                 node)))
          (ebox-render-to-buffer
              buffer
            (ebox-column
             (ancestor (child "s" 'old-ref nil nil) "p")
             (ebox-create :key 'root-peer :content "r")))
          (let ((candidate (ebox-candidate-begin buffer)))
            (ebox-candidate-replace-host-ref
             candidate 'ancestor
             (ancestor (child "s2" 'new-ref 'ancestor-range "a") "p2"))
            (ebox-candidate-replace-host-ref
             candidate 'child
             (child "s3" 'new-ref 'descendant-range "d"))
            (ebox-commit buffer candidate))
          (let* ((state (ebox--buffer-render-state buffer))
                 (table (plist-get state :range-ref-table))
                 (record (gethash 'new-ref table))
                 (child-id (gethash 'child (plist-get state :host-ref-table))))
            (should-not (gethash 'old-ref table))
            (should record)
            (should (= (hash-table-count table) 1))
            (should (equal (plist-get record :parent-node-id) child-id))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-child-range-disjoint-host-and-range-publish-once ()
  "Disjoint Host and Range changes share one scoped TP publication."
  (let ((buffer (generate-new-buffer " *ebox-range-disjoint*")) (callbacks 0))
    (unwind-protect
        (progn
          (ebox-render-to-buffer
              buffer
            (ebox-column
             (ebox-create :key 'host :host-ref 'host :content "old-host")
             (ebox-child-range
              'items (ebox-create :key 'old-range :content "old-range"))))
          (let* ((surface (with-current-buffer buffer ebox-surface--buffer-surface))
                 (revision (tp-surface-revision surface))
                 (candidate (ebox-candidate-begin buffer))
                 report)
            (ebox-candidate-replace-host-ref
             candidate 'host
             (ebox-create :key 'host :host-ref 'host :content "new-host"))
            (ebox-candidate-replace-range-ref
             candidate 'items
             (list (ebox-create :key 'new-range :content "new-range")))
            (setq report
                  (ebox-commit buffer candidate
                               (lambda (_report) (cl-incf callbacks))))
            (should (= callbacks 1))
            (should (= (tp-surface-revision surface) (1+ revision)))
            (should (= (plist-get (plist-get report :range-metrics)
                                  :applied-count) 1))
            (should-not (plist-get report :tp-scope-fallback))
            (let ((text (with-current-buffer buffer (buffer-string))))
              (should (string-match-p "new-host" text))
              (should (string-match-p "new-range" text)))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-child-range-final-accept-failure-restores-exact-generation ()
  "A Range commit rejected by final accept restores all old identities."
  (let ((buffer (generate-new-buffer " *ebox-range-final-rollback*")) trace)
    (unwind-protect
        (progn
          (ebox-render-to-buffer
              buffer
            (ebox-column
             (ebox-create :key 'static :content "s")
             (ebox-child-range
              'items (ebox-create :key 'old :host-ref 'old :content "old"))))
          (let* ((old-state (ebox--buffer-render-state buffer))
                 (old-root (plist-get old-state :root-node))
                 (old-table (plist-get old-state :range-ref-table))
                 (old-id (gethash 'old (plist-get old-state :host-ref-table)))
                 (old-buffer (with-current-buffer buffer (buffer-string)))
                 (candidate (ebox-candidate-begin buffer)))
            (ebox-candidate-replace-range-ref
             candidate 'items
             (list (ebox-create :key 'new :host-ref 'new :content "new")))
            (cl-letf (((symbol-function 'accept-change-group)
                       (lambda (_group) (error "reject final accept"))))
              (should-error
               (ebox-commit
                buffer candidate
                (lambda (_report) (push 'publish trace))
                (lambda (_report) (push 'rollback trace)))))
            (should (equal trace '(rollback publish)))
            (should (eq (ebox--buffer-render-state buffer) old-state))
            (should (eq (plist-get old-state :root-node) old-root))
            (should (eq (plist-get old-state :range-ref-table) old-table))
            (should (= (gethash 'old (plist-get old-state :host-ref-table))
                       old-id))
            (should (equal (with-current-buffer buffer (buffer-string))
                           old-buffer)))
          (let ((candidate (ebox-candidate-begin buffer)))
            (ebox-candidate-replace-range-ref
             candidate 'items
             (list (ebox-create :key 'new :content "new")))
            (ebox-commit buffer candidate)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-child-range-framework-failure-rolls-back-and-retries ()
  "A failed framework publish restores the exact old Range generation."
  (let ((buffer (generate-new-buffer " *ebox-range-rollback*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer
              buffer
            (ebox-column
             (ebox-create :key 'static :content "s")
             (ebox-child-range
              'items (ebox-create :key 'old :content "old"))))
          (let* ((old-state (ebox--buffer-render-state buffer))
                 (old-root (plist-get old-state :root-node))
                 (old-range-table (plist-get old-state :range-ref-table))
                 (old-buffer (with-current-buffer buffer (buffer-string)))
                 (candidate (ebox-candidate-begin buffer))
                 trace)
            (ebox-candidate-replace-range-ref
             candidate 'items
             (list (ebox-create :key 'new :content "new")))
            (should-error
             (ebox-commit
              buffer candidate
              (lambda (_report) (push 'publish trace) (error "reject"))
              (lambda (_report) (push 'rollback trace))))
            (should (equal trace '(rollback publish)))
            (should (eq (ebox--buffer-render-state buffer) old-state))
            (should (eq (plist-get old-state :root-node) old-root))
            (should (eq (plist-get old-state :range-ref-table) old-range-table))
            (should (equal (with-current-buffer buffer (buffer-string))
                           old-buffer)))
          (let ((candidate (ebox-candidate-begin buffer)))
            (ebox-candidate-replace-range-ref
             candidate 'items
             (list (ebox-create :key 'new :content "new")))
            (ebox-commit buffer candidate))
          (should (string-match-p "new" (with-current-buffer buffer
                                            (buffer-string)))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(provide 'ebox-child-range-tests)
;;; ebox-child-range-tests.el ends here
