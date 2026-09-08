;;; ebox-flex-tests.el --- Ebox flex layout tests -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)

(load-file (expand-file-name "../ebox.el" (file-name-directory (or load-file-name buffer-file-name))))
(require 'ebox-native-reflow)

(defun ebox-flex-test--render (node)
  "Render NODE once for flex tests."
  (ebox-render node))

(ert-deftest ebox-flex-resolved-constraints-preserve-pixels-and-unbounded-width ()
  "Resolved constraints do not reapply author units or ambient defaults."
  (let ((ebox-viewport-width 300)
        (config (ebox-layout-config-props (ebox-flex-layout-create))))
    (cl-letf (((symbol-function 'ebox--space-pixel-width) (lambda () 7)))
      (should (= (ebox--string-max-pixel-width
                  (ebox--render-flex-children
                   config '(:width 50 :height nil) '("X")))
                 50))
      (should (= (ebox--string-max-pixel-width
                  (ebox--render-flex-children
                   config '(:width nil :height nil) '("X")))
                 (ebox--string-pixel-width "X")))
      ;; The private legacy adapter still supplies its omitted-width default.
      (should (= (ebox--string-max-pixel-width
                  (ebox--render-flex
                   (list :ebox-type 'flex :props config :children '("X"))))
                 300)))))

(defun ebox-flex-test--intrinsic-toolbar (color &optional grow)
  "Return a nested max-content Flex using COLOR and optional GROW."
  (ebox-test-flex :width '(240) :flex-wrap 'wrap
    (ebox-test-column :width '(40) :flex-grow (if grow 0 1)
      (ebox-test-text "Title"))
    (ebox-test-flex :id "toolbar" :width 'max-content
                   :padding '(0 (3)) :margin '(0 (4))
                   :column-gap '(2) :justify-content 'space-between
                   :flex-grow (if grow 1 0) :bgcolor color
      (ebox-test-box :width '(20) (ebox-test-text "A"))
      (ebox-test-box :width '(30) (ebox-test-text "B")))))

(ert-deftest ebox-flex-nested-max-content-survives-paint-and-fresh-render ()
  "A paint change preserves the same single-line intrinsic Flex geometry."
  (let* ((ebox-viewport-width 240)
         (layout (ebox-flex-test--intrinsic-toolbar "white"))
         (buffer (generate-new-buffer " *ebox-intrinsic-toolbar*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer buffer layout)
          (dolist (color '("white" "black" "white"))
            (ebox-region-update (ebox-region-resolve buffer "toolbar")
                                :bgcolor color)
            (let ((retained (with-current-buffer buffer (buffer-string)))
                  (fresh (ebox-render
                          (ebox-flex-test--intrinsic-toolbar color))))
              (dolist (rendered (list retained fresh))
                (should (= (ebox-string-height rendered) 1))
                (should (= (ebox--string-max-pixel-width rendered) 240))
                ;; 174px title + 4px margin + 3px padding, counted once.
                (should (= (ebox--string-pixel-width
                            (substring rendered 0 (string-match "A" rendered)))
                           181)))
              (should (equal (substring-no-properties retained)
                             (substring-no-properties fresh))))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-flex-max-content-respects-parent-allocation ()
  "Intrinsic measurement does not discard a later definite Flex allocation."
  (let* ((ebox-viewport-width 240)
         (rendered (ebox-render
                    (ebox-flex-test--intrinsic-toolbar "white" t))))
    (should (= (ebox-string-height rendered) 1))
    (should (= (ebox--string-max-pixel-width rendered) 240))
    (should (= (ebox--string-pixel-width
                (substring rendered 0 (string-match "A" rendered)))
               47))
    (should (= (ebox--string-pixel-width
                (substring rendered 0 (string-match "B" rendered)))
               203))))

(ert-deftest ebox-flex-unbounded-constraint-reaches-nested-auto-flex ()
  "An auto Flex inside max-content must not recover the outer viewport."
  (let* ((ebox-viewport-width 300)
         (layout
          (ebox-test-flex :width 'max-content
            (ebox-test-flex
              (ebox-test-box :width '(20) (ebox-test-text "A"))
              (ebox-test-box :width '(30) (ebox-test-text "B"))))))
    (should (= (ebox--string-max-pixel-width (ebox-render layout)) 50))))

(ert-deftest ebox-flex-padded-lazy-children-use-content-viewport ()
  "Lazy responsive Flex items use the same content viewport as full layout."
  (let* ((ebox-viewport-width 300)
         (ebox-viewport-height 5)
         (layout
          (ebox-test-column :width '(viewport) :height '(viewport-height)
            (ebox-test-flex :width 'stretch :padding '(0 (10))
                           :flex-wrap 'wrap
              (ebox-test-flex :width 'stretch :wrap-mode 'none
                (ebox-test-box :width '(20) (ebox-test-text "A"))
                (ebox-test-box :width '(30) (ebox-test-text "B"))))))
         (_ (ebox-region-ids (ebox-test-root layout)))
         (eager (let ((ebox--scroll-window-render-disabled t))
                  (ebox-render layout)))
         (original (symbol-function 'ebox--render-flex-window-lines))
         (lazy-renders 0)
         lazy)
    (cl-letf (((symbol-function 'ebox--render-flex-window-lines)
               (lambda (node limit)
                 (let ((result (funcall original node limit)))
                   (when result (cl-incf lazy-renders))
                   result))))
      (setq lazy (ebox-render layout)))
    (should (> lazy-renders 0))
    (should (= (ebox--string-max-pixel-width eager) 300))
    (should (= (ebox--string-max-pixel-width lazy) 300))
    (should (equal-including-properties lazy eager))))

(ert-deftest ebox-flex-normalized-gap-keeps-pixels-on-wide-fonts ()
  "Flex gaps convert character units once and preserve explicit pixel units."
  (cl-letf (((symbol-function 'ebox--space-pixel-width) (lambda () 7)))
    (dolist (case '((2 . 14) ((2) . 2)))
      (let* ((layout
              (ebox-test-flex :width '(100) :column-gap (car case)
                (ebox-test-text "A")
                (ebox-test-text "B")))
             (rendered (ebox-render layout))
             (left (string-match "A" rendered))
             (right (string-match "B" rendered)))
        (should left)
        (should right)
        (should (= (ebox--string-pixel-width
                    (substring rendered (1+ left) right))
                   (cdr case)))
        (should
         (= (plist-get
             (ebox-native-reflow--compile-flex-inner
              (ebox-layout-config-props
               (ebox-box-node-layout (ebox-test-root layout))) nil)
             :column-gap)
            (cdr case)))))))

(ert-deftest ebox-flex-panels-in-padded-viewport-column-match-eager-layout ()
  "Lazy Column layout must preserve nested panel geometry and borders."
  (dolist (padding '(0 (1 2)))
    (dolist (viewport-width '(140 96 140))
      (let* ((ebox-viewport-width viewport-width)
             (ebox-viewport-height 30)
             (layout
              (ebox-test-column
               :width '(viewport) :height '(viewport-height)
               :padding padding :bgcolor "white"
               (ebox-test-flex :width 'stretch :flex-wrap 'wrap :gap '(1 2)
                 (ebox-test-column
                  :flex-basis '(20) :flex-shrink 0
                  :padding '(1 2) :border "gray"
                  (ebox-test-text "Sidebar"))
                 (ebox-test-column
                  :flex-grow 1 :flex-basis '(48) :min-width 0
                  :padding '(1 2) :border "gray"
                  (ebox-test-text "Main"))
                 (ebox-test-column
                  :flex-grow 1 :flex-basis '(28) :min-width 0
                  (ebox-test-column :padding '(1 2) :border "gray"
                    (ebox-test-text "Details") (ebox-test-text "Body"))
                  (ebox-test-column :padding '(1 2) :border "gray"
                    (ebox-test-text "Service") (ebox-test-text "Ready"))))))
             (_ (ebox-region-ids (ebox-test-root layout)))
             (eager (let ((ebox--scroll-window-render-disabled t))
                      (ebox-render layout)))
             (lazy (ebox-render layout)))
        (should (equal (substring-no-properties lazy)
                       (substring-no-properties eager)))
        (should (equal (mapcar #'ebox--string-pixel-width
                              (ebox-string-lines lazy))
                       (mapcar #'ebox--string-pixel-width
                              (ebox-string-lines eager))))
        (should (equal-including-properties lazy eager))))))

(ert-deftest ebox-flex-viewport-column-wraps-text-and-preserves-box-overflow ()
  "A lazy Column wraps raw Text but keeps a definite child's spatial output."
  (let* ((ebox-viewport-width 20)
         (ebox-viewport-height 10)
         (layout
          (ebox-test-column
           :width '(viewport) :height '(viewport-height) :padding '(0 (2))
           (ebox-test-text "one two three four five six")
           (ebox-test-box :width '(30) :wrap-mode 'none :border "blue"
             (ebox-test-text "wide child"))))
         (_ (ebox-region-ids (ebox-test-root layout)))
         (eager (let ((ebox--scroll-window-render-disabled t))
                  (ebox-render layout)))
         (lazy (ebox-render layout)))
    (should (equal-including-properties lazy eager))))

(ert-deftest ebox-flex-padded-scroll-producers-retain-containing-viewport ()
  "Lazy extension and full materialization keep the initial content width."
  (let* ((ebox-viewport-width 100)
         (ebox-viewport-height 4)
         (ebox-scroll-lazy-prefix-lookahead-lines 0)
         (ebox-wheel-scroll-step 0)
         (ebox-scroll-lazy-idle-prefetch-delay 999)
         (layout
          (apply #'ebox-test-column
                 (append
                  '(:id "padded-scroll" :width (viewport)
                    :height (viewport-height) :padding (0 (2)))
                  (cl-loop for index below 30
                           collect
                           (ebox-test-column :border "gray"
                             (ebox-test-text (format "row %02d" index)))))))
         (buffer (generate-new-buffer " *ebox-padded-scroll*"))
         root-id)
    (unwind-protect
        (progn
          (ebox-render-to-buffer buffer layout)
          (setq root-id
                (plist-get (car (ebox-selector-query-buffer
                                buffer "#padded-scroll")) :region-id))
          (let* ((state (ebox-scroll-state root-id))
                 (prefix (plist-get state :render-content-prefix))
                 (materialize (plist-get state :materialize-content-lines)))
            (should prefix)
            (should materialize)
            (let* ((extended
                    (ebox--scroll-state-ensure-prefix-lines root-id state 12 t))
                   (partial-lines (plist-get extended :content-lines))
                   (complete
                    (ebox--scroll-state-materialize-lines root-id extended))
                   (full-lines (plist-get complete :content-lines)))
              (should (= (length partial-lines) 12))
              (should (= (length full-lines) 30))
              (dolist (line (append partial-lines full-lines))
                (should (= (ebox--string-pixel-width line) 96)))
              (should (cl-every #'identity
                               (cl-mapcar
                                (lambda (partial full)
                                  (equal-including-properties
                                   (ebox--strip-paint-origins!
                                    (copy-sequence partial))
                                   (ebox--strip-paint-origins!
                                    (copy-sequence full))))
                                partial-lines (seq-take full-lines 12)))))))
      (when root-id (ebox--scroll-cancel-idle-prefetch root-id))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(defun ebox-flex-test--plain-lines (node)
  "Return rendered NODE as plain lines."
  (ebox-string-lines (substring-no-properties (ebox-flex-test--render node))))

(defun ebox-flex-test--line-widths (node)
  "Return rendered NODE pixel widths line by line."
  (mapcar #'ebox--string-pixel-width
          (ebox-string-lines (ebox-flex-test--render node))))

(defun ebox-flex-test--region-property-width (string region-id property)
  "Return max PROPERTY span width for REGION-ID in STRING."
  (let ((pos 0)
        (len (length string))
        (max-width 0))
    (while (< pos len)
      (if (equal (get-text-property pos property string) region-id)
          (let ((end (or (next-single-property-change
                          pos property string len)
                         len)))
            (setq max-width
                  (max max-width
                       (string-pixel-width (substring string pos end))))
            (setq pos end))
        (setq pos (or (next-single-property-change
                       pos 'ebox-content string len)
                      len))))
    max-width))

(defun ebox-flex-test--region-content-width (string region-id)
  "Return max content span width for REGION-ID in STRING."
  (ebox-flex-test--region-property-width string region-id 'ebox-content))

(defun ebox-flex-test--region-owner-width (string region-id)
  "Return max rendered owner span width for REGION-ID in STRING."
  (let ((pos 0)
        (len (length string))
        (current-width 0)
        (max-width 0))
    (while (< pos len)
      (let* ((owners (get-text-property pos 'ebox-content-owners string))
             (end (or (next-single-property-change
                       pos 'ebox-content-owners string len)
                      len)))
        (if (memq region-id owners)
            (setq current-width
                  (+ current-width
                     (string-pixel-width (substring string pos end))))
          (setq max-width (max max-width current-width)
                current-width 0))
        (setq pos end)))
    (max max-width current-width)))

(defun ebox-flex-test--content-widths (input)
  "Return max content widths for INPUT's direct material children."
  (let ((node (ebox-test-root input)))
  (let* ((ids (mapcar (lambda (child)
                        (car (ebox-region-ids child)))
                      (ebox-box-node-children node)))
         (rendered (ebox-flex-test--render input)))
    (mapcar (lambda (id)
              (ebox-flex-test--region-owner-width rendered id))
              ids))))

(defun ebox-flex-test--face-has-key-value-p (face key value)
  "Return non-nil when FACE contains KEY with VALUE."
  (cond
   ((null face) nil)
   ((and (listp face) (keywordp (car face)))
    (equal (plist-get face key) value))
   ((listp face)
    (cl-some (lambda (item)
               (ebox-flex-test--face-has-key-value-p item key value))
             face))
   (t nil)))

(defun ebox-flex-test--face-at-property (string property)
  "Return first face in STRING at PROPERTY."
  (let ((pos 0)
        (len (length string))
        face)
    (while (and (< pos len) (not face))
      (when (get-text-property pos property string)
        (setq face (get-text-property pos 'face string)))
      (setq pos (or (next-single-property-change pos property string)
                    (1+ pos))))
    face))

(defun ebox-flex-test--property-values (string property)
  "Return distinct values for PROPERTY in STRING."
  (let ((pos 0)
        (len (length string))
        values)
    (while (< pos len)
      (when-let* ((value (get-text-property pos property string)))
        (unless (memq value values)
          (setq values (append values (list value)))))
      (setq pos (1+ pos)))
    values))

(ert-deftest ebox-flex-batch-line-sizing-preserves-fallback-semantics ()
  "Batch line sizing should preserve the scalar Flexbox algorithm."
  (let* ((line
          (list
           (list :base 80 :hypothetical 80 :min-main 0 :max-main nil
                 :props '(:flex-grow 1 :flex-shrink 1))
           (list :base 80 :hypothetical 80 :min-main 0 :max-main nil
                 :props '(:flex-grow 2 :flex-shrink 1))))
         (expected
          (mapcar (lambda (item) (plist-get item :target))
                  (ebox--flex-size-line line 200 10)))
         (actual
          (mapcar (lambda (item) (plist-get item :target))
                  (car (ebox--flex-size-lines (list line) 200 10)))))
    (should (equal actual expected))))

(ert-deftest ebox-flex-module-preserves-item-participation ()
  "Extracted flex code should preserve item participation semantics."
  (let* ((node (ebox-build
                '(flex :width (240)
                  (box :flex-grow 1 :width (40) "Grow")
                  (box :width (40) "Fixed"))))
         (rendered (ebox-render node)))
    (should (string-match-p "Grow" rendered))
    (should (string-match-p "Fixed" rendered))))

(ert-deftest ebox-flex-measures-direct-text-without-box-geometry ()
  "A canonical Text child should participate as text, not a geometry Box."
  (let* ((node (ebox-build '(flex :width (120) "Direct text")))
         (rendered (ebox-render node)))
    (should (string-match-p "Direct text"
                            (substring-no-properties rendered)))
    (should (= (ebox--string-max-pixel-width rendered) 120))))

(ert-deftest ebox-flex-item-clears-disappeared-ecss-props-on-region-update ()
  "A region update should clear removed rule props but retain inline item props."
  (let* ((ebox-style-stylesheet (ecss-stylesheet-create))
         (layout
          (ebox-test-flex
            (ebox-test-box :id "rule" :class 'grow
                         (ebox-test-text "Rule") :width '(40))
            (ebox-test-box :id "inline" (ebox-test-text "Inline") :width '(40)
                         :flex-grow 2)))
         (buffer (generate-new-buffer " *ebox-flex-style-reset*")))
    (unwind-protect
        (progn
          (ebox-style-add-rule ".grow" '(:flex-grow 1) :layer 'layout)
          (ebox-render-to-buffer buffer layout)
          (let ((items (plist-get (plist-get (ebox--buffer-render-state buffer)
                                               :root-node)
                                 :children)))
            (should (= (ebox-get (car items) :flex-grow) 1))
            (should (= (ebox-get (cadr items) :flex-grow) 2)))
          (ebox-style-reset-rules)
          (ebox-region-update (ebox-region-resolve buffer "rule")
                              :width '(41))
          (let ((items (plist-get (plist-get (ebox--buffer-render-state buffer)
                                               :root-node)
                                 :children)))
            (should-not (ebox-get (car items) :flex-grow))
            (should (= (ebox-get (cadr items) :flex-grow) 2))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-flex-accepts-flex-props-on-direct-child-box ()
  "Flex item participation props may live directly on child boxes."
  (let* ((layout (ebox-test-flex
                  :width 300
                  (ebox-test-box (ebox-test-text "A") :flex-grow 1 :flex-basis '(80))
                  (ebox-test-box (ebox-test-text "B") :flex-grow 1 :flex-basis '(80))))
         (rendered (let ((ebox-viewport-width 300))
                     (ebox-render layout)))
         (widths (mapcar #'ebox--string-pixel-width
                         (ebox-string-lines rendered))))
    (should (cl-every (lambda (width) (<= width 300)) widths))
    (should (string-match-p "A" (substring-no-properties rendered)))
    (should (string-match-p "B" (substring-no-properties rendered)))))

(ert-deftest ebox-flex-grows-items-to-fill-row-container ()
  "Flex grow should distribute extra row width by grow factors."
  (let* ((layout
          (ebox-test-flex :width '(300)
            (ebox-test-flex-item
             (ebox-test-box (ebox-test-text "A") :width '(80))
             :flex-grow 1 :flex-basis '(80))
            (ebox-test-flex-item
             (ebox-test-box (ebox-test-text "B") :width '(80))
             :flex-grow 2 :flex-basis '(80))))
         (widths (ebox-flex-test--content-widths layout)))
    (should (= (length widths) 2))
    (should (= (apply #'+ widths) 300))
    (should (> (cadr widths) (car widths)))
    (should (equal (ebox-flex-test--line-widths layout) '(300)))))

(ert-deftest ebox-flex-margin-box-target-subtracts-inline-margins-for-border-box ()
  "A row flex target should include a border-box item's inline margins."
  (let ((layout
         (ebox-test-flex :width '(200) :align-items 'flex-start
           (ebox-test-box (ebox-test-text "A")
                        :width '(40)
                        :box-sizing 'border-box
                        :margin-left '(20)
                        :margin-right '(20)
                        :flex-grow 1))))
    (should (equal (ebox-flex-test--line-widths layout) '(200)))))

(ert-deftest ebox-flex-margin-box-target-subtracts-block-margins-for-border-box ()
  "A column flex target should include a border-box item's block margins."
  (let ((layout
         (ebox-test-flex :width '(80) :height 6
                    :flex-direction 'column
                    :align-items 'flex-start
           (ebox-test-box (ebox-test-text "A")
                        :width '(40)
                        :height 1
                        :box-sizing 'border-box
                        :margin-top 1
                        :margin-bottom 1
                        :flex-grow 1))))
    (should (= (ebox-string-height (ebox-flex-test--render layout)) 6))))

(ert-deftest ebox-flex-margin-box-target-preserves-content-box-outer-sides ()
  "Content-box flex targets should subtract padding, borders, and margins."
  (let ((layout
         (ebox-test-flex :width '(200) :align-items 'flex-start
           (ebox-test-box (ebox-test-text "A")
                        :width '(40)
                        :box-sizing 'content-box
                        :padding-left '(10)
                        :padding-right '(10)
                        :border-left '(5)
                        :border-right '(5)
                        :margin-left '(20)
                        :margin-right '(20)
                        :flex-grow 1))))
    (should (equal (ebox-flex-test--line-widths layout) '(200)))))

(ert-deftest ebox-flex-shrinks-items-by-shrink-factors ()
  "Flex shrink should remove more width from larger shrink factors."
  (let* ((layout
          (ebox-test-flex :width '(150)
            (ebox-test-flex-item
             (ebox-test-box (ebox-test-text "A") :width '(100))
             :flex-shrink 1 :flex-basis '(100))
            (ebox-test-flex-item
             (ebox-test-box (ebox-test-text "B") :width '(100))
             :flex-shrink 3 :flex-basis '(100))))
         (widths (ebox-flex-test--content-widths layout)))
    (should (= (length widths) 2))
    (should (= (apply #'+ widths) 150))
    (should (> (car widths) (cadr widths)))))

(ert-deftest ebox-flex-basis-supports-intrinsic-keywords ()
  "Flex basis intrinsic keywords should use content-derived sizes."
  (let* ((content "aa bbbb")
         (max-content (ebox--string-pixel-width content))
         (min-content (ebox--string-pixel-width "bbbb"))
         (layout
          (ebox-test-flex :width '(300)
            (ebox-test-flex-item
             (ebox-test-box (ebox-test-text content) :width '(160) :wrap-mode 'word)
             :flex-basis 'max-content)
            (ebox-test-flex-item
             (ebox-test-box (ebox-test-text content) :width '(160) :wrap-mode 'word)
             :flex-basis 'min-content)))
         (widths (ebox-flex-test--content-widths layout)))
    (should (equal widths (list max-content min-content)))))

(ert-deftest ebox-flex-definite-basis-does-not-materialize-fallback ()
  "A definite basis must not materialize a subtree for an unused fallback."
  (dolist (basis '((0) (40) 40))
    (let* ((input
            (ebox-test-box
             (ebox-test-column
              (ebox-test-text "nested content")
              (ebox-test-text "second line"))))
           (source (ebox-test-root input))
           (ebox--surface-materialization-active t)
           (expected (ebox--normalize-horizontal-size-value
                      basis ebox--preferred-size-keywords))
           (original-max (symbol-function 'ebox--content-max-pixel))
           (original-render (symbol-function 'ebox--render-layout))
           (max-calls 0)
           (materializations 0))
      (cl-letf (((symbol-function 'ebox--content-max-pixel)
                 (lambda (box)
                   (cl-incf max-calls)
                   (funcall original-max box)))
                ((symbol-function 'ebox--render-layout)
                 (lambda (node)
                   (cl-incf materializations)
                   (funcall original-render node))))
        (should (= expected (ebox--flex-basis-main source "" 'row basis))))
      (should (zerop max-calls))
      (should (zerop materializations)))))

(ert-deftest ebox-flex-basis-retains-required-intrinsic-fallback ()
  "Viewport-like basis values measure only when their viewport is absent."
  (dolist (viewport '(nil 120))
    (dolist (basis '(viewport stretch contain))
      (let* ((content "natural content")
             (source (ebox-test-root (ebox-test-box (ebox-test-text content))))
             (ebox--surface-materialization-active t)
             (ebox-viewport-width viewport)
             (original-max (symbol-function 'ebox--content-max-pixel))
             (max-calls 0))
        (cl-letf (((symbol-function 'ebox--content-max-pixel)
                   (lambda (box)
                     (cl-incf max-calls)
                     (funcall original-max box))))
          (should (= (or viewport (ebox--string-pixel-width content))
                     (ebox--flex-basis-main source "" 'row basis))))
        (should (= max-calls (if viewport 0 1)))))))

(ert-deftest ebox-flex-lazy-basis-fallback-preserves-public-dsl-output ()
  "Public Flex layout retains complete output when unused probes disappear."
  (let* ((input
          (ebox-build
           '(flex :width (140) :flex-wrap wrap :gap (1 (4))
              (box :flex-basis (40) :flex-grow 1 :min-width 0
                   :wrap-mode word :padding (1 (2))
                   :color "#123456" :bgcolor "#ddeeff"
                (column
                 (text "alpha beta gamma delta epsilon")
                 (text "second line")))
              (box :flex-basis (20) :min-width 0 :wrap-mode word
                (text "peer")))))
         (original-basis (symbol-function 'ebox--flex-basis-main))
         (fast (ebox-render input))
         eager)
    ;; Reintroduce only the eager fallback's materialization, using the same
    ;; public input and the unchanged resolver for the reference output.
    (cl-letf (((symbol-function 'ebox--flex-basis-main)
               (lambda (source rendered axis basis)
                 (when (and (eq axis 'row)
                            (ebox--flex-box-source-p source)
                            (ebox--flex-fixed-basis-value-p basis))
                   (ebox--content-max-pixel source))
                 (funcall original-basis source rendered axis basis))))
      (setq eager (ebox-render input)))
    (should (equal-including-properties fast eager))))

(ert-deftest ebox-flex-grow-redistributes-space-after-max-width-clamp ()
  "A max-width-clamped item should freeze and leave space for flexible siblings."
  (let* ((layout
          (ebox-test-flex :width '(200)
            (ebox-test-flex-item
             (ebox-test-box (ebox-test-text "A") :width '(60) :max-width '(80))
             :flex-grow 1 :flex-basis '(60))
            (ebox-test-flex-item
             (ebox-test-box (ebox-test-text "B") :width '(60))
             :flex-grow 1 :flex-basis '(60))))
         (widths (ebox-flex-test--content-widths layout)))
    (should (equal widths '(80 120)))
    (should (equal (ebox-flex-test--line-widths layout) '(200)))))

(ert-deftest ebox-flex-grow-starts-from-flex-base-before-min-width-clamp ()
  "Grow distribution should start from flex base sizes, not hypothetical sizes."
  (let* ((layout
          (ebox-test-flex :width '(200)
            (ebox-test-flex-item
             (ebox-test-box (ebox-test-text "A") :width '(50) :min-width '(80))
             :flex-grow 1 :flex-basis '(50))
            (ebox-test-flex-item
             (ebox-test-box (ebox-test-text "B") :width '(50))
             :flex-grow 1 :flex-basis '(50))))
         (widths (ebox-flex-test--content-widths layout)))
    (should (equal widths '(100 100)))
    (should (equal (ebox-flex-test--line-widths layout) '(200)))))

(ert-deftest ebox-flex-grow-factors-below-one-partially-fill-free-space ()
  "Grow factors whose sum is below 1 should leave some free space unclaimed."
  (let* ((layout
          (ebox-test-flex :width '(300)
            (ebox-test-flex-item
             (ebox-test-box (ebox-test-text "A") :width '(50))
             :flex-grow 0.25)
            (ebox-test-flex-item
             (ebox-test-box (ebox-test-text "B") :width '(50))
             :flex-grow 0.25)))
         (widths (ebox-flex-test--content-widths layout)))
    (should (equal widths '(100 100)))
    (should (equal (ebox-flex-test--line-widths layout) '(300)))))

(ert-deftest ebox-flex-shrink-redistributes-space-after-min-width-clamp ()
  "A min-width-clamped item should freeze and push shrinkage to siblings."
  (let* ((layout
          (ebox-test-flex :width '(150)
            (ebox-test-flex-item
             (ebox-test-box (ebox-test-text "A") :width '(100) :min-width '(80))
             :flex-shrink 1 :flex-basis '(100))
            (ebox-test-flex-item
             (ebox-test-box (ebox-test-text "B") :width '(100))
             :flex-shrink 1 :flex-basis '(100))))
         (widths (ebox-flex-test--content-widths layout)))
    (should (equal widths '(80 70)))
    (should (equal (ebox-flex-test--line-widths layout) '(150)))))

(ert-deftest ebox-flex-shrink-starts-from-flex-base-before-max-width-clamp ()
  "Shrink distribution should start from flex base sizes, not hypothetical sizes."
  (let* ((layout
          (ebox-test-flex :width '(150)
            (ebox-test-flex-item
             (ebox-test-box (ebox-test-text "A") :width '(100) :max-width '(80)
                          :wrap-mode 'word)
             :flex-shrink 1 :flex-basis '(100))
            (ebox-test-flex-item
             (ebox-test-box (ebox-test-text "B") :width '(100) :wrap-mode 'word)
             :flex-shrink 1 :flex-basis '(100))))
         (widths (ebox-flex-test--content-widths layout)))
    (should (equal widths '(75 75)))
    (should (equal (ebox-flex-test--line-widths layout) '(150)))))

(ert-deftest ebox-flex-shrink-factors-below-one-partially-shrink-overflow ()
  "Shrink factors whose sum is below 1 should leave some overflow unclaimed."
  (let* ((layout
          (ebox-test-flex :width '(150)
            (ebox-test-flex-item
             (ebox-test-box (ebox-test-text "A") :width '(100))
             :flex-shrink 0.25)
            (ebox-test-flex-item
             (ebox-test-box (ebox-test-text "B") :width '(100))
             :flex-shrink 0.25)))
         (widths (ebox-flex-test--content-widths layout)))
    (should (equal widths '(87 88)))
    (should (equal (ebox-flex-test--line-widths layout) '(175)))))

(ert-deftest ebox-flex-properties-reject-negative-values ()
  "Flex width, basis, grow, and shrink factors should reject negatives."
  (should-error
   (ebox-flex-test--render
    (ebox-test-flex :width '(-1)
      (ebox-test-box (ebox-test-text "A") :width '(20))))
   :type 'error)
  (should-error
   (ebox-flex-test--render
    (ebox-test-flex
      (ebox-test-flex-item (ebox-test-box (ebox-test-text "A") :width '(20))
                      :flex-grow -1)))
   :type 'error)
  (should-error
   (ebox-flex-test--render
    (ebox-test-flex
      (ebox-test-flex-item (ebox-test-box (ebox-test-text "A") :width '(20))
                      :flex-shrink -1)))
   :type 'error)
  (should-error
   (ebox-flex-test--render
    (ebox-test-flex
      (ebox-test-flex-item (ebox-test-box (ebox-test-text "A") :width '(20))
                      :flex-basis '(-1))))
   :type 'error))

(ert-deftest ebox-flex-wraps-rows-with-column-gap ()
  "Row wrap should create new flex lines using column gaps."
  (let* ((layout
          (ebox-test-flex :width '(210) :flex-wrap 'wrap :column-gap '(10)
            (ebox-test-box (ebox-test-text "A") :width '(100))
            (ebox-test-box (ebox-test-text "B") :width '(100))
            (ebox-test-box (ebox-test-text "C") :width '(100))))
         (lines (ebox-flex-test--plain-lines layout)))
    (should (= (length lines) 2))
    (should (string-match-p "A.*B" (car lines)))
    (should (string-match-p "C" (cadr lines)))
    (should (equal (ebox-flex-test--line-widths layout) '(210 210)))))

(ert-deftest ebox-flex-row-wrap-measures-column-items-at-natural-width ()
  "Column flex items should not stretch to the full row before line breaking."
  (let* ((layout
          (ebox-build
           '(flex :flex-flow (row wrap) :column-gap (12) :width (800)
             (column
              (box :width (220) "one")
              (box :width (42) "A"))
             (column
              (box :width (220) "two")
              (box :width (42) "B"))
             (column
              (box :width (220) "three")
              (box :width (42) "C")))))
         (lines (ebox-flex-test--plain-lines layout)))
    (should (= (length lines) 2))
    (should (string-match-p "one.*two.*three" (car lines)))
    (should (string-match-p "A.*B.*C" (cadr lines)))))

(ert-deftest ebox-flex-rerenders-composite-item-for-assigned-viewport ()
  "Composite flex items should re-render internals for final item width."
  (let* ((layout
          (ebox-build
           '(flex :flex-flow (row wrap) :column-gap (12) :width (800)
             (column
              (box :id "title" :max-width (293)
                   :padding (0 (10)) :border "#5E7F6A"
                   :text-align center "wrap")
              (flex :id "body" :max-width (293) :padding (0 (8))
                    :border-right "#5E7F6A"
                    :border-bottom "#5E7F6A"
                    :border-left "#5E7F6A"
                    :flex-wrap wrap :column-gap (8)
                    (box :flex-shrink 0 :width (118) "A 118")
                    (box :flex-shrink 0 :width (118) "B 118")
                    (box :flex-shrink 0 :width (118) "C 118"))))))
         (buffer (generate-new-buffer " *ebox-flex-viewport*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer buffer layout)
          (let* ((rendered (with-current-buffer buffer (buffer-string)))
                 (title-id (plist-get
                            (car (ebox-selector-query-buffer buffer "#title"))
                            :region-id))
                 (body-id (plist-get
                           (car (ebox-selector-query-buffer buffer "#body"))
                           :region-id))
                 (title-width (ebox-flex-test--region-property-width
                               rendered title-id 'ebox-bt))
                 (body-width (ebox-flex-test--region-property-width
                              rendered body-id 'ebox-bb)))
            (should (> title-width 200))
            (should (> body-width 200))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-flex-wrapper-bounds-preformatted-child-layout ()
  "Flex container boxes should not let child layout overflow widen them."
  (let* ((ebox-viewport-width 500)
         (layout
          (ebox-build
           '(flex :flex-flow (row wrap) :row-gap 1 :column-gap (12)
             :padding (0 (12))
             :border-right "#6F6A95"
             :border-bottom "#6F6A95"
             :border-left "#6F6A95"
             :bgcolor "#FBF9FF"
             (column
              (box :max-width (440)
                   :padding (0 (10)) :border "#6F6A95"
                   :text-align center ":flex-flow (row wrap)")
              (flex :max-width (440) :padding (0 (8))
                    :border-right "#6F6A95"
                    :border-bottom "#6F6A95"
                    :border-left "#6F6A95"
                    :flex-flow (row wrap) :gap (1 (12))
                    (box :width (170) "A")
                    (box :width (170) "B")
                    (box :width (170) "C wraps")))
             (column
              (box :max-width (440)
                   :padding (0 (10)) :border "#6F6A95"
                   :text-align center ":flex-flow (column wrap)")
              (flex :max-width (440) :padding (0 (8))
                    :border-right "#6F6A95"
                    :border-bottom "#6F6A95"
                    :border-left "#6F6A95"
                    :flex-flow (column wrap) :gap (1 (12))
                    (box :width (140) "A")
                    (box :width (140) "B")
                    (box :width (140) "C new column"))))))
         (rendered (ebox-flex-test--render layout))
         (line-widths (ebox-flex-test--line-widths layout))
         (border-widths
          (cl-loop for id in (ebox-flex-test--property-values rendered
                                                              'ebox-bb)
                   collect (ebox-flex-test--region-property-width
                            rendered id 'ebox-bb))))
    (should (cl-every (lambda (width) (<= width ebox-viewport-width))
                      line-widths))
    (should (cl-some (lambda (width) (> width 400)) border-widths))))

(ert-deftest ebox-flex-wraps-with-max-width-clamped-hypothetical-size ()
  "Line collection should use max-width-clamped hypothetical main sizes."
  (let* ((layout
          (ebox-test-flex :width '(210) :flex-wrap 'wrap :column-gap '(10)
            (ebox-test-flex-item
             (ebox-test-box (ebox-test-text "A") :width '(200) :max-width '(100))
             :flex-basis '(200))
            (ebox-test-flex-item
             (ebox-test-box (ebox-test-text "B") :width '(200) :max-width '(100))
             :flex-basis '(200))))
         (lines (ebox-flex-test--plain-lines layout))
         (widths (ebox-flex-test--content-widths layout)))
    (should (= (length lines) 1))
    (should (equal widths '(100 100)))
    (should (equal (ebox-flex-test--line-widths layout) '(210)))))

(ert-deftest ebox-flex-omitted-width-stretches-to-viewport-when-bound ()
  "A row flex container without :width should use the current viewport."
  (let* ((ebox-viewport-width 240)
         (layout
          (ebox-test-flex :flex-wrap 'wrap :column-gap '(10)
            (ebox-test-box (ebox-test-text "A") :width '(100))
            (ebox-test-box (ebox-test-text "B") :width '(100))
            (ebox-test-box (ebox-test-text "C") :width '(100)))))
    (should (equal (ebox-flex-test--line-widths layout) '(240 240)))))

(ert-deftest ebox-flex-stretch-width-is-independent-of-container-wrapper ()
  "Stretch width should use the viewport with or without a neutral wrapper."
  (let* ((ebox-viewport-width 200)
         (plain
          (ebox-test-flex :width 'stretch
            (ebox-test-box (ebox-test-text "A") :width '(40))))
         (padded
          (ebox-test-flex :width 'stretch :padding 0
            (ebox-test-box (ebox-test-text "A") :width '(40)))))
    (should (equal (mapcar #'ebox-flex-test--line-widths
                           (list plain padded))
                   '((200) (200))))))

(ert-deftest ebox-flex-indefinite-width-keeps-natural-size-across-wrapper ()
  "Indefinite width should stay natural with or without a neutral wrapper."
  (let* ((ebox-viewport-width nil)
         (cases
          (mapcar
           (lambda (width)
             (let ((plain
                    (ebox-test-flex :width width
                      (ebox-test-box (ebox-test-text "A") :width '(40))))
                   (padded
                    (ebox-test-flex :width width :padding 0
                      (ebox-test-box (ebox-test-text "A") :width '(40)))))
               (list width plain padded)))
           '(stretch auto)))
         (results
          (mapcar
           (lambda (case)
             (list (car case)
                   (car (ebox-flex-test--line-widths (nth 1 case)))
                   (car (ebox-flex-test--line-widths (nth 2 case)))))
           cases)))
    (should (equal results
                   '((stretch 40 40)
                     (auto 40 40))))))

(ert-deftest ebox-flex-omitted-wrapper-width-uses-viewport-content-box ()
  "A styled flex container should lay out inside its viewport-sized box."
  (let* ((ebox-viewport-width 240)
         (layout
          (ebox-test-flex :padding-inline '(20)
                     :border-left '(10)
                     :border-right '(10)
                     :justify-content 'space-between
            (ebox-test-box (ebox-test-text "A") :width '(40))
            (ebox-test-box (ebox-test-text "B") :width '(40))))
         (rendered (ebox-flex-test--render layout))
         (display-widths
          (cl-loop for index below (length rendered)
                   for display = (get-text-property index 'display rendered)
                   when (and (consp display)
                             (eq (car display) 'space))
                   collect (car (plist-get (cdr display) :width)))))
    (should (equal (ebox-flex-test--line-widths layout) '(240)))
    (should (member 100 display-widths))))

(ert-deftest ebox-flex-viewport-wrapper-width-uses-content-box ()
  "A viewport-sized styled flex container should use its content box for lines."
  (let* ((ebox-viewport-width 240)
         (layout
          (ebox-test-flex :width '(viewport)
                     :padding-inline '(20)
                     :border-left '(10)
                     :border-right '(10)
                     :flex-wrap 'wrap
            (ebox-test-flex-item (ebox-test-box (ebox-test-text "A") :width '(180)))
            (ebox-test-flex-item (ebox-test-box (ebox-test-text "B") :width '(180))))))
    (should (cl-every (lambda (width) (<= width ebox-viewport-width))
                      (ebox-flex-test--line-widths layout)))))

(ert-deftest ebox-flex-auto-height-is-independent-of-container-wrapper ()
  "Auto height should preserve natural child height across wrapper branches."
  (let* ((plain
          (ebox-test-flex :width '(80) :height 'auto
            (ebox-test-box (ebox-test-text "A\nB") :width '(40))))
         (padded
          (ebox-test-flex :width '(80) :height 'auto :padding 0
            (ebox-test-box (ebox-test-text "A\nB") :width '(40))))
         (results
          (mapcar
           (lambda (layout)
             (condition-case err
                 (ebox-string-height (ebox-flex-test--render layout))
               (error err)))
           (list plain padded))))
    (should (equal results '(2 2)))))

(ert-deftest ebox-flex-reuses-measured-non-box-child-render ()
  "Flex should not fully rerender a measured non-box child during one render."
  (let* ((child (ebox-test-column
                 :key 'measured-child
                 (ebox-test-box (ebox-test-text "A") :width '(100))
                 (ebox-test-box (ebox-test-text "B") :width '(100))))
         (layout (ebox-test-flex :width '(240) :flex-wrap 'wrap
                   child
                   (ebox-test-column
                    (ebox-test-box (ebox-test-text "C") :width '(100))
                    (ebox-test-box (ebox-test-text "D") :width '(100)))))
         (target-handle
          (ebox-node-source-handle (ebox-test-root child)))
         (calls 0)
         (original-render
          (symbol-function 'ebox--flex-render-source-for-measurement)))
    (cl-letf (((symbol-function 'ebox--flex-render-source-for-measurement)
               (lambda (node viewport)
                 (when (eq (ebox-node-source-handle node) target-handle)
                   (cl-incf calls))
                 (funcall original-render node viewport))))
      (ebox-render layout))
    (should (= calls 1))))

(ert-deftest ebox-flex-reuses-natural-non-box-render-before-cross-padding ()
  "Final cross padding should reuse a naturally sized non-box render."
  (let* ((source (ebox-test-column
                  :key 'natural-child
                  (ebox-test-box (ebox-test-text "A") :width '(80))
                  (ebox-test-box (ebox-test-text "A2") :width '(80))))
         (item (ebox-test-flex-item
                source :flex-grow 1 :flex-basis '(80)))
         (layout
          (ebox-test-flex :width '(220)
            item
            (ebox-test-box (ebox-test-text "B") :width '(80) :height 4)))
         (target-handle
          (ebox-node-source-handle (ebox-test-root item)))
         (calls 0)
         (original (symbol-function 'ebox--render-node))
         rendered)
    (cl-letf (((symbol-function 'ebox--render-node)
               (lambda (node &optional source-index)
                 (when (eq (ebox-node-source-handle node) target-handle)
                   (cl-incf calls))
                 (funcall original node source-index))))
      (setq rendered (ebox-render layout)))
    (should (= (ebox-string-height rendered) 4))
    (should (equal (mapcar #'ebox--string-pixel-width
                           (ebox-string-lines rendered))
                   '(220 220 220 220)))
    (should (= calls 2))))

(defun ebox-flex-test--observe-sized-box (input &optional force-final-render)
  "Render INPUT and observe its first child's actual Box materializations.
When FORCE-FINAL-RENDER is non-nil, discard only the child's natural sized
entry before final allocation, providing the original rerendering reference."
  (let* ((source (car (ebox-tree-layout-children (ebox-test-root input))))
         (handle (ebox-node-source-handle source))
         (render-box (symbol-function 'ebox--render-box))
         (render-sized (symbol-function 'ebox--flex-render-sized-entry))
         allocation observations final-source scroll-state rendered)
    (cl-letf (((symbol-function 'ebox--render-box)
               (lambda (box)
                 (when (and allocation
                            (eq (ebox-node-source-handle box) handle))
                   (push
                    (list :allocation allocation
                          :width (ebox-get box :width)
                          :height (ebox-get box :height)
                          :constraints
                          (ebox--render-cache-plist-signature box)
                          :context
                          (list ebox-viewport-width ebox-viewport-height
                                ebox--intrinsic-layout-measurement
                                ebox--inline-auto-width-intrinsic-p
                                ebox--containing-wrap-mode
                                ebox--box-content-cache-purpose
                                ebox--render-region-id
                                ebox--render-root-parent-kind
                                ebox--scroll-window-render-disabled))
                    observations))
                 (funcall render-box box)))
              ((symbol-function 'ebox--flex-render-sized-entry)
               (lambda (item axis main cross align)
                 (let* ((target (eq (ebox-node-source-handle
                                    (plist-get item :source))
                                   handle))
                        (previous-allocation allocation))
                   (when (and target cross force-final-render)
                     (setq item (copy-sequence item))
                     (plist-put item :render-cache nil))
                   (setq allocation (and target (list axis main cross align)))
                   (unwind-protect
                       (prog1 (funcall render-sized item axis main cross align)
                         (when (and target cross)
                           (let ((region-id
                                  (ebox-get (plist-get item :source) :region-id)))
                             (setq final-source
                                   (ebox-node-source-handle
                                    (gethash region-id ebox--region-box-table))
                                   scroll-state (ebox-scroll-state region-id)))))
                     (setq allocation previous-allocation))))))
      (setq rendered (ebox-render input)))
    (list :rendered rendered :observations (nreverse observations)
          :source-handle final-source :scroll-state scroll-state)))

(ert-deftest ebox-flex-identical-cross-materializes-box-once ()
  "An already assigned numeric cross size must not materialize a Box twice."
  (let* ((input
          (ebox-build
           '(flex :width (120) :flex-wrap wrap
              (box :flex-basis (40) :flex-grow 1 :min-width 0
                   :height 2 :wrap-mode word
                (text "short")))))
         (observed (ebox-flex-test--observe-sized-box input))
         (calls (plist-get observed :observations))
         (first (car calls)))
    (should (= (ebox-string-height (plist-get observed :rendered)) 2))
    (should (equal (mapcar #'ebox--string-pixel-width
                           (ebox-string-lines (plist-get observed :rendered)))
                   '(120 120)))
    (should (= (plist-get first :width) 120))
    (should (= (plist-get first :height) 2))
    ;; Before the fix both actual Box renders have identical complete node
    ;; declarations and dynamic contexts; only the caller's allocation differs.
    (dolist (call (cdr calls))
      (should (equal (plist-get first :constraints)
                     (plist-get call :constraints)))
      (should (equal (plist-get first :context)
                     (plist-get call :context))))
    (ert-info ((format "Actual Box allocations: %S"
                       (mapcar (lambda (call) (plist-get call :allocation))
                               calls)))
      (should (= (length calls) 1)))))

(ert-deftest ebox-flex-identical-cross-preserves-properties-and-source ()
  "Reused row/column output retains chrome, text properties, and source ids."
  (dolist (axis '(row column))
    (dolist (sizing '(border-box content-box))
      (let* ((ebox-viewport-width nil)
             (row-p (eq axis 'row))
             (label (propertize "alpha beta" 'help-echo "retained leaf"
                                'mouse-face 'highlight))
             (input
              (ebox-build
               `(flex ,@(if row-p '(:width (140)) '(:height 10))
                      :flex-direction ,axis :flex-wrap wrap
                  (box :flex-basis ,(if row-p '(40) 2) :flex-grow 1
                       :min-width 0 :wrap-mode word :overflow hidden
                       ,@(if row-p
                             (list :height (if (eq sizing 'border-box) 6 2))
                           '(:width (60)))
                       :box-sizing ,sizing :padding (1 (2)) :margin (1 (3))
                       :border (1 solid "#123456")
                       :color "#123456" :bgcolor "#ddeeff"
                    (column :width ,(if row-p '(100) '(40))
                      (text ,label) (text "second"))))))
             (source (car (ebox-tree-layout-children (ebox-test-root input))))
             (handle (ebox-node-source-handle source))
             (fast (ebox-flex-test--observe-sized-box input))
             (reference (ebox-flex-test--observe-sized-box input t))
             (rendered (plist-get fast :rendered)))
        (ert-info ((format "axis=%S sizing=%S" axis sizing))
          (should (= (length (plist-get fast :observations)) 1))
          (should (= (length (plist-get reference :observations)) 2))
          (should (equal-including-properties
                   rendered (plist-get reference :rendered)))
          (should (eq (plist-get fast :source-handle) handle))
          (should (eq (plist-get reference :source-handle) handle))
          (let ((position (string-match "alpha" rendered)))
            (should position)
            (should (equal (get-text-property position 'help-echo rendered)
                           "retained leaf"))
            (should (eq (get-text-property position 'mouse-face rendered)
                        'highlight))
            (should (get-text-property position 'face rendered))))))))

(ert-deftest ebox-flex-identical-cross-keeps-changing-constraints ()
  "Automatic, relative, clamped, and enlarged cross constraints rerender."
  (dolist (case '(nil
                  (:height (viewport-height))
                  (:height 1 :overflow visible)
                  (:height 2 :peer-height 4)
                  (:height 4 :max-height 2)
                  (:height 2 :min-height 3)))
    (let* ((ebox-viewport-height 2)
           (peer-height (plist-get case :peer-height))
           (input
            (ebox-build
             `(flex :width (120) :flex-wrap wrap
                (box :flex-basis (40) :flex-grow 1 :min-width 0
                     :wrap-mode word
                     ,@(ebox--plist-remove-keys case '(:peer-height))
                  (text "A\nB"))
                ,@(when peer-height
                    `((box :width (20) :height ,peer-height "peer"))))))
           (observed (ebox-flex-test--observe-sized-box input)))
      (ert-info ((format "Cross constraint: %S" case))
        (should (= (length (plist-get observed :observations)) 2))
        (should (equal-including-properties
                 (plist-get observed :rendered)
                 (plist-get (ebox-flex-test--observe-sized-box input t)
                            :rendered)))))))

(ert-deftest ebox-flex-identical-cross-keeps-dependent-column-viewport ()
  "A numeric cross declaration alone cannot override viewport dependence."
  (let* ((ebox-viewport-width nil)
         (input
          (ebox-build
           '(flex :height 4 :flex-direction column :flex-wrap wrap
              (box :width (60) :flex-basis 2 :flex-grow 1 :overflow hidden
                (box :width (viewport) (text "responsive"))))))
         (observed (ebox-flex-test--observe-sized-box input))
         (calls (plist-get observed :observations)))
    (should (= (length calls) 2))
    (should (equal (mapcar (lambda (call) (plist-get call :width)) calls)
                   '(60 60)))
    (should (equal (mapcar (lambda (call) (car (plist-get call :context))) calls)
                   '(nil 60)))
    (should (equal-including-properties
             (plist-get observed :rendered)
             (plist-get (ebox-flex-test--observe-sized-box input t)
                        :rendered)))))

(ert-deftest ebox-flex-identical-cross-retains-scroll-state ()
  "A reused fixed-height Box retains the already rendered scroll geometry."
  (let* ((input
          (ebox-build
           '(flex :width (120) :flex-wrap wrap
              (box :flex-basis (40) :flex-grow 1 :min-width 0
                   :height 2 :wrap-mode word :overflow scroll
                (column (text "A") (text "B") (text "C") (text "D"))))))
         (fast (ebox-flex-test--observe-sized-box input))
         (reference (ebox-flex-test--observe-sized-box input t))
         (state (plist-get fast :scroll-state))
         (old-state (plist-get reference :scroll-state)))
    (should (= (length (plist-get fast :observations)) 1))
    (should (= (length (plist-get reference :observations)) 2))
    (should (equal-including-properties
             (plist-get fast :rendered) (plist-get reference :rendered)))
    (should state)
    (should (= (plist-get state :content-height) 2))
    (should (= (ebox-get (plist-get state :box) :width) 120))
    (should (= (ebox-get (plist-get state :box) :height) 2))
    (dolist (property '(:scroll-offset :content-height
                       :content-lines-complete-p))
      (should (equal (plist-get state property) (plist-get old-state property))))
    (should (equal-including-properties
             (ebox-lines-join (plist-get state :content-lines))
             (ebox-lines-join (plist-get old-state :content-lines))))))

(ert-deftest ebox-flex-natural-reuse-preserves-stretched-visible-overflow-ownership ()
  "Stretch sizing should absorb visible overflow into the final box region."
  (let* ((box (ebox-test-box (ebox-test-text "A\nB") :width '(80) :height 1
                           :overflow 'visible :flex-grow 1))
         (region-id (car (ebox-region-ids (ebox-test-root box))))
         (rendered (ebox-render (ebox-test-flex :width '(120) box)))
         (lines (ebox-string-lines rendered)))
    (should (= (length lines) 2))
    (should (= (ebox-flex-test--region-owner-width
                (nth 1 lines) region-id)
               120))))

(ert-deftest ebox-flex-stretch-padding-retains-child-allocation-owner ()
  "Cross-axis blank lines remain part of the stretched child fragment."
  (let* ((child (ebox-test-box (ebox-test-text "A") :width '(80)))
         (region-id (car (ebox-region-ids (ebox-test-root child))))
         (layout
          (ebox-test-flex :width '(120) :height 3 :align-items 'stretch
            child))
         (lines (ebox-string-lines (ebox-render layout))))
    (should (= (length lines) 3))
    (dolist (line lines)
      (should
       (text-property-not-all
        0 (length line) 'ebox-content-owners nil line))
      (should
       (cl-some
        (lambda (position)
          (memq region-id
                (get-text-property position 'ebox-content-owners line)))
        (number-sequence 0 (1- (length line))))))))

(ert-deftest ebox-flex-natural-reuse-preserves-stretched-scroll-state ()
  "Stretch sizing should publish the final box geometry to scroll state."
  (let* ((ebox-viewport-width 120)
         (ebox-viewport-height 2)
         (layout
          (ebox-build
           '(flex :width (120)
              (box :id "root" :width (80) :height (viewport-height)
                   :overflow scroll :flex-grow 1
                (column :width (80)
                  (box :height 1 "A")
                  (box :height 1 "B")
                  (box :height 1 "C")
                  (box :height 1 "D"))))))
         (buffer (generate-new-buffer " *ebox-flex-scroll-state*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer buffer layout)
          (let* ((match (car (ebox-selector-query-buffer buffer "#root")))
                 (state (ebox-scroll-state (plist-get match :region-id))))
            (should (equal (ebox-get (plist-get state :box) :height) 2))
            (should-not (plist-get state :content-lines-complete-p))
            (should-not (plist-get state :render-content-prefix))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-flex-natural-row-padding-keeps-overflow-line-local ()
  "Visible overflow should widen only the line that actually overflows."
  (let* ((viewport-child
          (ebox-test-box (ebox-test-text "A") :width '(viewport)
                       :box-sizing 'content-box
                       :padding-left '(10) :padding-right '(10)))
         (source
          (ebox-test-column viewport-child
                       (ebox-test-box (ebox-test-text "A2") :width '(20))))
         (layout
          (ebox-test-flex :width '(240)
            (ebox-test-flex-item source :flex-basis '(20))
            (ebox-test-box (ebox-test-text "B") :width '(20) :height 4)))
         (widths
          (mapcar #'ebox--string-pixel-width
                  (ebox-string-lines (ebox-render layout)))))
    (should (= (length widths) 4))
    (should (= (car widths) 260))
    (should (equal (cdr widths) '(240 240 240)))))

(ert-deftest ebox-flex-composite-auto-row-respects-assigned-width ()
  "A composite auto-width row must not duplicate its Flex item viewport."
  (let* ((layout
          (ebox-test-flex :width '(120)
            (ebox-test-row
             (ebox-test-box (ebox-test-text "Left") :border '(1 solid))
             (ebox-test-box (ebox-test-text "Right") :border '(1 solid)))))
         (widths (mapcar #'ebox--string-pixel-width
                         (ebox-string-lines (ebox-render layout)))))
    (should (cl-every (lambda (width) (<= width 120)) widths))))

(ert-deftest ebox-flex-sized-persistent-hit-populates-pass-local-cache ()
  "Persistent sized renders should become reusable in the current pass."
  (let* ((source-input (ebox-test-box (ebox-test-text "A") :width '(80)))
         (source (ebox-test-root source-input))
         (ebox--render-cache-table (make-hash-table :test 'equal))
         (ebox--render-cache-signature-cache (make-hash-table :test 'eq))
         (ebox--surface-materialization-active t)
         (first (car (ebox--flex-collect-items (list source) 'row 220)))
         (main (plist-get first :target))
         (cache-key (list 'row main nil 'flex-start)))
    (ebox--flex-render-sized-entry first 'row main nil 'flex-start)
    (should (assoc cache-key (plist-get first :render-cache)))
    (let ((second (car (ebox--flex-collect-items (list source) 'row 220))))
      (should-not (assoc cache-key (plist-get second :render-cache)))
      (ebox--flex-render-sized-entry second 'row main nil 'flex-start)
      (should (assoc cache-key (plist-get second :render-cache))))))

(defun ebox-flex-test--face-signature (string)
  "Return a printed list of every face value carried by STRING."
  (let ((faces nil)
        (pos 0)
        (len (length string)))
    (while (< pos len)
      (push (get-text-property pos 'face string) faces)
      (setq pos (or (next-single-property-change pos 'face string) len)))
    (format "%S" (nreverse faces))))

(ert-deftest ebox-flex-measurement-miss-probes-cache-once ()
  "A flex measurement miss should compute one exact cache probe."
  (let* ((source-input
          (ebox-test-box (ebox-test-text "Measured once") :width '(80)))
         (source (ebox-test-root source-input))
         (props '(:flex-basis auto))
         (ebox--render-cache-table (make-hash-table :test 'equal))
         (ebox--render-cache-signature-cache (make-hash-table :test 'eq))
         (ebox--viewport-dependent-subtree-cache (make-hash-table :test 'eq))
         (ebox--surface-materialization-active t)
         (signature-calls 0)
         (lookup-calls 0)
         (original-signature
          (symbol-function 'ebox--flex-render-cache-signature))
         (original-lookup (symbol-function 'ebox--render-cache-lookup)))
    (cl-letf (((symbol-function 'ebox--flex-render-cache-signature)
               (lambda (node)
                 (cl-incf signature-calls)
                 (funcall original-signature node)))
              ((symbol-function 'ebox--render-cache-lookup)
               (lambda (cache-key signature &rest arguments)
                 (when (and (consp cache-key)
                            (eq (nth 1 cache-key) 'flex-measure))
                   (cl-incf lookup-calls))
                 (apply original-lookup cache-key signature arguments))))
      (ebox--flex-item-measurement source props 'row 120))
    (should (= signature-calls 1))
    (should (= lookup-calls 1))))

(ert-deftest ebox-flex-signature-prepares-identities-once-before-memoization ()
  "Cold and warm signatures stabilize nested identities through one owner."
  (let (observed)
    (dolist (region-memo-p '(nil t))
      (let* ((root
              (ebox-test-root
               (ebox-test-flex :width '(120)
                 (ebox-test-box :width '(40) (ebox-test-text "left"))
                 (ebox-test-column
                  (ebox-test-text "right")
                  (ebox-test-box (ebox-test-text "nested"))))))
             (ebox--render-cache-signature-cache (make-hash-table :test 'eq))
             (ebox--node-region-ids-cache
              (and region-memo-p (make-hash-table :test 'eq)))
             (runtime-ids (symbol-function 'ebox--runtime-node-ids))
             (region-ids (symbol-function 'ebox--node-all-region-ids))
             (body-signature (symbol-function 'ebox--render-cache-node-body-signature))
             (runtime-calls 0) (region-calls 0) (body-calls 0)
             nodes identity-snapshots signatures memoized-body)
        (cl-labels ((walk (node)
                      (push node nodes)
                      (mapc #'walk (ebox-tree-node-children node))))
          (walk root))
        (dolist (node nodes)
          (should-not (plist-get node :node-id))
          (should-not (plist-get node :region-id)))
        (cl-letf
            (((symbol-function 'ebox--runtime-node-ids)
              (lambda (node)
                ;; Recursive child entries are real work, not extra root probes.
                (when (eq node root) (cl-incf runtime-calls))
                (funcall runtime-ids node)))
             ((symbol-function 'ebox--node-all-region-ids)
              (lambda (node)
                (when (eq node root) (cl-incf region-calls))
                (funcall region-ids node)))
             ((symbol-function 'ebox--render-cache-node-body-signature)
              (lambda (node)
                (when (eq node root)
                  (cl-incf body-calls)
                  ;; Inspect before the real memoizing helper can read or write
                  ;; its cache; the first cached body must include every id.
                  (push
                   (mapcar
                    (lambda (child)
                      (should (integerp (plist-get child :node-id)))
                      (when (eq (plist-get child :ebox-type) 'box)
                        (should (integerp (plist-get child :region-id))))
                      (list (plist-get child :node-id)
                            (plist-get child :region-id)))
                    nodes)
                   identity-snapshots))
                (funcall body-signature node))))
          (dolist (phase '(cold warm))
            (setq runtime-calls 0 region-calls 0 body-calls 0)
            (when (eq phase 'warm)
              (should (eq memoized-body
                          (gethash root ebox--render-cache-signature-cache))))
            (push (ebox--flex-render-cache-signature root) signatures)
            (push (list region-memo-p phase runtime-calls region-calls body-calls)
                  observed)
            (if (eq phase 'cold)
                (setq memoized-body
                      (gethash root ebox--render-cache-signature-cache))
              (should (eq memoized-body
                          (gethash root ebox--render-cache-signature-cache))))))
        (should memoized-body)
        (should (equal (car signatures) (cadr signatures)))
        (should (equal (car signatures) (ebox--render-cache-node-signature root)))
        (should (equal (car identity-snapshots) (cadr identity-snapshots)))
        (when region-memo-p
          (should (gethash root ebox--node-region-ids-cache)))))
    (setq observed (nreverse observed))
    (message "Flex signature root entries (region-memo phase runtime region body): %S"
             observed)
    (should (equal observed '((nil cold 1 1 1) (nil warm 1 1 1)
                             (t cold 1 1 1) (t warm 1 1 1))))))

(ert-deftest ebox-flex-reuses-direct-column-natural-measurement ()
  "A direct Column's nil-viewport natural size should survive parent resize."
  (let* ((source-input
          (ebox-test-column
           (ebox-test-box (ebox-test-text "A") :width '(80))
           (ebox-test-box (ebox-test-text "B") :width '(80))))
         (source (ebox-test-root source-input))
         (props '(:flex-basis auto))
         (ebox--render-cache-table (make-hash-table :test 'equal))
         (ebox--render-cache-signature-cache (make-hash-table :test 'eq))
         (ebox--viewport-dependent-subtree-cache (make-hash-table :test 'eq))
         (ebox--surface-materialization-active t)
         (renders 0)
         (original
          (symbol-function 'ebox--flex-render-source-for-measurement)))
    (cl-letf (((symbol-function 'ebox--flex-render-source-for-measurement)
               (lambda (&rest arguments)
                 (cl-incf renders)
                 (apply original arguments))))
      (ebox--flex-item-measurement source props 'row 320)
      (ebox--flex-item-measurement source props 'row 640))
    (should (= renders 1))))

(ert-deftest ebox-flex-fixed-basis-wrapped-box-skips-intrinsic-render ()
  "Known flex metrics should not render a wrapped fixed-basis box twice."
  (let* ((source
          (ebox-test-box
           (ebox-test-text "A responsive wrapped child")
           :width '(viewport) :min-width 0 :height 4 :wrap-mode 'word))
         (item
          (ebox-test-flex-item
           source :flex-grow 1 :flex-shrink 1 :flex-basis '(80)))
         (layout (ebox-test-flex :width '(240) :height 4 item))
         (ebox-viewport-width 240)
         (measurement-renders 0)
         fast slow)
    (let ((original
           (symbol-function 'ebox--flex-render-source-for-measurement)))
      (cl-letf (((symbol-function 'ebox--flex-render-source-for-measurement)
                 (lambda (&rest arguments)
                   (cl-incf measurement-renders)
                   (apply original arguments))))
        (setq fast (ebox-render layout))))
    (should (zerop measurement-renders))
    (cl-letf (((symbol-function 'ebox--flex-unrendered-measurement)
               (lambda (&rest _) nil)))
      (setq slow (ebox-render layout)))
    (should (equal-including-properties fast slow))))

(ert-deftest ebox-flex-fixed-basis-nowrap-box-keeps-intrinsic-measurement ()
  "No-wrap auto minimums should retain their intrinsic render measurement."
  (let* ((source-input
          (ebox-test-box (ebox-test-text "UNBREAKABLE") :min-width 0 :height 1
                       :wrap-mode 'none))
         (source (ebox-test-root source-input))
         (item-input (ebox-test-flex-item source-input :flex-basis '(40)))
         (props
          (ebox--flex-item-props (ebox-test-root item-input))))
    (should-not (ebox--flex-unrendered-measurement source props 'row))))

(ert-deftest ebox-flex-explicit-zero-min-width-allows-no-wrap-shrink ()
  "An explicit zero minimum lets a no-wrap card shrink in its Flex line."
  (let* ((source-input
          (ebox-test-box (ebox-test-text "A long no-wrap card title")
                       :min-width 0 :wrap-mode 'none))
         (source (ebox-test-root source-input))
         (rendered (ebox-render source-input)))
    (should (zerop (ebox--flex-box-min-main source rendered 'row)))))

(ert-deftest ebox-flex-bounded-auto-basis-keeps-intrinsic-measurement ()
  "Clipping must not replace an auto-basis item's intrinsic contribution."
  (let* ((source-input
          (ebox-test-box (ebox-test-text "UNBREAKABLE") :width '(120) :height 2
                       :min-width 0 :wrap-mode 'none :overflow 'hidden))
         (source (ebox-test-root source-input))
         (props (ebox--flex-item-props source)))
    (should (eq (plist-get props :flex-basis) 'auto))
    (should-not (ebox--flex-unrendered-measurement source props 'row))))

(ert-deftest ebox-flex-column-natural-cache-respects-final-cross-viewport ()
  "Column flex must render composite items in the final cross viewport."
  (let* ((viewport-child
          (ebox-test-box (ebox-test-text "VP") :width '(viewport)))
         (source-input
          (ebox-test-column
           viewport-child
           (ebox-test-box (ebox-test-text "F") :width '(100))))
         (source (ebox-test-root source-input))
         (region-id
          (car (ebox-region-ids (ebox-test-root viewport-child))))
         (layout
          (ebox-test-flex :height 4
                     :flex-direction 'column
                     :align-items 'stretch
            (ebox-test-flex-item source-input :flex-grow 1 :flex-basis 2)))
         (rendered (ebox-render layout)))
    (should (ebox-box-node-p source))
    (should (eq (ebox-layout-config-kind (ebox-box-node-layout source))
                'column))
    (should (= (ebox-flex-test--region-owner-width rendered region-id)
               100))))

(ert-deftest ebox-flex-nowrap-explicit-cross-skips-natural-cross-measure ()
  "Nowrap containers with fixed cross size should not measure natural cross."
  (let* ((layout
          (ebox-test-flex :width '(220) :height 4 :flex-wrap 'nowrap
            (ebox-test-box (ebox-test-text "A") :width '(80))
            (ebox-test-box (ebox-test-text "B") :width '(80))))
         (calls 0)
         (original (symbol-function 'ebox--flex-line-cross)))
    (cl-letf (((symbol-function 'ebox--flex-line-cross)
               (lambda (&rest args)
                 (cl-incf calls)
                 (apply original args))))
      (ebox-render layout))
    (should (= calls 0))))

(ert-deftest ebox-flex-aligns-items-on-row-cross-axis ()
  "Align-items center should move short row items within the line height."
  (let* ((layout
          (ebox-test-flex :width '(180) :height 3 :align-items 'center
            (ebox-test-box (ebox-test-text "A") :width '(80) :height 1)
            (ebox-test-box (ebox-test-text "B\nB\nB") :width '(80) :height 3)))
         (lines (ebox-flex-test--plain-lines layout)))
    (should (= (length lines) 3))
    (should (= (cl-position-if (lambda (line)
                                 (string-match-p "A" line))
                               lines)
               1))))

(ert-deftest ebox-flex-honors-order-and-reverse-directions ()
  "Order and reverse directions should change visual item order."
  (let* ((ordered
          (ebox-test-flex
            (ebox-test-flex-item (ebox-test-box (ebox-test-text "A") :width '(40)) :order 2)
            (ebox-test-flex-item (ebox-test-box (ebox-test-text "B") :width '(40)) :order 1)))
         (column-reverse
          (ebox-test-flex :flex-direction 'column-reverse
            (ebox-test-box (ebox-test-text "A") :width '(40))
            (ebox-test-box (ebox-test-text "B") :width '(40)))))
    (should (string-match-p "B.*A"
                            (car (ebox-flex-test--plain-lines ordered))))
    (should (string-match-p "B"
                            (car (ebox-flex-test--plain-lines column-reverse))))))

(ert-deftest ebox-flex-align-self-overrides-align-items ()
  "Align-self should override the container cross-axis alignment."
  (let* ((layout
          (ebox-test-flex :width '(180) :height 3 :align-items 'flex-start
            (ebox-test-flex-item
             (ebox-test-box (ebox-test-text "A") :width '(80) :height 1)
             :align-self 'flex-end)
            (ebox-test-box (ebox-test-text "B\nB\nB") :width '(80) :height 3)))
         (lines (ebox-flex-test--plain-lines layout)))
    (should (= (length lines) 3))
    (should (= (cl-position-if (lambda (line)
                                 (string-match-p "A" line))
                               lines)
               2))))

(ert-deftest ebox-flex-wrap-single-line-align-content-keeps-natural-cross-size ()
  "A wrapped one-line container should still use multi-line align-content rules."
  (let* ((layout
          (ebox-test-flex :width '(180) :height 4
            :flex-wrap 'wrap
            :align-content 'flex-start
            :align-items 'center
            (ebox-test-box (ebox-test-text "A") :width '(60) :height 1)))
         (lines (ebox-flex-test--plain-lines layout)))
    (should (= (length lines) 4))
    (should (= (cl-position-if (lambda (line)
                                 (string-match-p "A" line))
                               lines)
               0))))

(ert-deftest ebox-flex-applies-container-box-properties ()
  "Flex container visual box properties should render around the flex layout."
  (let* ((layout
          (ebox-test-flex :width '(160) :box-sizing 'border-box
            :padding '(1 (8))
            :border '(1 "#ff0000")
            :bgcolor "#101010"
            (ebox-test-box (ebox-test-text "A") :width '(60))))
         (rendered (ebox-flex-test--render layout))
         (left-face (ebox-flex-test--face-at-property rendered 'ebox-bl))
         (right-face (ebox-flex-test--face-at-property rendered 'ebox-br))
         (top-face (ebox-flex-test--face-at-property rendered 'ebox-bt))
         (bottom-face (ebox-flex-test--face-at-property rendered 'ebox-bb))
         (content-face (ebox-flex-test--face-at-property rendered 'ebox-content)))
    (should (equal (ebox-flex-test--line-widths layout) '(160 160 160)))
    (should (ebox-flex-test--face-has-key-value-p
             left-face :background "#ff0000"))
    (should (ebox-flex-test--face-has-key-value-p
             right-face :background "#ff0000"))
    (should (ebox-flex-test--face-has-key-value-p top-face :overline "#ff0000"))
    (should (ebox-flex-test--face-has-key-value-p
             bottom-face
             :underline
             '(:position t :color "#ff0000")))
    (should (ebox-flex-test--face-has-key-value-p
             content-face :background "#101010"))))

(ert-deftest ebox-flex-container-box-preserves-blank-child-bottom-border ()
  "A visual flex container should preserve child bottom borders on blank lines."
  (let* ((child (ebox-test-box (ebox-test-text "A")
                             :width '(80)
                             :height 2
                             :padding '(0 (6))
                             :border '(1 "#00aa00")
                             :flex-basis '(80)))
         (child-id (car (ebox-region-ids (ebox-test-root child))))
         (layout (ebox-test-flex :width '(140)
                   :padding '(1 (4))
                   :border '(1 "#444444")
                   child))
         (rendered (ebox-flex-test--render layout)))
    (should (memq child-id
                  (ebox-flex-test--property-values rendered 'ebox-bb)))))

(ert-deftest ebox-flex-container-box-wrapper-preserves-rendered-layout ()
  "A flex container box wrapper should not rewrap the rendered flex layout."
  (cl-letf (((symbol-function 'require)
             (lambda (feature &optional _filename _noerror)
               (when (eq feature 'ekp) t)))
            ((symbol-function 'ekp-pixel-justify)
             (lambda (text _width)
               (if (string-match-p "\n" text)
                   "REWRAPPED"
                 text))))
    (let* ((layout
            (ebox-test-flex :width '(260) :height 3 :border "gray"
              :flex-flow '(row wrap)
              :justify-content 'space-between
              (ebox-test-box (ebox-test-text "sample box two")
                           :height 3
                           :box-sizing 'border-box
                           :padding '(0 (8))
                           :border '(1 solid)
                           :wrap-mode 'none)
              (ebox-test-box (ebox-test-text "sample box three")
                           :height 3
                           :box-sizing 'border-box
                           :padding '(0 (8))
                           :border '(1 solid)
                           :wrap-mode 'none)))
           (plain (substring-no-properties (ebox-flex-test--render layout))))
      (should-not (string-match-p "REWRAPPED" plain))
      (should (string-match-p "sample box two" plain))
      (should (string-match-p "sample box three" plain)))))

(ert-deftest ebox-flex-item-applies-box-properties-with-flex-metadata ()
  "An item wrapper should keep flex metadata and apply visual box properties."
  (let* ((layout
          (ebox-test-flex :width '(180)
            (ebox-test-flex-item
             (ebox-test-box (ebox-test-text "A") :width '(60))
             :flex 1
             :box-sizing 'border-box
             :padding '(0 (6))
             :border '(1 "#00aa00"))))
         (rendered (ebox-flex-test--render layout))
         (left-face (ebox-flex-test--face-at-property rendered 'ebox-bl))
         (right-face (ebox-flex-test--face-at-property rendered 'ebox-br))
         (top-face (ebox-flex-test--face-at-property rendered 'ebox-bt))
         (bottom-face (ebox-flex-test--face-at-property rendered 'ebox-bb)))
    (should (equal (ebox-flex-test--line-widths layout) '(180)))
    (should (string-match-p "A" (substring-no-properties rendered)))
    (should (ebox-flex-test--face-has-key-value-p
             left-face :background "#00aa00"))
    (should (ebox-flex-test--face-has-key-value-p
             right-face :background "#00aa00"))
    (should (ebox-flex-test--face-has-key-value-p top-face :overline "#00aa00"))
    (should (ebox-flex-test--face-has-key-value-p
             bottom-face
             :underline
             '(:position t :color "#00aa00")))))

(ert-deftest ebox-flex-item-wrapper-preserves-preformatted-layout ()
  "An item wrapper with box properties should not rewrap rendered children."
  (cl-letf (((symbol-function 'require)
             (lambda (feature &optional _filename _noerror)
               (when (eq feature 'ekp) t)))
            ((symbol-function 'ekp-pixel-justify)
             (lambda (text _width)
               (if (string-match-p "\n" text)
                   "REWRAPPED"
                 text))))
    (let* ((layout
            (ebox-test-flex :width '(220)
              (ebox-test-flex-item
               (ebox-test-column
                (ebox-test-box (ebox-test-text "Top") :width '(80))
                (ebox-test-box (ebox-test-text "Bottom") :width '(80)))
               :width '(180)
               :box-sizing 'border-box
               :border '(1 solid))))
           (plain (substring-no-properties (ebox-flex-test--render layout))))
      (should-not (string-match-p "REWRAPPED" plain))
      (should (string-match-p "Top" plain))
      (should (string-match-p "Bottom" plain)))))

(ert-deftest ebox-flex-neutral-size-properties-keep-child-identity ()
  "Width, height, and box-sizing alone should not wrap a flex container."
  (dolist (props '((:width (120))
                   (:height 2)
                   (:box-sizing border-box)))
    (let* ((left (ebox-test-box (ebox-test-text "A") :width '(40)))
           (right (ebox-test-box (ebox-test-text "B") :width '(40)))
           (layout
            (apply #'ebox-test-flex
                   (append props (list left right)))))
      (should (equal (ebox-box-node-children (ebox-test-root layout))
                     (mapcar #'ebox-test-root (list left right))))
      (should (string-match-p "A.*B"
                              (substring-no-properties
                               (ebox-flex-test--render layout)))))))

(ert-deftest ebox-flex-box-sizing-alone-keeps-child-region-ids ()
  "Box-sizing by itself should not wrap a flex container."
  (let* ((left (ebox-test-box (ebox-test-text "A") :width '(40)))
         (right (ebox-test-box (ebox-test-text "B") :width '(40)))
         (layout
          (ebox-test-flex :width '(120) :box-sizing 'border-box left right)))
    (should (equal (ebox-box-node-children (ebox-test-root layout))
                   (mapcar #'ebox-test-root (list left right))))
    (should (equal (ebox-flex-test--line-widths layout) '(120)))))

(ert-deftest ebox-flex-direct-child-combines-frame-and-participation ()
  "One child Box should own both frame and Flex participation facts."
  (let* ((left (ebox-test-box (ebox-test-text "A") :width '(60)
                            :flex-grow 1 :flex-basis '(60)
                            :box-sizing 'border-box :border '(1 solid)))
         (right (ebox-test-box (ebox-test-text "B") :width '(40)))
         (layout (ebox-test-flex :width '(160) left right))
         (left-id (car (ebox-region-ids (ebox-test-root left))))
         (right-id (car (ebox-region-ids (ebox-test-root right))))
         (rendered (ebox-flex-test--render layout))
         (left-width
          (ebox-flex-test--region-owner-width rendered left-id))
         (right-width
          (ebox-flex-test--region-owner-width rendered right-id)))
    (should (equal (ebox-box-node-children (ebox-test-root layout))
                   (mapcar #'ebox-test-root (list left right))))
    (should (> left-width 60))
    (should (> left-width right-width))))

(ert-deftest ebox-flex-wraps-before-shrinking-no-wrap-item-below-minimum ()
  "A no-wrap flex item should keep its rendered minimum width when wrapping."
  (let* ((layout
          (ebox-test-flex :width '(160)
            :flex-flow '(row wrap)
            :column-gap '(10)
            (ebox-test-flex-item
             (ebox-test-box (ebox-test-text "wide no-wrap label")
                          :width '(150)
                          :box-sizing 'border-box
                          :wrap-mode 'none)
             :flex 1)
            (ebox-test-box (ebox-test-text "B") :width '(120))))
         (lines (ebox-flex-test--plain-lines layout)))
    (should (= (length lines) 2))
    (should (cl-every (lambda (width) (<= width 160))
                      (ebox-flex-test--line-widths layout)))
    (should (string-match-p "wide no-wrap label" (car lines)))
    (should (string-match-p "B" (cadr lines)))))

(ert-deftest ebox-flex-supports-standard-value-matrix ()
  "Every supported flex value should render without falling out of the model."
  (dolist (direction '(row row-reverse column column-reverse))
    (should (stringp
             (ebox-render
              (ebox-test-flex :width '(220) :height 4 :flex-direction direction
                (ebox-test-box (ebox-test-text "A") :width '(60) :height 1)
                (ebox-test-box (ebox-test-text "B") :width '(60) :height 1))))))
  (dolist (wrap '(nowrap wrap wrap-reverse))
    (should (stringp
             (ebox-render
              (ebox-test-flex :width '(130) :height 4 :flex-wrap wrap
                (ebox-test-box (ebox-test-text "A") :width '(60) :height 1)
                (ebox-test-box (ebox-test-text "B") :width '(60) :height 1)
                (ebox-test-box (ebox-test-text "C") :width '(60) :height 1))))))
  (dolist (justify '(normal start end flex-start flex-end center stretch
                    space-between space-around space-evenly))
    (should (stringp
             (ebox-render
              (ebox-test-flex :width '(220) :justify-content justify
                (ebox-test-box (ebox-test-text "A") :width '(60))
                (ebox-test-box (ebox-test-text "B") :width '(60)))))))
  (dolist (align '(normal start end stretch flex-start flex-end center baseline))
    (should (stringp
             (ebox-render
              (ebox-test-flex :width '(220) :height 4
                :align-items align
                (ebox-test-box (ebox-test-text "A") :width '(60) :height 1)
                (ebox-test-box (ebox-test-text "B") :width '(60) :height 1))))))
  (dolist (align '(normal start end stretch flex-start flex-end center
                  space-between space-around space-evenly))
    (should (stringp
             (ebox-render
              (ebox-test-flex :width '(130) :height 5 :flex-wrap 'wrap
                :align-content align
                (ebox-test-box (ebox-test-text "A") :width '(60) :height 1)
                (ebox-test-box (ebox-test-text "B") :width '(60) :height 1)
                (ebox-test-box (ebox-test-text "C") :width '(60) :height 1)))))))

(ert-deftest ebox-flex-allocation-content-keeps-warm-child-scroll-clears ()
  "Distinct allocation copies retain a warm child's A-to-B-to-A clears."
  (let* ((child (ebox-test-root
                 (ebox-test-box
                     (ebox-test-text (propertize "first\nsecond" 'help-echo "kept"))
                   :width '(80) :height 3 :overflow 'scroll)))
         (source (ebox-test-root
                  (ebox-test-box (ebox-test-text "parent") :width 'stretch)))
         (ebox--surface-materialization-active t)
         (ebox--render-cache-table (make-hash-table :test 'equal))
         (ebox--box-content-render-cache (make-hash-table :test 'eq))
         (ebox--region-box-table (make-hash-table :test 'equal))
         (ebox--scroll-global-state (make-hash-table :test 'equal))
         (ebox--scroll-idle-prefetch-timers (make-hash-table :test 'equal))
         (ebox--render-cache-scroll-state-region-ids (make-hash-table :test 'equal))
         ;; Normal bounded eviction removes the old child entry after B.
         (ebox-render-cache-max-entries 1)
         (warm (ebox--render-with-cache child))
         (region-id (plist-get child :region-id))
         (calls 0) first-admitted actual final-state)
    (should (plist-member (ebox--render-cache-probe child) :rendered))
    (should-not (gethash region-id ebox--scroll-global-state))
    (cl-labels ((render-parent (width renderer)
                  (ebox--render-box-content-cached
                   (ebox--flex-copy-node-for-size source 'row width nil t)
                   renderer))
                (render-a ()
                  (cl-incf calls)
                  (ebox--render-with-cache child)))
      (should (equal-including-properties
               warm (render-parent 120 #'render-a)))
      (setq first-admitted (and (gethash source ebox--box-content-render-cache) t))
      (render-parent
       150
       (lambda ()
         (ebox--render-with-cache
          (ebox--flex-copy-node-for-size child 'row 80 1 t))))
      (should (gethash region-id ebox--scroll-global-state))
      (should-not (plist-member (ebox--render-cache-probe child) :rendered))
      (setq actual (render-parent 120 #'render-a)
            final-state (gethash region-id ebox--scroll-global-state))
      (let ((ebox--box-content-render-cache nil))
        (should (equal-including-properties actual (ebox--render-with-cache child)))))
    (should (equal-including-properties warm actual))
    (should-not final-state)
    (should-not first-admitted)
    (should (= calls 2))))

(provide 'ebox-flex-tests)
;;; ebox-flex-tests.el ends here
