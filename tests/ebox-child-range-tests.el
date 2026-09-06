;;; ebox-child-range-tests.el --- Persistent child sequence tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'ebox-child-range)
(require 'ebox)

;; This suite locks child-range and Elisp projection semantics.  Native frame
;; execution is verified separately and must not replace the named fallback
;; strategies merely because a developer has built the optional module.
(defvar ebox-native-reflow-module-path)
(setq ebox-native-reflow-module-path nil)

(defconst ebox-child-range-test--root
  (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name)))
  "Ebox repository root for source audits.")

(defun ebox-child-range-test--item (key)
  "Return one declarative test item for KEY."
  (list :key key :value key))

(defun ebox-child-range-test--node-key (item &optional source-index)
  "Return ITEM's key from SOURCE-INDEX or its low-level fixture field."
  (or (and (ebox-canonical-input-p item)
           (ebox-tree-node-author-key
            (ebox-test-source-index item) (ebox-test-root item)))
      (and source-index
           (ebox-tree-node-source-handle item)
           (ebox-tree-node-author-key source-index item))
      (plist-get item :key)))

(defalias 'ebox-child-range-test--key
  #'ebox-child-range-test--node-key)

(defun ebox-child-range-test--input (items)
  "Combine canonical fixture ITEMS into one Range replacement input."
  (apply #'ebox-test-forest-input items))

(defun ebox-child-range-test--host-ref-table (state)
  "Return STATE's source-owned Host reference index."
  (ebox-source--index-host-ref-table-view (plist-get state :source-index)))

(defun ebox-child-range-test--build (segments &optional hash-function)
  "Build low-level SEGMENTS with the fixture key contract."
  (ebox-child-range--build
   segments #'ebox-child-range-test--key hash-function))

(defun ebox-child-range-test--replace (sequence ref items)
  "Replace REF ITEMS using the fixture key contract."
  (ebox-child-range--replace
   sequence ref items #'ebox-child-range-test--key))

(defun ebox-child-range-test--fixture (static-count range-items &optional hash)
  "Build STATIC-COUNT static segments followed by RANGE-ITEMS."
  (ebox-child-range-test--build
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
  (let* ((item-input (ebox-test-box (ebox-test-text "item") :key 'item))
         (item (ebox-test-root item-input))
         (source-index (ebox-test-source-index item-input))
         (sequence
          (ebox-child-range--build
           (list (cons 'range (list item)))
           (lambda (node)
             (ebox-tree-node-author-key source-index node))))
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
                 (result (ebox-child-range-test--replace
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
         (result (ebox-child-range-test--replace
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
         (one (car (ebox-child-range-test--replace
                    empty 'range (list (ebox-child-range-test--item 'one)))))
         (many (car (ebox-child-range-test--replace
                     one 'range
                     (mapcar #'ebox-child-range-test--item '(two three)))))
         (empty-again (car (ebox-child-range-test--replace many 'range nil))))
    (should (= (length (ebox-child-range--segment-payload
                        (ebox-child-range--segment-at empty 1))) 0))
    (should (equal (mapcar (lambda (item) (plist-get item :key))
                           (ebox-child-range--flatten many))
                   '((static 0) two three)))
    (should-not (cdr (ebox-child-range--flatten empty-again)))
    (should-error
     (ebox-child-range-test--build
      (list (cons 'same nil) (cons 'same nil))))
    (should-error (ebox-child-range-test--build (list (cons nil nil))))
    (should-error (ebox-child-range-test--build nil))
    (should-error
     (ebox-child-range-test--build
      (list (cons nil (list (ebox-child-range-test--item 'a)
                            (ebox-child-range-test--item 'b))))))
    (should-error
     (ebox-child-range-test--build
      (list (cons nil (list (ebox-child-range-test--item 'duplicate)))
            (cons 'range (list (ebox-child-range-test--item 'duplicate))))))
    (should-error
     (ebox-child-range-test--build
      (list (cons 'left (list (ebox-child-range-test--item 'duplicate)))
            (cons 'right (list (ebox-child-range-test--item 'duplicate))))))
    (should-error
     (ebox-child-range-test--replace
      empty 'range
      (list (ebox-child-range--descriptor-create 'nested nil))))
    (should-error (ebox-child-range--descriptor-create nil nil))
    (should-error (ebox-child-range--descriptor-create 'bad '(one . two)))
    (should-error (ebox-child-range-test--replace empty 'range '(one . two)))
    (should-error
     (ebox-child-range-test--build (list (cons 'bad '(one . two)))))
    (should-error (ebox-child-range-test--replace empty 'missing nil))))

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
         (base (ebox-child-range-test--build segments)))
    (dolist (entry '((first first-new) (middle middle-new) (last last-new)))
      (let* ((result
              (ebox-child-range-test--replace
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
  (let* ((static (ebox-test-box :key 'a :class "a" (ebox-test-text "A") :width '(40)))
         (one (ebox-test-box :key 'b :class "b" (ebox-test-text "B") :width '(40)))
         (two (ebox-test-box :key 'c :class "c" (ebox-test-text "C") :width '(40)))
         (descriptor (ebox-child-range--descriptor-create 'items (list one two)))
         (empty (ebox-child-range--descriptor-create 'empty nil))
         (raw-items (ebox-child-range--descriptor-items descriptor))
         (ranged (ebox-test-column static empty descriptor))
         (direct (ebox-test-column
                  (ebox-test-box :key 'a :class "a" (ebox-test-text "A") :width '(40))
                  (ebox-test-box :key 'b :class "b" (ebox-test-text "B") :width '(40))
                  (ebox-test-box :key 'c :class "c" (ebox-test-text "C") :width '(40))))
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
          (should (equal (mapcar #'ebox-child-range-test--node-key raw-items)
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
  (should-error
   (ebox-test-column
    (ebox-child-range--descriptor-create
     'outer (list (ebox-child-range--descriptor-create 'nested nil)))))
  (should-error
   (ebox-test-column
    (ebox-test-box :key 'duplicate (ebox-test-text "a"))
    (ebox-child-range--descriptor-create
     'range (list (ebox-test-box :key 'duplicate (ebox-test-text "b"))))))
  (let ((buffer (generate-new-buffer " *ebox-range-invalid*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer buffer (ebox-test-box :key 'root (ebox-test-text "old")))
          (let ((before (with-current-buffer buffer (buffer-string)))
                (state (ebox--buffer-render-state buffer)))
            (dolist
                (root
                 (list
                  (ebox-child-range--descriptor-create
                   'root (list (ebox-test-box :key 'x (ebox-test-text "x"))))
                  (list :ebox-type 'box
                        :ebox-content-node
                        (ebox-child-range--descriptor-create 'scalar nil))
                  (ebox-test-column
                   (ebox-child-range--descriptor-create 'same nil)
                   (ebox-test-column
                    (ebox-child-range--descriptor-create 'same nil)))))
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
          (ebox-test-box :key 'left :source-identity 'left :class "left"
                       (ebox-test-text "L") :width '(40)))
         (direct-right
          (ebox-test-box :key 'right :source-identity 'right :class "right"
                       (ebox-test-text "R") :width '(40)))
         (range-left
          (ebox-test-box :key 'left :source-identity 'left :class "left"
                       (ebox-test-text "L") :width '(40)))
         (range-right
          (ebox-test-box :key 'right :source-identity 'right :class "right"
                       (ebox-test-text "R") :width '(40)))
         (left-range
          (ebox-child-range--descriptor-create 'left-range (list range-left)))
         (right-range
          (ebox-child-range--descriptor-create 'right-range (list range-right)))
         (direct (ebox-test-column
                  :class "parent" direct-left direct-right))
         (ranged (ebox-test-column
                  :class "parent" left-range right-range))
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
                   (node-id
                    (gethash ref
                             (ebox-child-range-test--host-ref-table state)))
                   (node (gethash node-id (plist-get state :node-table))))
              (should node-id)
              (should (equal
                       (ebox-child-range-test--node-key
                        node (plist-get state :source-index))
                       ref)))))
      (dolist (buffer (list direct-buffer range-buffer))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest ebox-child-range-path-copy-replaces-compiled-material-child ()
  "Tree path copying cannot ignore a child stored in a compiled sequence."
  (let* ((source
          (ebox-test-column
           (ebox-test-box :key 'static (ebox-test-text "static"))
           (ebox-test-child-range
            'items (ebox-test-box :key 'old (ebox-test-text "old")))))
         (compiled (ebox-tree-copy-node-structure (ebox-test-root source)))
         (old-child (cadr (ebox-tree-layout-children compiled)))
         (new-input (ebox-test-box :key 'new (ebox-test-text "new")))
         (new-child (ebox-test-root new-input))
         (source-index
          (ebox-test-source-index
           (ebox-test-forest-input source new-input)))
         (unchanged (ebox-tree-copy-with-direct-child-replacements compiled nil))
         (copy (ebox-tree-copy-with-direct-child-replacements
                compiled (list (cons old-child new-child))
                (lambda (node)
                  (ebox-child-range-test--node-key node source-index)))))
    (should (eq (plist-get unchanged :ebox-child-sequence)
                (plist-get compiled :ebox-child-sequence)))
    (should (equal (mapcar (lambda (node)
                             (ebox-child-range-test--node-key
                              node source-index))
                           (ebox-tree-layout-children copy))
                   '(static new)))
    (should (equal (mapcar (lambda (node)
                             (ebox-child-range-test--node-key
                              node source-index))
                           (ebox-tree-layout-children compiled))
                   '(static old)))
    (let* ((original (ebox-test-text "old"))
           (range (ebox-test-child-range 'typed original))
           (typed-input (ebox-test-column range))
           (typed (ebox-test-root typed-input))
           (owned (car (ebox-box-node-children typed)))
           (replacement-input (ebox-test-text "new"))
           (replacement (ebox-test-root replacement-input))
           (replaced
            (ebox-tree-copy-with-direct-child-replacements
             typed (list (cons owned replacement))))
           (builder (ebox-source-builder-create))
           (_typed-sources
            (ebox-source-builder-import
             builder (ebox-test-source-index typed-input)))
           (_replacement-sources
            (ebox-source-builder-import
             builder (ebox-test-source-index replacement-input)))
           (replaced-index
            (ebox-tree-source-builder-snapshot builder (list replaced)))
           direct)
      (ebox-tree-for-each-direct-child
       replaced (lambda (child) (push child direct)))
      (setq direct (nreverse direct))
      (dolist (view (list (ebox-box-node-children replaced)
                          direct
                          (ebox-tree-layout-children replaced)
                          (ebox-tree-semantic-children replaced)))
        (should (= (length view) 1))
        (should (eq (car view) replacement)))
      (should (eq (ebox-tree-validate-declarative-root
                   replaced nil nil replaced-index)
                  replaced))
      (should-error
       (ebox-tree-copy-with-direct-child-replacements
        typed (list (cons owned nil)))
       :type 'error))))

(ert-deftest ebox-child-range-empty-sequence-is-authoritative ()
  "An all-empty sequence cannot fall through to legacy alias children."
  (let* ((sequence (ebox-child-range-test--build (list (cons 'empty nil))))
         (legacy (ebox-test-box :key 'legacy (ebox-test-text "legacy")))
         (node (list :ebox-type 'stack :ebox-child-sequence sequence
                     :top legacy :bottom legacy)))
    (should-not (ebox-tree-layout-children node))))

(ert-deftest ebox-child-range-validator-covers-wrapper-and-scalar-slots ()
  "Flat Range compilation cannot hide wrappers or admit scalar descriptors."
  (let* ((wrapper-input
          (ebox-test-box :key 'wrapper :source-identity 'wrapper (ebox-test-text "W")))
         (item-input
          (ebox-test-box :key 'item :source-identity 'item (ebox-test-text "I")))
         (wrapper (ebox-test-root wrapper-input))
         (item (ebox-test-root item-input))
         (descriptor (ebox-test-child-range 'items item-input))
         (source (list :ebox-type 'flex :display '(block flex)
                       :box wrapper :children (list descriptor)))
         (typed-input (ebox-test-column descriptor))
         (typed (ebox-test-root typed-input)))
    (should-error (ebox-tree-copy-node-structure source) :type 'error)
    (ebox-tree-validate-declarative-root
     typed nil nil (ebox-test-source-index typed-input))
    (let* ((copy (ebox-tree-copy-node-structure typed))
           (copy-wrapper (car (ebox-tree-layout-children copy)))
           (copy-item (car (ebox-tree-layout-children copy))))
      (should-not (eq item copy-wrapper))
      (should-not (eq item copy-item))
      (dolist (node (list wrapper item))
        (should-not (plist-get node :node-id))
        (should-not (plist-get node :region-id))
        (should-not (plist-get node :surface-object))))
    (should-error
     (ebox-tree-validate-declarative-root
      (list :ebox-type 'stack :display '(block column)
            :top (ebox-child-range--descriptor-create 'bad nil)
            :bottom (ebox-test-box :key 'bottom (ebox-test-text "B")))))
    (should-error
     (ebox-tree-validate-declarative-root
      (list :ebox-type 'flex :display '(block flex)
            :box (ebox-test-box :key 'same :source-identity 'same (ebox-test-text "W"))
            :children
            (list (ebox-child-range--descriptor-create
                   'items
                   (list (ebox-test-box :key 'item :source-identity 'same
                                      (ebox-test-text "I"))))))))))

(ert-deftest ebox-child-range-public-candidate-splices-and-reports ()
  "Public child Ranges support empty and repeated last-wins candidate splices."
  (let* ((buffer (generate-new-buffer " *ebox-public-range*"))
         (source
          (ebox-test-column
           (ebox-test-box :key 'static (ebox-test-text "S"))
           (ebox-test-child-range 'items)))
         report)
    (unwind-protect
        (progn
          (ebox-render-to-buffer buffer source)
          (dolist (items
                   (list
                    (list (ebox-test-box :key 'one (ebox-test-text "1")))
                    (list (ebox-test-box :key 'two (ebox-test-text "2"))
                          (ebox-test-box :key 'three (ebox-test-text "3")))
                    (list (ebox-test-box :key 'final (ebox-test-text "F")))
                    nil))
            (let ((candidate (ebox-candidate-begin buffer)))
              (ebox-candidate-replace-range-ref
               candidate 'items (ebox-child-range-test--input items))
              (when items
                (ebox-candidate-replace-range-ref
                 candidate 'items (ebox-child-range-test--input items)))
              (setq report (ebox-commit buffer candidate))
              (should (plist-get report :range-metrics))))
          (should (gethash 'items
                           (plist-get (ebox--buffer-render-state buffer)
                                      :range-ref-table))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-child-range-candidate-retains-proven-owned-items ()
  "A fresh candidate-owned Range item is not copied twice before commit."
  (let* ((buffer (generate-new-buffer " *ebox-range-retained-items*"))
         (input
          (ebox-child-range-test--input
           (list (ebox-test-box :key 'new (ebox-test-text "new")))))
         (item (ebox-test-root input)))
    (unwind-protect
        (progn
          (ebox-render-to-buffer
           buffer
           (ebox-test-column
            (ebox-test-box :key 'static (ebox-test-text "static"))
            (ebox-test-child-range
             'items (ebox-test-box :key 'old (ebox-test-text "old")))))
          (let* ((candidate (ebox-candidate-begin buffer))
                 entry)
            (ebox-candidate-replace-range-ref
             candidate 'items input nil t)
            (setq entry (car (ebox-candidate--range-replacements candidate)))
            (should
             (ebox-incremental--candidate-range-replacement-retain-item-identities-p
              entry))
            (should (eq item
                        (car
                         (ebox-incremental--candidate-range-replacement-items
                          entry))))
            (ebox-commit buffer candidate))
          (let* ((state (ebox--buffer-render-state buffer))
                 (record (gethash 'items (plist-get state :range-ref-table)))
                 (parent (gethash (plist-get record :parent-node-id)
                                  (plist-get state :node-table)))
                 (segment
                  (ebox-child-range--lookup-ref
                   (plist-get parent :ebox-child-sequence) 'items))
                 (published (aref (ebox-child-range--segment-payload segment) 0)))
            (should (eq published item))
            (should (plist-get published :node-id))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-child-range-candidate-retention-falls-back-on-runtime-identity ()
  "A retention proof miss uses the ordinary identity-clearing copy path."
  (let* ((buffer (generate-new-buffer " *ebox-range-retention-fallback*"))
         (input
          (ebox-child-range-test--input
           (list (ebox-test-box :key 'new (ebox-test-text "new")))))
         (item (ebox-test-root input)))
    (plist-put item :node-id 999)
    (unwind-protect
        (progn
          (ebox-render-to-buffer
           buffer
           (ebox-test-column
            (ebox-test-child-range
             'items (ebox-test-box :key 'old (ebox-test-text "old")))))
          (let* ((candidate (ebox-candidate-begin buffer))
                 entry retained)
            (ebox-candidate-replace-range-ref
             candidate 'items input nil t)
            (setq entry (car (ebox-candidate--range-replacements candidate))
                  retained
                  (ebox-incremental--candidate-range-replacement-items entry))
            (should-not
             (ebox-incremental--candidate-range-replacement-retain-item-identities-p
              entry))
            (should-not (eq item (car retained)))
            (should-not (plist-get (car retained) :node-id))
            (ebox-commit buffer candidate))
          (should (string-match-p "new" (with-current-buffer buffer
                                           (buffer-string)))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-child-range-candidate-retains-fresh-slots-around-reuse ()
  "Mixed Range updates retain fresh slots while preserving reused slots."
  (let* ((buffer (generate-new-buffer " *ebox-range-mixed-retention*"))
         (input
          (ebox-child-range-test--input
           (list (ebox-test-box :key 'old-one (ebox-test-text "old-one"))
                 (ebox-test-box :key 'new-two (ebox-test-text "new-two")))))
         (fresh (nth 1 (ebox-test-forest input))))
    (unwind-protect
        (progn
          (ebox-render-to-buffer
           buffer
           (ebox-test-column
            (ebox-test-child-range
             'items
             (ebox-test-box :key 'old-one (ebox-test-text "old-one"))
             (ebox-test-box :key 'old-two (ebox-test-text "old-two")))))
          (let* ((candidate (ebox-candidate-begin buffer))
                 entry)
            (ebox-candidate-replace-range-ref
             candidate 'items input '((0 . 0)) t)
            (setq entry (car (ebox-candidate--range-replacements candidate)))
            (should
             (ebox-incremental--candidate-range-replacement-retain-item-identities-p
              entry))
            (should (eq fresh
                        (nth 1
                             (ebox-incremental--candidate-range-replacement-items
                              entry))))
            (ebox-commit buffer candidate))
          (let* ((state (ebox--buffer-render-state buffer))
                 (record (gethash 'items (plist-get state :range-ref-table)))
                 (parent (gethash (plist-get record :parent-node-id)
                                  (plist-get state :node-table)))
                 (segment
                  (ebox-child-range--lookup-ref
                   (plist-get parent :ebox-child-sequence) 'items))
                 (payload (ebox-child-range--segment-payload segment)))
            (should (eq fresh (aref payload 1)))
            (should (plist-get (aref payload 1) :node-id))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-child-range-stable-keyed-refresh-is-not-structural ()
  "Stable keyed Range refreshes must not become root structure updates."
  (let ((buffer (generate-new-buffer " *ebox-stable-range-dirty*")))
    (cl-labels
        ((rows (selected)
           (cl-loop for id from 1 to 12
                    for content = (ebox-test-text (format "row-%02d" id))
                    collect
                    (if (= id selected)
                        (ebox-test-box
                         :key id :width '(420) :color "#2F6B43" content)
                      (ebox-test-box :key id :width '(420) content))))
         (root ()
           (ebox-test-box
            :width '(900) :color "#172033" :wrap-mode 'none
            (ebox-test-flex
             :width '(900)
             (ebox-test-box
              :key 'list :width 'stretch :min-width 0 :wrap-mode 'none
              :min-height 24 :padding '(2 2) :border "#687386"
              :flex-grow 2 :flex-shrink 1 :flex-basis '(600)
              (ebox-test-column
               (apply #'ebox-test-child-range 'items (rows 1))))
             (ebox-test-box :key 'detail :source-identity 'detail
                          :width 'stretch :min-width 0
                          :min-height 24 :padding '(2 2) :border "#687386"
                          :flex-grow 1 :flex-shrink 1 :flex-basis '(300)
                          (ebox-test-text "detail-1"))))))
      (unwind-protect
          (progn
            (ebox-render-to-buffer buffer (root))
            (dolist (selected '(2 1 2))
              (let ((candidate (ebox-candidate-begin buffer)))
                  (ebox-candidate-replace-range-ref
                   candidate 'items
                   (ebox-child-range-test--input (rows selected)))
                  (ebox-candidate-replace-host-ref
                   candidate 'detail
                   (ebox-test-box :key 'detail :source-identity 'detail
                                :width 'stretch :min-width 0
                                :min-height 24 :padding '(2 2)
                                :border "#687386"
                                :flex-grow 1 :flex-shrink 1 :flex-basis '(300)
                                (ebox-test-text (format "detail-%d" selected))))
                  (let ((report (ebox-commit buffer candidate)))
                    (ert-info ((format "selected=%S report=%S"
                                       selected report))
                      (should-not (memq 'structure
                                        (plist-get report :dirty-kinds)))
                      (should (memq 'paint
                                    (plist-get report :dirty-kinds)))
                      (should (memq (plist-get report :strategy)
                                    '(span-patch owner-rerender
                                      mixed-owner-reflow)))
                      (should (> (plist-get report :tp-scope-count) 0))
                      (should-not (plist-get report :tp-full-root))
                      (should (= (plist-get report :created-objects) 0))
                      (should (= (plist-get report :removed-objects) 0))
                      (with-current-buffer buffer
                        (should (string-match-p
                                 (format "detail-%d" selected)
                                 (buffer-string)))))))))
      (when (buffer-live-p buffer) (kill-buffer buffer))))))

(defun ebox-child-range-test--snapshot-detail (expanded &optional title)
  "Return a retained detail root, with TITLE and status when EXPANDED."
  (if expanded
      (ebox-test-column :key 'detail :source-identity 'detail :overflow 'scroll
        :bgcolor "#E8DED1"
        (ebox-test-text (propertize (or title "title-1") 'face '(:weight bold))
                        :key 'title :source-identity 'title)
        (ebox-test-text "status" :key 'status :source-identity 'status))
    (ebox-test-text "placeholder" :key 'detail :source-identity 'detail)))

(defun ebox-child-range-test--snapshot-replacement-root ()
  "Return a detail Range beside painted rows and an active scroll sibling."
  (ebox-test-column :width '(200) :bgcolor "#FFFDF8"
    (ebox-test-box :key 'row-1 :source-identity 'row-1 :color "#123456"
      (ebox-test-text "row-1"))
    (ebox-test-box :key 'row-2 :source-identity 'row-2 :color "#654321"
      (ebox-test-text "row-2"))
    (ebox-test-column :bgcolor "#DDE7EF"
      :surface-properties '(help-echo "retained detail help")
      (ebox-test-child-range
       'details (ebox-child-range-test--snapshot-detail nil)))
    (ebox-test-box :key 'scroll :source-identity 'scroll
      :height 2 :width '(80) :overflow 'scroll
      (ebox-test-text "line-a\nline-b\nline-c\nline-d"))))

(defun ebox-child-range-test--replace-snapshot-detail (buffer expanded)
  "Return a BUFFER candidate replacing its detail Range with EXPANDED content."
  (let ((candidate (ebox-candidate-begin buffer)))
    (ebox-candidate-replace-range-ref
     candidate 'details (ebox-child-range-test--snapshot-detail expanded))
    candidate))

(defun ebox-child-range-test--assert-current-snapshot (buffer node-id)
  "Assert BUFFER's NODE-ID snapshot reflects its current structural/style facts."
  (let* ((node (ebox--buffer-runtime-node buffer node-id))
         (expected (ebox--node-layout-snapshot buffer node))
         (actual (ebox--layout-snapshot buffer node-id)))
    (dolist (key '(:type :display :region-ids :style-signature :child-ids))
      (ert-info ((format "current snapshot field %S" key))
        (should (equal (plist-get expected key) (plist-get actual key)))))))

(defun ebox-child-range-test--assert-full-render-equivalent (buffer)
  "Assert BUFFER exactly matches a full render of its published root."
  (with-current-buffer buffer
    (let* ((state (ebox--buffer-render-state buffer))
           (expected (ebox--render-node (plist-get state :root-node)
                                       (plist-get state :source-index))))
      (should (equal-including-properties expected (buffer-string))))))

(ert-deftest ebox-child-range-retained-kind-replacement-refreshes-snapshots ()
  "Text/Column roundtrips refresh facts only after successful publication."
  (with-temp-buffer
    (ebox-render-to-buffer
     (current-buffer) (ebox-child-range-test--snapshot-replacement-root))
    (let* ((owner-id (plist-get (ebox--host-ref-node (current-buffer) 'detail)
                                :node-id))
           (sibling-id (plist-get (ebox--host-ref-node (current-buffer) 'row-1)
                                  :node-id))
           (ancestors
            (let ((node-id owner-id)
                  (parents (plist-get (ebox--buffer-render-state (current-buffer))
                                      :parent-table))
                  result)
              (while (setq node-id (gethash node-id parents))
                (push node-id result))
              result)))
      (dolist (expanded '(t nil t))
        (ert-info ((format "detail expanded=%S" expanded))
          (dolist (ancestor ancestors)
            (ebox--layout-snapshot (current-buffer) ancestor))
          (ebox--ensure-layout-snapshot-details (current-buffer) sibling-id)
          (let* ((old (ebox--ensure-layout-snapshot-details (current-buffer) owner-id))
                 (old-facts (copy-tree old))
                 (state (ebox--buffer-render-state (current-buffer)))
                 (snapshots (plist-get state :layout-snapshots))
                 (runtime-revision (plist-get state :runtime-revision))
                 (surface-revision (tp-surface-revision ebox-surface--buffer-surface))
                 (scroll-id (car (plist-get state :scroll-region-ids)))
                 (scroll (gethash scroll-id ebox--scroll-global-state))
                 (before (buffer-string))
                 sibling-seed sibling-seed-facts
                 (seed-observer
                  (lambda (candidate-state)
                    (setq sibling-seed
                          (gethash sibling-id (plist-get candidate-state
                                                        :layout-snapshots))
                          sibling-seed-facts (copy-tree sibling-seed)))))
            (should (equal (if expanded '(inline flow) '(block column))
                           (plist-get old :display)))
            (should (eq (if expanded 'visible 'scroll)
                        (plist-get (plist-get old :style-signature) :overflow)))
            (cl-letf (((symbol-function 'accept-change-group)
                       (lambda (_) (error "Reject retained kind replacement"))))
              (should (equal
                       (should-error
                        (ebox-commit
                         (current-buffer)
                         (ebox-child-range-test--replace-snapshot-detail
                          (current-buffer) expanded)))
                       '(error "Reject retained kind replacement"))))
            (should (eq state (ebox--buffer-render-state (current-buffer))))
            (should (eq snapshots (plist-get state :layout-snapshots)))
            (should (eq old (gethash owner-id snapshots)))
            (should (equal old-facts old))
            (should (= runtime-revision (plist-get state :runtime-revision)))
            (should (= surface-revision
                       (tp-surface-revision ebox-surface--buffer-surface)))
            (should (eq scroll (gethash scroll-id ebox--scroll-global-state)))
            (should (equal-including-properties before (buffer-string)))
            (advice-add 'ebox-surface--render-candidate :before seed-observer)
            (unwind-protect
                (ebox-commit
                 (current-buffer)
                 (ebox-child-range-test--replace-snapshot-detail
                  (current-buffer) expanded))
              (advice-remove 'ebox-surface--render-candidate seed-observer))
            (should (ebox--layout-snapshot-detailed-p sibling-seed))
            (should (eq sibling-seed
                        (gethash sibling-id
                                 (plist-get (ebox--buffer-render-state (current-buffer))
                                            :layout-snapshots))))
            (should (equal sibling-seed-facts sibling-seed))
            (should (= owner-id
                       (plist-get (ebox--host-ref-node (current-buffer) 'detail)
                                  :node-id)))
            (ebox-child-range-test--assert-full-render-equivalent (current-buffer))
            (ebox-child-range-test--assert-current-snapshot
             (current-buffer) owner-id)
            (dolist (ancestor ancestors)
              (ebox-child-range-test--assert-current-snapshot
               (current-buffer) ancestor))))))))

(ert-deftest ebox-child-range-owner-scoped-followup-retains-proven-mounts ()
  "Repeated single-owner text updates retain published properties and mounts."
  (with-temp-buffer
    (ebox-render-to-buffer
     (current-buffer) (ebox-child-range-test--snapshot-replacement-root))
    (ebox-commit
     (current-buffer)
     (ebox-child-range-test--replace-snapshot-detail (current-buffer) t))
    (let* ((surface ebox-surface--buffer-surface)
           (state (ebox--buffer-render-state (current-buffer)))
           (mounts (tp--surface-mounts surface))
           (mount-ids (mapcar #'tp--surface-mount-id mounts))
           (mount-index (tp--surface-mount-index surface))
           (index (tp--surface-index surface))
           (ranges (plist-get state :surface-owned-ranges))
           (title-id (plist-get (ebox--host-ref-node (current-buffer) 'title) :node-id))
           retained)
      (dolist (title '("title-2" "title-3" "title-1"))
        (let ((candidate (ebox-candidate-begin (current-buffer))))
          (ebox-candidate-replace-host-ref
           candidate 'title
           (ebox-test-text (propertize title 'face '(:weight bold))
                           :key 'title :source-identity 'title))
          (let* ((report (ebox-commit (current-buffer) candidate))
                 (next-state (ebox--buffer-render-state (current-buffer)))
                 (tp-report (tp-surface-report surface)))
            (ebox-child-range-test--assert-full-render-equivalent (current-buffer))
            (should (eq (plist-get report :projection-kind) 'owner-scoped))
            (should (= (plist-get report :dirty-count) 1))
            (should (= title-id
                       (plist-get (ebox--host-ref-node (current-buffer) 'title) :node-id)))
            (should-not (plist-get report :tp-full-root))
            (should-not (plist-member next-state :span-patch-retained-owned-ranges))
            (should-not (plist-member next-state :paint-property-contributions))
            ;; Exercise every semantic update before checking the new reuse claim.
            (push (list :title title :batch (plist-get tp-report :commit-batch)
                        :retained (plist-get tp-report :retained-mount-state)
                        :mounts (eq mounts (tp--surface-mounts surface))
                        :ids (equal mount-ids
                                    (mapcar #'tp--surface-mount-id
                                            (tp--surface-mounts surface)))
                        :mount-index (eq mount-index (tp--surface-mount-index surface))
                        :index (eq index (tp--surface-index surface))
                        :snapshot (eq ranges (plist-get next-state :surface-owned-ranges)))
                  retained))))
      (dolist (sample (nreverse retained))
        (ert-info ((format "owner-scoped reuse sample %S" sample))
          (dolist (key '(:batch :retained :mounts :ids :mount-index :index :snapshot))
            (should (plist-get sample key))))))))

(ert-deftest ebox-child-range-owner-scoped-followup-rolls-back-and-retries ()
  "A rejected single-owner publication restores the exact prior generation."
  (with-temp-buffer
    (ebox-render-to-buffer
     (current-buffer) (ebox-child-range-test--snapshot-replacement-root))
    (ebox-commit
     (current-buffer)
     (ebox-child-range-test--replace-snapshot-detail (current-buffer) t))
    (cl-labels
        ((candidate ()
           (let ((value (ebox-candidate-begin (current-buffer))))
             (ebox-candidate-replace-host-ref
              value 'title
              (ebox-test-text (propertize "title-2" 'face '(:weight bold))
                              :key 'title :source-identity 'title))
             value)))
      (let* ((surface ebox-surface--buffer-surface)
             (state (ebox--buffer-render-state (current-buffer)))
             (revision (tp-surface-revision surface))
             (runtime-revision (plist-get state :runtime-revision))
             (previous-report (tp-surface-report surface))
             (mounts (tp--surface-mounts surface))
             (mount-ids (mapcar #'tp--surface-mount-id mounts))
             (mount-index (tp--surface-mount-index surface))
             (index (tp--surface-index surface))
             (ranges (plist-get state :surface-owned-ranges))
             (snapshots (plist-get state :layout-snapshots))
             (scroll-id (car (plist-get state :scroll-region-ids)))
             (scroll (gethash scroll-id ebox--scroll-global-state))
             (before (buffer-string)) trace)
        (should-error
         (ebox-commit
          (current-buffer) (candidate)
          (lambda (_report) (push 'publish trace) (error "reject owner publication"))
          (lambda (_report) (push 'rollback trace))))
        (should (equal trace '(rollback publish)))
        (should (eq state (ebox--buffer-render-state (current-buffer))))
        (should (eq state (tp-surface-client-state surface)))
        (should (= revision (tp-surface-revision surface)))
        (should (= runtime-revision (plist-get state :runtime-revision)))
        (should (equal previous-report (tp-surface-report surface)))
        (should (eq ranges (plist-get state :surface-owned-ranges)))
        (should (eq snapshots (plist-get state :layout-snapshots)))
        (should (eq mounts (tp--surface-mounts surface)))
        (should (equal mount-ids (mapcar #'tp--surface-mount-id mounts)))
        (should (eq mount-index (tp--surface-mount-index surface)))
        (should (eq index (tp--surface-index surface)))
        (should (eq scroll (gethash scroll-id ebox--scroll-global-state)))
        (should (equal-including-properties before (buffer-string)))
        (let* ((report (ebox-commit (current-buffer) (candidate)))
               (next-state (ebox--buffer-render-state (current-buffer))))
          (ebox-child-range-test--assert-full-render-equivalent (current-buffer))
          (should (= (1+ revision) (tp-surface-revision surface)))
          (should (= (1+ runtime-revision) (plist-get next-state :runtime-revision)))
          (should (eq (plist-get report :projection-kind) 'owner-scoped))
          (should-not (plist-member next-state :span-patch-retained-owned-ranges))
          (should-not (plist-member next-state :paint-property-contributions))
          (should (plist-get (tp-surface-report surface) :commit-batch))
          (should (plist-get (tp-surface-report surface) :retained-mount-state))
          (should (eq mounts (tp--surface-mounts surface)))
          (should (equal mount-ids (mapcar #'tp--surface-mount-id mounts)))
          (should (eq mount-index (tp--surface-mount-index surface)))
          (should (eq index (tp--surface-index surface)))
          (should (eq ranges (plist-get next-state :surface-owned-ranges))))))))

(ert-deftest ebox-child-range-owner-scoped-followup-proof-misses-keep-fallback ()
  "Each absent strict authority keeps a single-owner update on its fallback."
  (dolist (miss '(projection no-proof multi-owner range paint
                            no-witness copied-witness coordinates))
    (ert-info ((format "owner-scoped proof miss %S" miss))
      (with-temp-buffer
        (ebox-render-to-buffer
         (current-buffer) (ebox-child-range-test--snapshot-replacement-root))
        (ebox-commit
         (current-buffer)
         (ebox-child-range-test--replace-snapshot-detail (current-buffer) t))
        (let* ((candidate (ebox-candidate-begin (current-buffer)))
               (extent (buffer-size)) observed
               (observer
                (lambda (original &rest arguments)
                  (setq observed t)
                  (let* ((state (nth 2 arguments))
                         (proofs (plist-get state :owner-scoped-proofs))
                         (witness (plist-get state :span-patch-retained-owned-ranges)))
                    (unless (eq miss 'coordinates)
                      (should (eq (nth 4 arguments) 'owner-scoped))
                      (should (= (length proofs) 1))
                      (should witness)
                      (should (eq witness (plist-get state :previous-surface-owned-ranges))))
                    (pcase miss
                      ('projection
                       (setcar (nthcdr 4 arguments) 'span-patch)
                       (plist-put state :projection-kind 'span-patch))
                      ('no-proof (plist-put state :owner-scoped-proofs nil))
                      ('multi-owner
                       (plist-put state :owner-scoped-proofs
                                  (append proofs (list (copy-sequence (car proofs))))))
                      ('range
                       (plist-put state :owner-scoped-proofs
                                  (list (plist-put (copy-sequence (car proofs))
                                                   :range-splice-p t))))
                      ('paint
                       (plist-put state :paint-property-contributions
                                  '((:start 0 :end 0 :props nil))))
                      ('no-witness (cl-remf state :span-patch-retained-owned-ranges))
                      ('copied-witness
                       (let ((copy (copy-tree witness)))
                         (should (equal copy witness))
                         (should-not (eq copy witness))
                         (plist-put state :span-patch-retained-owned-ranges copy))))
                    (apply original arguments)))))
          (ebox-candidate-replace-host-ref
           candidate 'title
           (ebox-test-text
            (propertize (if (eq miss 'coordinates) "title-2 with a longer extent" "title-2")
                        'face '(:weight bold))
            :key 'title :source-identity 'title))
          (advice-add 'ebox-surface--projection-result :around observer)
          (unwind-protect
              (ebox-commit (current-buffer) candidate)
            (advice-remove 'ebox-surface--projection-result observer))
          (should observed)
          (ebox-child-range-test--assert-full-render-equivalent (current-buffer))
          (when (eq miss 'coordinates) (should-not (= extent (buffer-size))))
          (should-not (plist-member (ebox--buffer-render-state (current-buffer))
                                    :span-patch-retained-owned-ranges))
          (should-not (plist-member (ebox--buffer-render-state (current-buffer))
                                    :paint-property-contributions))
          (should-not (plist-get (tp-surface-report ebox-surface--buffer-surface)
                                 :retained-mount-state)))))))

(defun ebox-child-range-test--mixed-followup-candidate (buffer selected &optional title)
  "Return BUFFER's title and row-paint candidate for SELECTED, using TITLE."
  (let ((candidate (ebox-candidate-begin buffer)))
    (ebox-candidate-replace-host-ref
     candidate 'title
     (ebox-test-text (propertize (or title (format "title-%d" selected))
                                'face '(:weight bold))
                     :key 'title :source-identity 'title))
    (dolist (row '(1 2))
      (let ((ref (intern (format "row-%d" row))))
        (ebox-candidate-replace-host-ref
         candidate ref
         (ebox-test-box :key ref :source-identity ref
           :color (if (= row selected) "#123456" "#654321")
           (ebox-test-text (format "row-%d" row))))))
    candidate))

(ert-deftest ebox-child-range-paint-marker-consumption-preserves-input-baselines ()
  "Layering consumes transient markers without changing input or permanent facts."
  (with-temp-buffer
    (ebox-render-to-buffer
     (current-buffer) (ebox-child-range-test--snapshot-replacement-root))
    (let* ((state (copy-sequence (ebox--buffer-render-state (current-buffer))))
           (template (car (ebox-surface--materialized-fragment-ledger state)))
           (roles (plist-get template :paint-role-ids))
           (fragments
            (cl-loop for text in '("A" "B" "")
                     for marker in (list roles nil nil)
                     for baseline in '((:slant italic) nil nil)
                     collect
                     (let ((fragment (copy-sequence template)))
                       (plist-put fragment :text (propertize text 'face 'bold))
                       (plist-put fragment :text-source-p nil)
                       (plist-put fragment :face-baseline baseline)
                       (plist-put fragment :face-baseline-known-p t)
                       (plist-put fragment :old-paint-role-ids marker))))
           (before (copy-tree fragments))
           (before-text (mapcar (lambda (fragment)
                                 (copy-sequence (plist-get fragment :text)))
                               fragments))
           (result (ebox-surface--layer-paint-contributions "" fragments state)))
      (should roles)
      (should (equal-including-properties fragments before))
      (should (plist-get state :paint-property-contributions))
      (cl-mapc
       (lambda (input output text)
         (should (equal-including-properties (plist-get input :text) text))
         (should (plist-member input :old-paint-role-ids))
         (should-not (eq input output))
         (dolist (key '(:paint-role-ids :paint-address :paint-node-chain))
           (should (eq (plist-get input key) (plist-get output key))))
         (should (equal (plist-get input :face-baseline)
                        (plist-get output :face-baseline)))
         (should (plist-get output :face-baseline-known-p))
         (when (> (length (plist-get output :text)) 0)
           (should (equal (get-text-property 0 'face (plist-get output :text))
                          (plist-get input :face-baseline)))))
       fragments result before-text)
      (dolist (fragment result)
        (should-not (plist-member fragment :old-paint-role-ids))))))

(defun ebox-child-range-test--paint-owner-candidate (buffer title &optional ref color)
  "Return BUFFER's TITLE update and optional disjoint REF paint COLOR."
  (let ((candidate (ebox-candidate-begin buffer)))
    (ebox-candidate-replace-host-ref
     candidate 'title
     (ebox-test-text (propertize title 'face '(:weight bold))
                     :key 'title :source-identity 'title))
    (when ref
      (ebox-candidate-replace-host-ref
       candidate ref
       (ebox-test-box :key ref :source-identity ref :color color
         (ebox-test-text (symbol-name ref)))))
    candidate))

(ert-deftest ebox-child-range-paint-marker-consumption-isolates-disjoint-history ()
  "Mixed A, retained text, mixed B, and A publish only their current paint work."
  (with-temp-buffer
    (ebox-render-to-buffer
     (current-buffer) (ebox-child-range-test--snapshot-replacement-root))
    (ebox-commit
     (current-buffer)
     (ebox-child-range-test--replace-snapshot-detail (current-buffer) t))
    (let* ((surface ebox-surface--buffer-surface)
           (state (ebox--buffer-render-state (current-buffer)))
           (mounts (tp--surface-mounts surface))
           (mount-ids (mapcar #'tp--surface-mount-id mounts))
           (mount-index (tp--surface-mount-index surface))
           (ranges (plist-get state :surface-owned-ranges)))
      (dolist (step '(("title-2" row-1 "#224466") ("title-3")
                     ("title-4" row-2 "#446688") ("title-5" row-1 "#6688AA")))
        (let* ((ref (nth 1 step))
               (paint-object
                (and ref
                     (gethash (plist-get (ebox--host-ref-node (current-buffer) ref) :node-id)
                              (plist-get state :surface-node-object-table))))
               layers report
               (observer
                (lambda (_context _projection candidate-state _output &optional _kind)
                  (setq layers (copy-tree (plist-get candidate-state
                                                     :paint-property-contributions))))))
          (advice-add 'ebox-surface--projection-result :before observer)
          (unwind-protect
              (setq report
                    (ebox-commit
                     (current-buffer)
                     (apply #'ebox-child-range-test--paint-owner-candidate
                            (current-buffer) step)))
            (advice-remove 'ebox-surface--projection-result observer))
          (ebox-child-range-test--assert-full-render-equivalent (current-buffer))
          (should (eq (plist-get report :projection-kind)
                      (if ref 'mixed-owner-reflow 'owner-scoped)))
          (if (not ref)
              (should-not layers)
            (should layers)
            (let ((owned (tp-object-mounts paint-object)))
              (dolist (layer layers)
                (ert-info ((format "current owner %S layer %S mounts %S" ref layer owned))
                  (should
                   (cl-loop for offset from (plist-get layer :start)
                            below (plist-get layer :end)
                            always (cl-some
                                    (lambda (mount)
                                      (and (<= (plist-get mount :start) (1+ offset))
                                           (< (1+ offset) (plist-get mount :end))))
                                    owned)))))))
          (let ((next-state (ebox--buffer-render-state (current-buffer))))
            (dolist (fragment (ebox-surface--materialized-fragment-ledger next-state))
              (should-not (plist-member fragment :old-paint-role-ids)))
            (should (eq ranges (plist-get next-state :surface-owned-ranges))))
          (should (plist-get (tp-surface-report surface) :commit-batch))
          (should (plist-get (tp-surface-report surface) :retained-mount-state))
          (should (eq mounts (tp--surface-mounts surface)))
          (should (eq mount-index (tp--surface-mount-index surface)))
          (should (equal mount-ids (mapcar #'tp--surface-mount-id mounts))))))))

(ert-deftest ebox-child-range-paint-marker-consumption-rolls-back-and-retries ()
  "Rejected layering preserves its prior ledger exactly before a fresh retry."
  (with-temp-buffer
    (ebox-render-to-buffer
     (current-buffer) (ebox-child-range-test--snapshot-replacement-root))
    (ebox-commit
     (current-buffer)
     (ebox-child-range-test--replace-snapshot-detail (current-buffer) t))
    (dolist (step '(("title-2" row-1 "#224466") ("title-3")))
      (ebox-commit
       (current-buffer)
       (apply #'ebox-child-range-test--paint-owner-candidate (current-buffer) step)))
    (let* ((surface ebox-surface--buffer-surface)
           (state (ebox--buffer-render-state (current-buffer)))
           (revision (tp-surface-revision surface))
           (runtime-revision (plist-get state :runtime-revision))
           (ledger (plist-get state :surface-fragments))
           (ledger-before (copy-tree ledger))
           (ranges (plist-get state :surface-owned-ranges))
           (mounts (tp--surface-mounts surface))
           (mount-ids (mapcar #'tp--surface-mount-id mounts))
           (mount-index (tp--surface-mount-index surface))
           (index (tp--surface-index surface))
           (before (buffer-string)) (layer-calls 0) trace
           (observer (lambda (&rest _arguments) (cl-incf layer-calls))))
      (advice-add 'ebox-surface--layer-paint-contributions :after observer)
      (unwind-protect
          (should-error
           (ebox-commit
            (current-buffer)
            (ebox-child-range-test--paint-owner-candidate
             (current-buffer) "title-4" 'row-2 "#446688")
            (lambda (_report)
              (should (= layer-calls 1))
              (push 'publish trace)
              (error "reject consumed paint markers"))
            (lambda (_report) (push 'rollback trace))))
        (advice-remove 'ebox-surface--layer-paint-contributions observer))
      (should (= layer-calls 1))
      (should (equal trace '(rollback publish)))
      (should (eq state (ebox--buffer-render-state (current-buffer))))
      (should (eq state (tp-surface-client-state surface)))
      (should (= revision (tp-surface-revision surface)))
      (should (= runtime-revision (plist-get state :runtime-revision)))
      (should (eq ledger (plist-get state :surface-fragments)))
      (should (equal-including-properties ledger-before ledger))
      (should (eq ranges (plist-get state :surface-owned-ranges)))
      (should (eq mounts (tp--surface-mounts surface)))
      (should (eq mount-index (tp--surface-mount-index surface)))
      (should (eq index (tp--surface-index surface)))
      (should (equal mount-ids (mapcar #'tp--surface-mount-id mounts)))
      (should (equal-including-properties before (buffer-string)))
      (ebox-commit
       (current-buffer)
       (ebox-child-range-test--paint-owner-candidate
        (current-buffer) "title-4" 'row-2 "#446688"))
      (ebox-child-range-test--assert-full-render-equivalent (current-buffer))
      (should (= (1+ revision) (tp-surface-revision surface)))
      (should (plist-get (tp-surface-report surface) :retained-mount-state))
      (should (eq mounts (tp--surface-mounts surface)))
      (should (eq mount-index (tp--surface-mount-index surface)))
      (dolist (fragment (ebox-surface--materialized-fragment-ledger
                        (ebox--buffer-render-state (current-buffer))))
        (should-not (plist-member fragment :old-paint-role-ids))))))

(ert-deftest ebox-child-range-retained-kind-replacement-allows-mixed-followups ()
  "Later title and row paint edits remain local beside disjoint scrolling."
  (with-temp-buffer
    (ebox-render-to-buffer
     (current-buffer) (ebox-child-range-test--snapshot-replacement-root))
    (ebox--ensure-layout-snapshot-details
     (current-buffer)
     (plist-get (ebox--host-ref-node (current-buffer) 'detail) :node-id))
    (ebox-commit
     (current-buffer)
     (ebox-child-range-test--replace-snapshot-detail (current-buffer) t))
    (let* ((state (ebox--buffer-render-state (current-buffer)))
           (surface ebox-surface--buffer-surface)
           (mounts (tp--surface-mounts surface))
           (mount-ids (mapcar #'tp--surface-mount-id mounts))
           (mount-index (tp--surface-mount-index surface))
           (index (tp--surface-index surface))
           (ranges (plist-get state :surface-owned-ranges))
           (scroll-id (car (plist-get state :scroll-region-ids)))
           (scroll (gethash scroll-id ebox--scroll-global-state))
           (raw (plist-get scroll :content-lines))
           (rendered (plist-get scroll :rendered-content-lines))
           (identities
            (mapcar (lambda (ref)
                      (cons ref (plist-get (ebox--host-ref-node (current-buffer) ref)
                                           :node-id)))
                    '(row-1 row-2 detail title status scroll))))
      (should scroll-id)
      (should (= (length (plist-get state :scroll-region-ids)) 1))
      (dolist (selected '(2 1 2))
        (let* ((candidate
                (ebox-child-range-test--mixed-followup-candidate
                 (current-buffer) selected))
               (root-renders 0)
               (observer (lambda (&rest _arguments) (cl-incf root-renders)))
               report)
          (advice-add 'ebox-surface--render-candidate :before observer)
          (unwind-protect
              (setq report (ebox-commit (current-buffer) candidate))
            (advice-remove 'ebox-surface--render-candidate observer))
          (ebox-child-range-test--assert-full-render-equivalent (current-buffer))
          (dolist (entry identities)
            (should (= (cdr entry)
                       (plist-get (ebox--host-ref-node (current-buffer) (car entry))
                                  :node-id))))
          (ert-info ((format "selected=%S root-renders=%S report=%S"
                             selected root-renders report))
            (should (eq (plist-get report :projection-kind) 'mixed-owner-reflow))
            (should (zerop root-renders))
            (should-not (plist-get report :tp-full-root))
            (should (plist-get (tp-surface-report surface) :commit-batch))
            (should (plist-get (tp-surface-report surface) :retained-mount-state))
            (should (eq mounts (tp--surface-mounts surface)))
            (should (equal mount-ids
                           (mapcar #'tp--surface-mount-id
                                   (tp--surface-mounts surface))))
            (should (eq mount-index (tp--surface-mount-index surface)))
            (should (eq index (tp--surface-index surface)))
            (should (eq ranges
                        (plist-get (ebox--buffer-render-state (current-buffer))
                                   :surface-owned-ranges))))
          (let ((next-scroll (gethash scroll-id ebox--scroll-global-state)))
            (should (eq raw (plist-get next-scroll :content-lines)))
            (should (eq rendered (plist-get next-scroll :rendered-content-lines)))))))))

(ert-deftest ebox-child-range-mixed-followup-publish-failure-restores-and-retries ()
  "A failed public mixed commit restores the old generation before retry."
  (with-temp-buffer
    (ebox-render-to-buffer
     (current-buffer) (ebox-child-range-test--snapshot-replacement-root))
    (ebox--ensure-layout-snapshot-details
     (current-buffer)
     (plist-get (ebox--host-ref-node (current-buffer) 'detail) :node-id))
    (ebox-commit
     (current-buffer)
     (ebox-child-range-test--replace-snapshot-detail (current-buffer) t))
    (let* ((state (ebox--buffer-render-state (current-buffer)))
           (surface ebox-surface--buffer-surface)
           (revision (tp-surface-revision surface))
           (previous-report (tp-surface-report surface))
           (before (buffer-string))
           (mounts (tp--surface-mounts surface))
           (mount-ids (mapcar #'tp--surface-mount-id mounts))
           (mount-index (tp--surface-mount-index surface))
           (index (tp--surface-index surface))
           (ranges (plist-get state :surface-owned-ranges))
           (scroll-id (car (plist-get state :scroll-region-ids)))
           (scroll (gethash scroll-id ebox--scroll-global-state))
           trace)
      (should-error
       (ebox-commit
        (current-buffer)
        (ebox-child-range-test--mixed-followup-candidate (current-buffer) 2)
        (lambda (_report) (push 'publish trace) (error "reject mixed publication"))
        (lambda (_report) (push 'rollback trace))))
      (should (equal trace '(rollback publish)))
      (should (eq state (ebox--buffer-render-state (current-buffer))))
      (should (eq state (tp-surface-client-state surface)))
      (should (= revision (tp-surface-revision surface)))
      (should (eq ranges (plist-get state :surface-owned-ranges)))
      (should (eq mounts (tp--surface-mounts surface)))
      (should (equal mount-ids (mapcar #'tp--surface-mount-id mounts)))
      (should (eq mount-index (tp--surface-mount-index surface)))
      (should (eq index (tp--surface-index surface)))
      (should (eq scroll (gethash scroll-id ebox--scroll-global-state)))
      (should (equal-including-properties before (buffer-string)))
      (should (equal previous-report (tp-surface-report surface)))
      (let ((report
             (ebox-commit
              (current-buffer)
              (ebox-child-range-test--mixed-followup-candidate
               (current-buffer) 2))))
        (ebox-child-range-test--assert-full-render-equivalent (current-buffer))
        (should (= (1+ revision) (tp-surface-revision surface)))
        (should (eq (plist-get report :projection-kind) 'mixed-owner-reflow))
        (should-not (plist-get report :tp-full-root))
        (should (plist-get (tp-surface-report surface) :commit-batch))
        (should (plist-get (tp-surface-report surface) :retained-mount-state))
        (should (eq mounts (tp--surface-mounts surface)))
        (should (equal mount-ids (mapcar #'tp--surface-mount-id mounts)))
        (should (eq mount-index (tp--surface-mount-index surface)))
        (should (eq index (tp--surface-index surface)))
        (should (eq (plist-get scroll :content-lines)
                    (plist-get (gethash scroll-id ebox--scroll-global-state)
                               :content-lines)))))))

(ert-deftest ebox-child-range-mixed-followup-removes-face-without-contribution ()
  "A paint owner with no new face still publishes its baseline-only removal."
  (with-temp-buffer
    (ebox-render-to-buffer
     (current-buffer)
     (ebox-test-column :width '(200)
       (ebox-test-column :bgcolor "#DDE7EF"
         (ebox-test-text (propertize "title-1" 'face '(:weight bold))
                         :key 'title :source-identity 'title))
       (ebox-test-box :key 'row-1 :source-identity 'row-1 :color "#123456"
         (ebox-test-text (propertize "row-1" 'face '(:slant italic))))))
    (let* ((surface ebox-surface--buffer-surface)
           (mounts (tp--surface-mounts surface))
           (mount-index (tp--surface-mount-index surface))
           (candidate (ebox-candidate-begin (current-buffer)))
           (observed nil) (contributions 'not-observed)
           (observer
            (lambda (_context _projection state _output &optional kind)
              (when (eq kind 'mixed-owner-reflow)
                (setq observed t
                      contributions (plist-get state :paint-property-contributions)))))
           report)
      (ebox-candidate-replace-host-ref
       candidate 'title
       (ebox-test-text (propertize "title-2" 'face '(:weight bold))
                       :key 'title :source-identity 'title))
      (ebox-candidate-replace-host-ref
       candidate 'row-1
       (ebox-test-box :key 'row-1 :source-identity 'row-1
         (ebox-test-text (propertize "row-1" 'face '(:slant italic)))))
      (advice-add 'ebox-surface--projection-result :before observer)
      (unwind-protect
          (setq report (ebox-commit (current-buffer) candidate))
        (advice-remove 'ebox-surface--projection-result observer))
      (ebox-child-range-test--assert-full-render-equivalent (current-buffer))
      (should observed)
      (should-not contributions)
      (should (eq (plist-get report :projection-kind) 'mixed-owner-reflow))
      (should (equal (get-text-property (string-match "row-1" (buffer-string))
                                       'face (buffer-string))
                     '(:slant italic)))
      (should (plist-get (tp-surface-report surface) :commit-batch))
      (should (plist-get (tp-surface-report surface) :retained-mount-state))
      (should (eq mounts (tp--surface-mounts surface)))
      (should (eq mount-index (tp--surface-mount-index surface))))))

(ert-deftest ebox-child-range-mixed-followup-coordinate-change-keeps-fallback ()
  "A longer title cannot claim the stable-coordinate mount-reuse proof."
  (with-temp-buffer
    (ebox-render-to-buffer
     (current-buffer) (ebox-child-range-test--snapshot-replacement-root))
    (ebox-commit
     (current-buffer)
     (ebox-child-range-test--replace-snapshot-detail (current-buffer) t))
    (let ((extent (buffer-size)))
      (ebox-commit
       (current-buffer)
       (ebox-child-range-test--mixed-followup-candidate
        (current-buffer) 2 "title-2 with a longer extent"))
      (should-not (= extent (buffer-size))))
    (ebox-child-range-test--assert-full-render-equivalent (current-buffer))
    (should-not (plist-get (tp-surface-report ebox-surface--buffer-surface)
                           :retained-mount-state))))

(ert-deftest ebox-child-range-mixed-followup-patch-layers-require-complete-coverage ()
  "Ordered paint may cross adjacent patches, but cannot disappear into a gap."
  (let* ((baseline (propertize "abcdefgh" 'face 'bold 'help-echo "base"))
         (patches
          (mapcar (lambda (range)
                    (list :old-start (car range) :old-end (cdr range)
                          :new-start (car range) :new-end (cdr range)
                          :replacement (substring baseline (car range) (cdr range))))
                  '((0 . 2) (2 . 4) (6 . 8))))
         (before (copy-tree patches))
         (layers '((:start 0 :end 4 :props (face italic))
                   (:start 1 :end 3 :props (face nil help-echo nil))
                   (:start 6 :end 8 :props (face (:foreground "red")))))
         (mapped (ebox-surface--patch-property-contributions patches layers 8))
         (batch (tp-commit-batch-create
                 :base-revision 1 :target-revision 2 :base-extent 8 :target-extent 8
                 :patches mapped))
         (stored (tp-commit-batch-patches batch))
         (actual (concat (plist-get (nth 0 stored) :replacement)
                         (plist-get (nth 1 stored) :replacement)
                         (substring baseline 4 6)
                         (plist-get (nth 2 stored) :replacement))))
    (should (equal-including-properties
             actual (tp--compose-relative-property-contributions baseline layers)))
    (should (equal-including-properties before patches))
    (should-not (eq (car patches) (car mapped)))
    (should-not
     (ebox-surface--patch-property-contributions
      patches '((:start 1 :end 7 :props (face italic))) 8))
    (dolist (invalid '((:start -1 :end 1 :props (face bold))
                      (:start 0 :end 9 :props (face bold))
                      (:start 0 :end 1 :props (face))))
      (should-not
       (ebox-surface--patch-property-contributions patches (list invalid) 8)))
    (should
     (ebox-surface--patch-property-contributions
      patches '((:start 5 :end 5 :props (face bold))) 8))))

(ert-deftest ebox-child-range-mixed-followup-proof-misses-preserve-fallback ()
  "Missing ownership or paint coverage returns to exact retained-content work."
  (dolist (miss '(ownership coverage))
    (with-temp-buffer
      (ebox-render-to-buffer
       (current-buffer) (ebox-child-range-test--snapshot-replacement-root))
      (ebox-commit
       (current-buffer)
       (ebox-child-range-test--replace-snapshot-detail (current-buffer) t))
      (let* ((function (if (eq miss 'ownership)
                           'ebox-surface--span-patch-output
                         'ebox-surface--patch-property-contributions))
             observed
             (observer
              (lambda (original &rest arguments)
                (setq observed t)
                (when (eq miss 'ownership)
                  (prog1 (apply original arguments)
                    (cl-remf (nth 2 arguments) :span-patch-retained-owned-ranges))))))
        (advice-add function :around observer)
        (unwind-protect
            (ebox-commit
             (current-buffer)
             (ebox-child-range-test--mixed-followup-candidate (current-buffer) 2))
          (advice-remove function observer))
        (should observed)
        (ebox-child-range-test--assert-full-render-equivalent (current-buffer))
        (should-not (plist-get (tp-surface-report ebox-surface--buffer-surface)
                               :retained-mount-state))))))

(ert-deftest ebox-child-range-mixed-followup-merger-errors-escape-proof-fallback ()
  "Even a constructor-like merger error propagates once and preserves state."
  (with-temp-buffer
    (ebox-render-to-buffer
     (current-buffer) (ebox-child-range-test--snapshot-replacement-root))
    (ebox-commit
     (current-buffer)
     (ebox-child-range-test--replace-snapshot-detail (current-buffer) t))
    (let* ((surface ebox-surface--buffer-surface)
           (state (ebox--buffer-render-state (current-buffer)))
           (revision (tp-surface-revision surface))
           (mounts (tp--surface-mounts surface))
           (index (tp--surface-mount-index surface))
           (before (buffer-string))
           (merge-calls 0) (contributed-batches 0) contributed-face
           (observer
            (lambda (original &rest arguments)
              (let* ((patches (mapcar #'copy-sequence (plist-get arguments :patches)))
                     (patch (cl-find-if
                             (lambda (entry) (plist-get entry :property-contributions))
                             patches)))
                (when patch
                  ;; Exception-boundary fixture: TP merges only over a present
                  ;; baseline property.  Keep Ebox's actual generated layers,
                  ;; adding a baseline only to a detached constructor argument.
                  ;; Inline row faces would change the fixture's geometry proof.
                  (let* ((layer (car (plist-get patch :property-contributions)))
                         (start (plist-get layer :start))
                         (replacement (copy-sequence (plist-get patch :replacement))))
                    (should (< start (plist-get layer :end)))
                    (setq contributed-face (plist-get (plist-get layer :props) 'face))
                    (should contributed-face)
                    (put-text-property start (1+ start) 'face '(:slant italic) replacement)
                    (plist-put patch :replacement replacement)
                    (setq arguments (plist-put (copy-sequence arguments) :patches patches))
                    (cl-incf contributed-batches)))
                (apply original arguments)))))
      (let ((tp--property-policies (copy-hash-table tp--property-policies))
            (tp--property-policy-order (copy-sequence tp--property-policy-order)))
        (tp-define-property-policy
         (tp-text-property-id 'face)
         :projector (tp-property-policy-projector
                     (tp-property-policy (tp-text-property-id 'face)))
         :merge (lambda (old new)
                  (should (equal old '(:slant italic)))
                  (should (equal new contributed-face))
                  (cl-incf merge-calls)
                  (signal 'tp-surface-error '(:commit-patch merger-failure))))
        (advice-add 'tp-commit-batch-create :around observer)
        (unwind-protect
            (let ((condition
                   (should-error
                    (ebox-commit
                     (current-buffer)
                     (ebox-child-range-test--mixed-followup-candidate
                      (current-buffer) 2))
                    :type 'tp-surface-error)))
              (should (equal (seq-take condition 3)
                             '(tp-surface-error :commit-patch merger-failure))))
          (advice-remove 'tp-commit-batch-create observer)))
      (should (= contributed-batches 1))
      (should (= merge-calls 1))
      (should (= revision (tp-surface-revision surface)))
      (should (eq state (tp-surface-client-state surface)))
      (should (eq state (ebox--buffer-render-state (current-buffer))))
      (should (eq mounts (tp--surface-mounts surface)))
      (should (eq index (tp--surface-mount-index surface)))
      (should (equal-including-properties before (buffer-string)))
      (ebox-commit
       (current-buffer)
       (ebox-child-range-test--mixed-followup-candidate (current-buffer) 2))
      (ebox-child-range-test--assert-full-render-equivalent (current-buffer))
      (should (plist-get (tp-surface-report surface) :retained-mount-state)))))

(ert-deftest ebox-child-range-mixed-followup-role-change-keeps-fallback ()
  "Replacing text with a new box role cannot reuse the old mount topology."
  (with-temp-buffer
    (ebox-render-to-buffer
     (current-buffer) (ebox-child-range-test--snapshot-replacement-root))
    (ebox-commit
     (current-buffer)
     (ebox-child-range-test--replace-snapshot-detail (current-buffer) t))
    (let ((candidate
           (ebox-child-range-test--mixed-followup-candidate (current-buffer) 2)))
      (ebox-candidate-replace-host-ref
       candidate 'title
       (ebox-test-box :key 'title :source-identity 'title
         (ebox-test-text (propertize "title-2" 'face '(:weight bold)))))
      (ebox-commit (current-buffer) candidate))
    (ebox-child-range-test--assert-full-render-equivalent (current-buffer))
    (should-not (plist-get (tp-surface-report ebox-surface--buffer-surface)
                           :retained-mount-state))))

(ert-deftest ebox-child-range-does-not-reuse-disappeared-key-positionally ()
  "A new keyed item must not inherit a removed peer's runtime identity."
  (let ((buffer (generate-new-buffer " *ebox-range-key-reentry*")))
    (cl-labels
        ((rows (keys)
           (mapcar (lambda (key)
                     (ebox-test-box :key key
                                  (ebox-test-text (format "row-%s" key))))
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
                                        (ebox-child-range-test--node-key
                                         item
                                         (plist-get state
                                                    :source-index))))))
             (plist-get node :node-id))))
      (unwind-protect
          (progn
            (ebox-render-to-buffer
             buffer
             (ebox-test-column
              (apply #'ebox-test-child-range 'items (rows '(1 2 3 4)))))
            (let ((initial-1 (row-id 1))
                  (initial-4 (row-id 4)))
              (let ((candidate (ebox-candidate-begin buffer)))
                (ebox-candidate-replace-range-ref
                 candidate 'items
                 (ebox-child-range-test--input (rows '(1 4))))
                (ebox-commit buffer candidate))
              (let ((candidate (ebox-candidate-begin buffer)))
                (ebox-candidate-replace-range-ref
                 candidate 'items
                 (ebox-child-range-test--input (rows '(1 2 3 4))))
                (ebox-commit buffer candidate))
              (should (= initial-1 (row-id 1)))
              (should (= initial-4 (row-id 4)))
              (should-not (= initial-4 (row-id 2)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest ebox-child-range-sole-child-keeps-public-layout-parent ()
  "Keep row/column material parents for one empty or populated Range."
  (dolist (case '((ebox-test-row row) (ebox-test-column column)))
    (dolist (items (list nil (list (ebox-test-box :key 'one (ebox-test-text "1")))))
      (let* ((range (apply #'ebox-test-child-range 'items items))
             (parent-input (funcall (car case) range))
             (parent (ebox-test-root parent-input)))
        (should-not (ebox-child-range--descriptor-p parent))
        (should (ebox-box-node-p parent))
        (should (eq (ebox-layout-config-kind (ebox-box-node-layout parent))
                    (cadr case)))
        (should (equal (ebox-box-node-children parent)
                       (mapcar #'ebox-test-root items)))
        (should (equal (ebox-box-node-range-anchors parent)
                       (list (list :ref 'items :before 0
                                   :after (length items)))))
        (should (stringp (ebox-render parent-input)))))))

(ert-deftest ebox-child-range-typed-box-preserves-transparent-range ()
  "Typed Box should retain Range identity outside its visual child model."
  (let* ((before (ebox-test-text "before" :key 'before))
         (first (ebox-test-text "A" :key 'first))
         (second (ebox-test-text "B" :key 'second))
         (after (ebox-test-text "after" :key 'after))
         (range (ebox-test-child-range 'items first second))
         (range-items (ebox-child-range--descriptor-items range))
         (box-input (ebox-test-column before range after))
         (box (ebox-test-root box-input))
         (buffer (generate-new-buffer " *ebox-typed-range*")))
    (unwind-protect
        (progn
          (should (equal (ebox-box-node-children box)
                         (mapcar #'ebox-test-root
                                 (list before first second after))))
          (cl-mapc (lambda (actual expected)
                     (should (eq actual expected)))
                   (ebox-box-node-children box)
                   (mapcar #'ebox-test-root
                           (list before (car range-items)
                                 (cadr range-items) after)))
          (should (equal (ebox-box-node-range-anchors box)
                         '((:ref items :before 1 :after 3))))
          (let* ((empty (ebox-test-child-range 'empty))
                 (empty-input (ebox-test-column before empty after))
                 (empty-box (ebox-test-root empty-input)))
            (should (equal (ebox-box-node-children empty-box)
                           (mapcar #'ebox-test-root (list before after))))
            (should (equal (ebox-box-node-range-anchors empty-box)
                           '((:ref empty :before 1 :after 1)))))
          (should
           (equal
            (mapcar (lambda (line)
                      (string-trim-right (substring-no-properties line)))
                    (ebox-string-lines (ebox-render box-input)))
            '("before" "A" "B" "after")))
          (ebox-render-to-buffer buffer box-input)
          (let* ((runtime-root (ebox--buffer-root-node buffer))
                 (snapshot
                  (ebox-tree-runtime-identity-snapshot runtime-root)))
            (should (= (plist-get snapshot :node-count) 5))
            (should (= (length (plist-get
                                (plist-get snapshot :root) :children))
                       4)))
          (let ((candidate (ebox-candidate-begin buffer)))
            (ebox-candidate-replace-range-ref
             candidate 'items
             (ebox-child-range-test--input
              (list (ebox-test-text "C" :key 'replacement))))
            (ebox-commit buffer candidate))
          (should
           (equal
            (with-current-buffer buffer
              (mapcar (lambda (line)
                        (string-trim-right
                         (substring-no-properties line)))
                      (ebox-string-lines (buffer-string))))
            '("before" "C" "after")))
          (let ((before-style-state (ebox--buffer-render-state buffer))
                (before-style-text
                 (with-current-buffer buffer (buffer-string)))
                (candidate (ebox-candidate-begin buffer)))
             (ebox-candidate-replace-range-ref
              candidate 'items
              (ebox-child-range-test--input
              (list (ebox-test-text "B" :color "red"))))
            (cl-letf (((symbol-function 'accept-change-group)
                       (lambda (_group) (error "reject styled Range"))))
              (should-error (ebox-commit buffer candidate) :type 'error))
            (should (eq before-style-state
                        (ebox--buffer-render-state buffer)))
            (should (equal before-style-text
                           (with-current-buffer buffer (buffer-string)))))
          (let ((candidate (ebox-candidate-begin buffer)))
            (ebox-candidate-replace-range-ref
             candidate 'items
             (ebox-child-range-test--input
              (list (ebox-test-text "B" :color "red"))))
            (ebox-commit buffer candidate))
          (let* ((state (ebox--buffer-render-state buffer))
                 (root (plist-get state :root-node))
                 (rendered (with-current-buffer buffer (buffer-string)))
                 (position (let ((case-fold-search nil))
                             (string-match "B" rendered)))
                 (face (and position
                            (get-text-property position 'face rendered))))
            (should (zerop (ebox-tree-author-style-count root)))
            (should-not (plist-get state :cascade-required-p))
            (should
             (or (and (listp face)
                      (keywordp (car face))
                      (equal (plist-get face :foreground) "red"))
                 (cl-some (lambda (entry)
                            (and (listp entry)
                                 (equal (plist-get entry :foreground) "red")))
                          face))))
          (let ((candidate (ebox-candidate-begin buffer)))
            (ebox-candidate-replace-range-ref
             candidate 'items
             (ebox-child-range-test--input
              (list (ebox-test-text "D" :key 'unstyled))))
            (ebox-commit buffer candidate))
          (let* ((state (ebox--buffer-render-state buffer))
                 (root (plist-get state :root-node))
                 (rendered (with-current-buffer buffer (buffer-string)))
                 (position (string-match "D" rendered))
                 (face (and position
                            (get-text-property position 'face rendered))))
            (should (zerop (ebox-tree-author-style-count root)))
            (should-not
             (or (and (listp face)
                      (keywordp (car face))
                      (equal (plist-get face :foreground) "red"))
                 (cl-some (lambda (entry)
                            (and (listp entry)
                                 (equal (plist-get entry :foreground) "red")))
                          face))))
          (let ((before-invalid
                 (with-current-buffer buffer (buffer-string)))
                (candidate (ebox-candidate-begin buffer)))
            (should-error
             (ebox-candidate-replace-range-ref
              candidate 'items
              (list (list :ebox-type 'box :content "legacy")))
             :type 'error)
            (should (equal before-invalid
                           (with-current-buffer buffer (buffer-string))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-child-range-typed-render-reuses-material-child-list ()
  "Typed Range rendering should not repeatedly flatten its child sequence."
  (let* ((items
          (cl-loop for index below 100
                   collect (ebox-test-text
                            (number-to-string index) :key index)))
         (range (apply #'ebox-test-child-range 'items items))
         (box-input (ebox-test-column range))
         (box (ebox-test-root box-input))
         (original (symbol-function 'ebox-child-range--flatten))
         (calls 0))
    (cl-letf (((symbol-function 'ebox-child-range--flatten)
               (lambda (sequence)
                 (cl-incf calls)
                 (funcall original sequence))))
      (ebox-render box-input))
    (should (zerop calls))
    (let* ((replacement-input
            (ebox-test-text "replacement" :key 'new))
           (replacement (ebox-test-root replacement-input))
           (source-index
            (ebox-test-source-index
             (ebox-test-forest-input box-input replacement-input)))
           (updated
            (car
             (ebox-child-range--replace
              (plist-get box :ebox-child-sequence)
              'items (list replacement)
              (lambda (node)
                (ebox-child-range-test--node-key node source-index)))))
           (candidate (copy-sequence box)))
      (ebox-tree--put-child-sequence candidate updated)
      (setq calls 0)
      (cl-letf (((symbol-function 'ebox-child-range--flatten)
                 (lambda (sequence)
                   (cl-incf calls)
                   (funcall original sequence))))
        (ebox-tree-subject-index candidate source-index)
        (ebox-tree-layout-children candidate))
      (should (= calls 1)))))

(ert-deftest ebox-child-range-empty-owner-falls-back-atomically ()
  "Publish empty sole Range through full surface fallback and rollback safely."
  (let ((buffer (generate-new-buffer " *ebox-empty-range-owner*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer buffer
                                 (ebox-test-column (ebox-test-child-range 'items)))
          (let ((candidate (ebox-candidate-begin buffer)))
            (ebox-candidate-replace-range-ref
             candidate 'items
             (ebox-child-range-test--input
              (list (ebox-test-box :key 'one (ebox-test-text "1")))))
            (cl-letf (((symbol-function 'accept-change-group)
                       (lambda (&rest _) (error "injected empty accept"))))
              (should-error (ebox-commit buffer candidate) :type 'error)))
          (should (equal "" (with-current-buffer buffer (buffer-string))))
          (let ((candidate (ebox-candidate-begin buffer)))
            (ebox-candidate-replace-range-ref
             candidate 'items
             (ebox-child-range-test--input
              (list (ebox-test-box :key 'one (ebox-test-text "1")))))
            (let ((report (ebox-commit buffer candidate)))
              (should (plist-get report :empty-range-owner-fallback))))
          (should (string-match-p "1" (with-current-buffer buffer
                                        (buffer-string))))
          (let ((candidate (ebox-candidate-begin buffer)))
            (ebox-candidate-replace-range-ref
             candidate 'items (ebox-test-forest-input))
            (ebox-commit buffer candidate))
          (should (equal "" (with-current-buffer buffer (buffer-string)))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-child-range-candidate-derivation-never-flattens-parent ()
  "Range logical-root and local-index derivation never flatten parent payloads."
  (let* ((buffer (generate-new-buffer " *ebox-range-no-flatten*"))
         (static
          (cl-loop for index below 100
                   collect (ebox-test-box :key (format "static-%d" index)
                                        (ebox-test-text (number-to-string index)))))
         (root (apply #'ebox-test-column
                      (append static
                              (list (ebox-test-child-range
                                     'items
                                     (ebox-test-box :key 'old (ebox-test-text "old")))))))
         candidate logical trace deltas)
    (unwind-protect
        (progn
          (ebox-render-to-buffer buffer root)
          (setq candidate (ebox-candidate-begin buffer))
          (ebox-candidate-replace-range-ref
           candidate 'items
           (ebox-child-range-test--input
            (list (ebox-test-box :key 'new (ebox-test-text "new")))))
          (setq trace (make-hash-table :test 'equal))
          (cl-letf (((symbol-function 'ebox-child-range--flatten)
                     (lambda (&rest _) (error "candidate flattened Range"))))
            (let ((ebox-incremental--candidate-path-copy-trace trace)
                  (ebox-incremental--candidate-range-index-deltas nil)
                  (ebox-incremental--candidate-incoming-source-indexes
                   (ebox-incremental--candidate-source-input-map candidate)))
              (setq logical
                    (ebox-incremental--candidate-logical-root candidate nil)
                    deltas ebox-incremental--candidate-range-index-deltas)
              (ebox-incremental--candidate-local-index-delta
               (ebox-candidate--base-state candidate) logical trace deltas)))
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
            (ebox-test-column
             (ebox-test-child-range
              'left (ebox-test-box :key 'move (ebox-test-text "L")))
             (ebox-test-child-range
              'right (ebox-test-box :key 'stay (ebox-test-text "R")))))
          (let ((candidate (ebox-candidate-begin buffer)))
            (ebox-candidate-replace-range-ref
             candidate 'left (ebox-test-forest-input))
            (ebox-candidate-replace-range-ref
             candidate 'right
             (ebox-child-range-test--input
              (list (ebox-test-box :key 'move (ebox-test-text "M"))
                    (ebox-test-box :key 'stay (ebox-test-text "R")))))
            (ebox-commit buffer candidate))
          (should (string-match-p "M" (with-current-buffer buffer
                                          (buffer-string)))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-child-range-public-gate-a-and-prepared-index ()
  "Public Range commits retain logarithmic metrics and a prepared local index."
  (dolist (static-count '(10 100 500))
    (let* ((buffer (generate-new-buffer " *ebox-range-public-gate*"))
           (root
            (apply #'ebox-test-column
                   (append
                    (cl-loop for index below static-count
                             collect (ebox-test-box :key (format "static-%d" index)
                                                  (ebox-test-text "s")))
                    (list (ebox-test-child-range
                           'items (ebox-test-box :key 'old (ebox-test-text "o"))))))))
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
               (ebox-child-range-test--input
                (list (ebox-test-box :key 'new-a (ebox-test-text "a"))
                      (ebox-test-box :key 'new-b (ebox-test-text "b")))))
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
            (ebox-test-column (ebox-test-box :key 'a :source-identity 'a (ebox-test-text "a"))
                         (ebox-test-box :key 'b (ebox-test-text "b"))))
          (let ((candidate (ebox-candidate-begin buffer)))
            (ebox-candidate-replace-host-ref
             candidate 'a
             (ebox-test-column
              (ebox-test-box :key 'a :source-identity 'a (ebox-test-text "a"))
              (ebox-test-child-range 'introduced)))
            (should-error
             (ebox-candidate-replace-range-ref
              candidate 'introduced (ebox-test-forest-input)))
            (ebox-commit buffer candidate))
          (let ((candidate (ebox-candidate-begin buffer)))
            (ebox-candidate-replace-range-ref
             candidate 'introduced
             (ebox-child-range-test--input
              (list (ebox-test-box :key 'later (ebox-test-text "later")))))
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
              (ebox-test-column
               (ebox-test-column
                :source-identity 'parent
                (ebox-test-box :key 'static (ebox-test-text "s"))
                (ebox-test-child-range
                 'items (ebox-test-box :key 'child :source-identity 'child
                                       (ebox-test-text "old"))))
               (ebox-test-box :key 'peer (ebox-test-text "peer"))))
            (let ((candidate (ebox-candidate-begin buffer)))
              (dolist (operation (if (eq order 'host-first)
                                     '(host range) '(range host)))
                (pcase operation
                  ('host
                   (ebox-candidate-replace-host-ref
                    candidate 'parent
                    (ebox-test-box :key 'parent-new (ebox-test-text "HOST-WINS"))))
                  ('range
                   (ebox-candidate-replace-range-ref
                    candidate 'items
                    (ebox-child-range-test--input
                     (list (ebox-test-box :key 'range-new
                                          (ebox-test-text "range-loses"))))))))
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
            (ebox-test-column
             (ebox-test-box :key 'static (ebox-test-text "s"))
             (ebox-test-child-range
              'items (ebox-test-box :key 'child :source-identity 'child (ebox-test-text "0")))))
          (dotimes (turn 2)
            (let ((candidate (ebox-candidate-begin buffer)))
              (ebox-candidate-replace-host-ref
               candidate 'child
               (ebox-test-box :key 'child :source-identity 'child
                            (ebox-test-text (number-to-string (1+ turn)))))
              (ebox-commit buffer candidate))
            (let* ((state (ebox--buffer-render-state buffer))
                   (current-id
                    (gethash 'child
                             (ebox-child-range-test--host-ref-table state)))
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
            (ebox-test-column
             (ebox-test-column
              :source-identity 'parent
              (ebox-test-box :key 'static (ebox-test-text "s"))
              (ebox-test-child-range
               'items (ebox-test-box :key 'child :source-identity 'child
                                     (ebox-test-text "old"))))
             (ebox-test-box :key 'peer (ebox-test-text "peer"))))
          (let ((candidate (ebox-candidate-begin buffer)))
            (ebox-candidate-replace-host-ref
             candidate 'parent
             (ebox-test-column
              :source-identity 'parent
              (ebox-test-box :key 'static (ebox-test-text "s2"))
              (ebox-test-child-range
               'items (ebox-test-box :key 'child :source-identity 'child
                                     (ebox-test-text "ancestor")))))
            (ebox-candidate-replace-range-ref
             candidate 'items
             (ebox-child-range-test--input
              (list (ebox-test-box :key 'range (ebox-test-text "RANGE-LOSES")))))
            (ebox-candidate-replace-host-ref
             candidate 'child
             (ebox-test-box :key 'child :source-identity 'child
                          (ebox-test-text "DESCENDANT-WINS")))
            (ebox-commit buffer candidate))
          (let ((text (with-current-buffer buffer (buffer-string))))
            (should (string-match-p "DESCENDANT-WINS" text))
            (should-not (string-match-p "RANGE-LOSES" text))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-child-range-large-payload-never-promotes-to-full-index ()
  "M=64 remains an affected-payload local delta under 500 static segments."
  (let* ((buffer (generate-new-buffer " *ebox-range-large-payload*"))
         (root
          (apply #'ebox-test-column
                 (append
                  (cl-loop for index below 500
                           collect (ebox-test-box :key (format "static-%d" index)
                                                (ebox-test-text "s")))
                  (list (ebox-test-child-range 'items)))))
         report)
    (unwind-protect
        (progn
          (ebox-render-to-buffer buffer root)
          (let ((candidate (ebox-candidate-begin buffer)))
            (ebox-candidate-replace-range-ref
             candidate 'items
             (ebox-child-range-test--input
              (cl-loop for index below 64
                       collect (ebox-test-box :key (format "new-%d" index)
                                              (ebox-test-text "n")))))
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
              (ebox-test-column
               (ebox-test-box :key 'static (ebox-test-text "s"))
               (ebox-test-child-range
                'items (ebox-test-box :key 'child :source-identity 'child
                                    (ebox-test-text "old")))))
            (let ((candidate (ebox-candidate-begin buffer)))
              (dolist (operation (if (eq order 'host-first)
                                     '(host range) '(range host)))
                (if (eq operation 'host)
                    (ebox-candidate-replace-host-ref
                     candidate 'child
                     (ebox-test-box :key 'child :source-identity 'child
                                  (ebox-test-text "HOST-LOSES")))
                  (ebox-candidate-replace-range-ref
                   candidate 'items
                   (ebox-child-range-test--input
                    (list (ebox-test-box :key 'range
                                         (ebox-test-text "RANGE-WINS")))))))
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
                      (ebox-test-column
                       :key 'child :source-identity 'child
                       (ebox-test-box :key 'child-static (ebox-test-text static-text))
                       (if range-key
                           (ebox-test-child-range
                            range-ref
                            (ebox-test-box :key range-key (ebox-test-text range-text)))
                         (ebox-test-child-range range-ref)))))
                 node))
             (ancestor (child-node peer-text)
               (let ((node
                      (ebox-test-column
                       :key 'ancestor :source-identity 'ancestor
                       child-node
                       (ebox-test-box :key 'ancestor-peer (ebox-test-text peer-text)))))
                 node)))
          (ebox-render-to-buffer
              buffer
            (ebox-test-column
             (ancestor (child "s" 'old-ref nil nil) "p")
             (ebox-test-box :key 'root-peer (ebox-test-text "r"))))
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
                 (child-id
                  (gethash 'child
                           (ebox-child-range-test--host-ref-table state))))
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
            (ebox-test-column
             (ebox-test-box :key 'host :source-identity 'host (ebox-test-text "old-host"))
             (ebox-test-child-range
              'items (ebox-test-box :key 'old-range (ebox-test-text "old-range")))))
          (let* ((surface (with-current-buffer buffer ebox-surface--buffer-surface))
                 (revision (tp-surface-revision surface))
                 (candidate (ebox-candidate-begin buffer))
                 report)
            (ebox-candidate-replace-host-ref
             candidate 'host
             (ebox-test-box :key 'host :source-identity 'host (ebox-test-text "new-host")))
            (ebox-candidate-replace-range-ref
             candidate 'items
             (ebox-child-range-test--input
              (list (ebox-test-box :key 'new-range (ebox-test-text "new-range")))))
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
            (ebox-test-column
             (ebox-test-box :key 'static (ebox-test-text "s"))
             (ebox-test-child-range
              'items (ebox-test-box :key 'old :source-identity 'old (ebox-test-text "old")))))
          (let* ((old-state (ebox--buffer-render-state buffer))
                 (old-root (plist-get old-state :root-node))
                 (old-table (plist-get old-state :range-ref-table))
                 (old-id
                  (gethash 'old
                           (ebox-child-range-test--host-ref-table old-state)))
                 (old-buffer (with-current-buffer buffer (buffer-string)))
                 (candidate (ebox-candidate-begin buffer)))
            (ebox-candidate-replace-range-ref
             candidate 'items
             (ebox-child-range-test--input
              (list (ebox-test-box :key 'new :source-identity 'new
                                   (ebox-test-text "new"))))
             nil t)
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
            (should (= (gethash
                        'old (ebox-child-range-test--host-ref-table old-state))
                       old-id))
            (should (equal (with-current-buffer buffer (buffer-string))
                           old-buffer)))
          (let ((candidate (ebox-candidate-begin buffer)))
            (ebox-candidate-replace-range-ref
             candidate 'items
             (ebox-child-range-test--input
              (list (ebox-test-box :key 'new (ebox-test-text "new")))))
            (ebox-commit buffer candidate)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-child-range-framework-failure-rolls-back-and-retries ()
  "A failed framework publish restores the exact old Range generation."
  (let ((buffer (generate-new-buffer " *ebox-range-rollback*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer
              buffer
            (ebox-test-column
             (ebox-test-box :key 'static (ebox-test-text "s"))
             (ebox-test-child-range
              'items (ebox-test-box :key 'old (ebox-test-text "old")))))
          (let* ((old-state (ebox--buffer-render-state buffer))
                 (old-root (plist-get old-state :root-node))
                 (old-range-table (plist-get old-state :range-ref-table))
                 (old-buffer (with-current-buffer buffer (buffer-string)))
                 (candidate (ebox-candidate-begin buffer))
                 trace)
            (ebox-candidate-replace-range-ref
             candidate 'items
             (ebox-child-range-test--input
              (list (ebox-test-box :key 'new (ebox-test-text "new")))))
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
             (ebox-child-range-test--input
              (list (ebox-test-box :key 'new (ebox-test-text "new")))))
            (ebox-commit buffer candidate))
          (should (string-match-p "new" (with-current-buffer buffer
                                            (buffer-string)))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(provide 'ebox-child-range-tests)
;;; ebox-child-range-tests.el ends here
