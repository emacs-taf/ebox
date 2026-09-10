;;; ebox-nested-scroll-tests.el --- Cached nested scroll publication -*- lexical-binding: t; -*-

;;; Commentary:
;; Fixed scroll allocations publish their retained windows locally while
;; preserving ancestor effects, native interaction and TP mount ownership.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ebox)

(defmacro ebox-nested-scroll-test--with-buffer (&rest body)
  "Run BODY with an isolated mounted surface and the Elisp renderer."
  (declare (indent 0) (debug t))
  `(cl-letf (((symbol-function 'ebox-native-reflow-layout-ready-p)
              (lambda () nil)))
     (let ((ebox-viewport-width 104) (ebox-viewport-height 30)
           (ebox-runtime-idle-prewarm nil)
           (ebox-runtime-idle-reflow-cache-prewarm nil))
       (with-temp-buffer
         (unwind-protect (progn ,@body)
           (when (ebox-surface-buffer-mounted-p (current-buffer))
             (ebox-unmount-buffer (current-buffer))))))))

(defun ebox-nested-scroll-test--input (&optional layout chrome peers)
  "Build a scroll owner under LAYOUT with CHROME and PEERS other boxes."
  (ebox-build
   `(column :id "root" :width (px 104) :color "#204060"
      (box :id "before" "before")
      (,(or layout 'column)
       ,@(pcase layout
           ('row '(:width (px 104)))
           ('flex '(:width (px 104) :gap ((lh 0) (px 2))))
           ('grid '(:width (px 104) :grid-template-columns ((px 80) (px 20)))))
       :background-color "#E0E8F0" :padding-left (px 2)
       (box :id "scroll" :width (px 80) :height (lh 5) :overflow scroll
            ,@(when chrome '(:padding ((lh 1) (px 1)) :border-width (px 1)
                             :border-style solid :border-color "#456789"))
            ,@(cl-loop for number below 30
                       collect `(box :id ,(format "line-%d" number)
                                     :help-echo ,(format "line %d" number)
                                     :pointer hand
                                     :hover-style (:background-color "#FFFFA0")
                                     :keymap (keymap (13 . ignore))
                                     ,(format "line %02d" number))))
       (box :id "sibling" :width (px 20) "sibling"))
      ,@(cl-loop for index below (or peers 0)
                 collect `(box :id ,(format "peer-%d" index) "peer"))
      (box :id "after" "after"))))

(defun ebox-nested-scroll-test--region (id)
  "Return ID's runtime region in the current mounted buffer."
  (cdr (ebox-selector--region-target (ebox-region-resolve (current-buffer) id))))

(defun ebox-nested-scroll-test--mounts (&optional preserve-order-p)
  "Return semantic IDs and their live mount ranges in the current buffer.
PRESERVE-ORDER-P retains attachment order for exact rollback checks."
  (mapcar
   (lambda (id)
     (let* ((region (ebox-nested-scroll-test--region id))
            (state (ebox--buffer-render-state (current-buffer)))
            (object (gethash region (plist-get state :region-surface-object-table))))
       (let ((ranges (mapcar (lambda (mount)
                              (cons (plist-get mount :start) (plist-get mount :end)))
                            (tp-object-mounts object))))
         (cons id (if preserve-order-p ranges
                    (sort ranges
                          (lambda (left right)
                            (if (= (car left) (car right)) (< (cdr left) (cdr right))
                              (< (car left) (car right))))))))))
   (append '("before" "scroll" "sibling" "after")
           (cl-loop for index below 30 collect (format "line-%d" index)))))

(defun ebox-nested-scroll-test--parity ()
  "Compare current paint, interactions and mounts with fresh committed input."
  (let* ((state (ebox--buffer-render-state (current-buffer)))
         (ebox-viewport-width (plist-get state :viewport-width))
         (ebox-viewport-height (plist-get state :viewport-height))
         (input (plist-get (ebox-surface-buffer-snapshot (current-buffer)) :input))
         (actual (buffer-string))
         (mounts (ebox-nested-scroll-test--mounts)))
    (with-temp-buffer
      (unwind-protect
          (progn
            (ebox-render-to-buffer (current-buffer) input)
            (should (equal (substring-no-properties actual)
                           (buffer-substring-no-properties (point-min) (point-max))))
            (dotimes (position (length actual))
              (dolist (property '(face display help-echo mouse-face pointer keymap))
                (should (equal (get-text-property position property actual)
                               (get-text-property (1+ position) property)))))
            (should (equal mounts (ebox-nested-scroll-test--mounts))))
        (when (ebox-surface-buffer-mounted-p (current-buffer))
          (ebox-unmount-buffer (current-buffer)))))))

(ert-deftest ebox-nested-scroll-retained-fragments-own-newline-separators ()
  "Retained paint ledgers cover separators with both neighboring owners."
  (let* ((lines (list (propertize "before" 'ebox-content-owner 1)
                      (propertize "inside" 'ebox-content-owner 2)
                      (propertize "after" 'ebox-content-owner 3)))
         (output (ebox-lines-join lines))
         (retained (ebox-surface--scroll-fragment-data lines output))
         (fresh (ebox-surface--rendered-fragments (copy-sequence output))))
    (cl-labels ((roles-at (fragments position)
                  (plist-get
                   (cl-find-if (lambda (fragment)
                                 (and (<= (plist-get fragment :start) position)
                                      (< position (plist-get fragment :end))))
                               fragments)
                   :role-ids)))
      (dotimes (position (length output))
        (should (equal (roles-at retained position) (roles-at fresh position))))
      (should (equal (roles-at retained 6) '((content-owner . 1) (content-owner . 2))))
      (should (equal (roles-at retained 13) '((content-owner . 2) (content-owner . 3)))))
    ;; Leading/trailing unowned runs also depend on the adjacent line, so
    ;; these retain the complete scanner until that wider context is proved.
    (dolist (boundary '(" unowned" "unowned "))
      (let ((line (copy-sequence boundary)))
        (put-text-property 1 (1- (length line)) 'ebox-content-owner 1 line)
        (should-not (ebox-surface--scroll-line-fragment-template line))))))

(ert-deftest ebox-nested-scroll-cached-window-does-not-render-siblings ()
  "One cached nested window avoids root renders and unrelated node work."
  (ebox-nested-scroll-test--with-buffer
    (ebox-render-to-buffer (current-buffer) (ebox-nested-scroll-test--input nil nil 200))
    (let* ((region (ebox-nested-scroll-test--region "scroll"))
           (owner (ebox--buffer-region-render-owner-node-id (current-buffer) region))
           (child-region (ebox-nested-scroll-test--region "line-0"))
           (child (ebox--buffer-region-render-owner-node (current-buffer) child-region))
           (root-renders 0) (index-builds 0)
           (render (symbol-function 'ebox-surface--render-candidate))
           (layout (symbol-function 'ebox--render-layout))
           (index (symbol-function 'ebox--runtime-index)))
      (dolist (delta '(1 1 -1 -1))
        (cl-letf (((symbol-function 'ebox-surface--render-candidate)
                   (lambda (&rest arguments)
                     (cl-incf root-renders) (apply render arguments)))
                  ((symbol-function 'ebox--runtime-index)
                   (lambda (&rest arguments)
                     (cl-incf index-builds) (apply index arguments)))
                  ((symbol-function 'ebox--render-layout)
                   (lambda (node)
                     (should (equal (plist-get node :node-id) owner))
                     (funcall layout node))))
          (should (= (ebox--surface-scroll-region-by
                      (current-buffer) region delta nil) delta)))
        (should (eq child (ebox--buffer-region-render-owner-node
                           (current-buffer) child-region)))
        (ebox-nested-scroll-test--parity))
      (should (= root-renders 0))
      (should (= index-builds 0))
      (ebox-nested-scroll-test--parity))))

(ert-deftest ebox-nested-scroll-preserves-allocated-layout-and-chrome ()
  "Column, Row, Flex and Grid owners retain paint, slots and scroll identities."
  (dolist (layout '(column row flex grid))
    (dolist (chrome '(nil t))
      (ert-info ((format "layout=%S chrome=%S" layout chrome))
        (ebox-nested-scroll-test--with-buffer
          (ebox-render-to-buffer (current-buffer)
                                 (ebox-nested-scroll-test--input layout chrome))
          (let* ((region (ebox-nested-scroll-test--region "scroll"))
                 (old-state (ebox--buffer-render-state (current-buffer)))
                 (old-box (gethash region (plist-get old-state :region-box-table)))
                 (old-scroll (gethash region (plist-get old-state :scroll-state-table))))
            (cl-letf (((symbol-function 'ebox-surface--render-candidate)
                       (lambda (&rest _) (ert-fail "Nested allocation rendered root"))))
              (should (= (ebox--surface-scroll-region-by
                          (current-buffer) region 1 nil) 1)))
            (let* ((state (ebox--buffer-render-state (current-buffer)))
                   (box (gethash region (plist-get state :region-box-table)))
                   (scroll (gethash region (plist-get state :scroll-state-table))))
              (should-not (eq old-box box))
              (should (eq box (plist-get scroll :box)))
              (should (= (or (ebox-get old-box :scroll-offset) 0) 0))
              (should (= (plist-get old-scroll :scroll-offset) 0))
              (should (= (ebox-get box :scroll-offset) 1))
              (should (= (plist-get scroll :scroll-offset) 1)))
            (ebox-nested-scroll-test--parity)))))))

(ert-deftest ebox-nested-scroll-independent-owners-retain-their-caches ()
  "Side-by-side scrolls keep independent offsets across content and resize."
  (ebox-nested-scroll-test--with-buffer
    (ebox-render-to-buffer (current-buffer) (ebox-nested-scroll-test--input 'row))
    (ebox-region-update "sibling" :height '(lh 5) :overflow 'scroll
                        :content "sibling 0\nsibling 1\nsibling 2\nsibling 3\nsibling 4\nsibling 5\nsibling 6\nsibling 7")
    (let ((left (ebox-nested-scroll-test--region "scroll"))
          (right (ebox-nested-scroll-test--region "sibling")))
      (cl-letf (((symbol-function 'ebox-surface--render-candidate)
                 (lambda (&rest _) (ert-fail "Independent scroll rendered root"))))
        (should (= (ebox--surface-scroll-region-by (current-buffer) right 2 nil) 2)))
      (ebox-nested-scroll-test--parity)
      (let* ((state (ebox--buffer-render-state (current-buffer)))
             (scroll (gethash right (plist-get state :scroll-state-table)))
             (lines (plist-get scroll :content-lines)))
        (cl-letf (((symbol-function 'ebox-surface--render-candidate)
                   (lambda (&rest _) (ert-fail "Independent scroll rendered root"))))
          (should (= (ebox--surface-scroll-region-by (current-buffer) left 1 nil) 1)))
        (let ((next (gethash right (plist-get (ebox--buffer-render-state
                                             (current-buffer)) :scroll-state-table))))
          (should (= (plist-get next :scroll-offset) 2))
          (should (eq (plist-get next :content-lines) lines))))
      (ebox-nested-scroll-test--parity)
      (ebox-region-update "line-1" :content "UPDATED")
      (should (string-match-p "UPDATED" (buffer-string)))
      (ebox-nested-scroll-test--parity)
      (ebox-rerender-buffer-with-context (current-buffer) 120 35)
      (ebox-nested-scroll-test--parity)
      (should (= (ebox--surface-scroll-region-by (current-buffer) left -1 nil) -1))
      (ebox-nested-scroll-test--parity))))

(ert-deftest ebox-nested-scroll-rejection-restores-local-and-fallback-state ()
  "TP rejection restores text, mounts and runtime on local and declined slots."
  (dolist (fallback '(nil t))
    (ebox-nested-scroll-test--with-buffer
      (ebox-render-to-buffer (current-buffer) (ebox-nested-scroll-test--input))
      ;; Arbitrary inherited interactions deliberately require full projection.
      (when fallback (ebox-region-update "root" :help-echo "enclosing action"))
      (let* ((region (ebox-nested-scroll-test--region "scroll"))
             (state (ebox--buffer-render-state (current-buffer)))
             (scroll (gethash region (plist-get state :scroll-state-table)))
             (box (plist-get scroll :box))
             (before (buffer-string))
             (mounts (ebox-nested-scroll-test--mounts t))
             (revision (ebox-surface-buffer-revision (current-buffer)))
             (root-renders 0)
             (render (symbol-function 'ebox-surface--render-candidate)))
        (cl-letf (((symbol-function 'ebox-surface--render-candidate)
                   (lambda (&rest arguments)
                     (cl-incf root-renders) (apply render arguments))))
          (let ((tp--surface-publication-step-function
                 (lambda (step _surface)
                   (when (eq step 'client-state) (error "Reject nested scroll")))))
            (should-error (ebox--surface-scroll-region-by
                           (current-buffer) region 1 nil))))
        (should (eq state (ebox--buffer-render-state (current-buffer))))
        (should (= revision (ebox-surface-buffer-revision (current-buffer))))
        (should (equal-including-properties before (buffer-string)))
        (should (equal mounts (ebox-nested-scroll-test--mounts t)))
        (should (= (plist-get scroll :scroll-offset) 0))
        (should (= (or (ebox-get box :scroll-offset) 0) 0))
        (should (if fallback (> root-renders 0) (= root-renders 0)))
        (should (= (ebox--surface-scroll-region-by (current-buffer) region 1 nil) 1))
        (ebox-nested-scroll-test--parity)))))

(ert-deftest ebox-nested-scroll-updates-enclosing-cache-and-role-membership ()
  "Inner motion repairs enclosing cache coordinates before outer scrolling."
  (ebox-nested-scroll-test--with-buffer
    (ebox-render-to-buffer (current-buffer) (ebox-nested-scroll-test--input nil nil 200))
    (ebox-region-update "root" :height '(lh 15) :overflow 'scroll)
    (let ((inner (ebox-nested-scroll-test--region "scroll"))
          (outer (ebox-nested-scroll-test--region "root"))
          (hidden (ebox-nested-scroll-test--region "line-0"))
          (visible (ebox-nested-scroll-test--region "line-5")))
      (cl-letf (((symbol-function 'ebox-surface--render-candidate)
                 (lambda (&rest _) (ert-fail "Inner scroll rendered enclosing root"))))
        (should (= (ebox--surface-scroll-region-by (current-buffer) inner 1 nil) 1)))
      (let* ((state (ebox--buffer-render-state (current-buffer)))
             (scroll (gethash outer (plist-get state :scroll-state-table)))
             (members (ebox--scroll-state-ensure-content-region-id-set scroll)))
        (should (eq (plist-get scroll :box) (plist-get state :root-node)))
        (should-not (gethash hidden members))
        (should (gethash visible members))
        (let ((bounds (plist-get scroll :region-line-bounds-index))
              (fresh (ebox--scroll-build-region-line-bounds-index
                      (plist-get scroll :content-lines))))
          (should (= (hash-table-count bounds) (hash-table-count fresh)))
          (maphash (lambda (id range) (should (equal range (gethash id bounds)))) fresh)))
      (ebox-nested-scroll-test--parity)
      (ebox-region-update "line-5" :content "NEW VISIBLE")
      (should (string-match-p "NEW VISIBLE" (buffer-string)))
      (ebox-region-update "line-0" :content "NEW HIDDEN")
      (should-not (string-match-p "NEW HIDDEN" (buffer-string)))
      (ebox-nested-scroll-test--parity)
      (should (= (ebox--surface-scroll-region-by (current-buffer) outer 2 nil) 2))
      (ebox-nested-scroll-test--parity)
      ;; The inner allocation is partially clipped at this outer offset.
      (should (= (ebox--surface-scroll-region-by (current-buffer) inner 1 nil) 1))
      (ebox-nested-scroll-test--parity)
      (should (= (ebox--surface-scroll-region-by (current-buffer) outer 10 nil) 10))
      (let ((before (buffer-string)))
        (cl-letf (((symbol-function 'ebox-surface--render-candidate)
                   (lambda (&rest _) (ert-fail "Hidden inner scroll rendered root"))))
          (should (= (ebox--surface-scroll-region-by (current-buffer) inner 1 nil) 1)))
        (should (equal (substring-no-properties before) (buffer-string)))
        (dotimes (position (length before))
          (dolist (property '(face font-lock-face display help-echo keymap mouse-face pointer))
            (should (equal (get-text-property position property before)
                           (get-text-property (1+ position) property)))))
        (ebox-nested-scroll-test--parity))
      (should (= (ebox--surface-scroll-region-by (current-buffer) outer -12 nil) -12))
      (ebox-nested-scroll-test--parity))))

(ert-deftest ebox-nested-scroll-enclosing-cache-rejection-is-atomic ()
  "Rejected inner publication preserves both scroll caches and source boxes."
  (ebox-nested-scroll-test--with-buffer
    (ebox-render-to-buffer (current-buffer) (ebox-nested-scroll-test--input))
    (ebox-region-update "root" :height '(lh 15) :overflow 'scroll)
    (let* ((inner (ebox-nested-scroll-test--region "scroll"))
           (outer (ebox-nested-scroll-test--region "root"))
           (state (ebox--buffer-render-state (current-buffer)))
           (table (plist-get state :scroll-state-table))
           (before (buffer-string))
           (mounts (ebox-nested-scroll-test--mounts t))
           (revision (ebox-surface-buffer-revision (current-buffer)))
           (outer-state (gethash outer table))
           (outer-lines (plist-get outer-state :content-lines)))
      (let ((tp--surface-publication-step-function
             (lambda (step _surface)
               (when (eq step 'client-state) (error "Reject enclosing cache")))))
        (should-error (ebox--surface-scroll-region-by (current-buffer) inner 1 nil)))
      (should (eq state (ebox--buffer-render-state (current-buffer))))
      (should (eq outer-lines (plist-get (gethash outer table) :content-lines)))
      (should (equal-including-properties before (buffer-string)))
      (should (equal mounts (ebox-nested-scroll-test--mounts t)))
      (should (= revision (ebox-surface-buffer-revision (current-buffer))))
      (should (= (plist-get (gethash inner table) :scroll-offset) 0))
      (should (= (ebox--surface-scroll-region-by (current-buffer) inner 1 nil) 1))
      (ebox-nested-scroll-test--parity))))

(ert-deftest ebox-nested-scroll-enclosing-prefix-and-independent-owner-stay-current ()
  "Ancestor prefix growth, materialization and resize retain inner state."
  (ebox-nested-scroll-test--with-buffer
    (ebox-render-to-buffer
     (current-buffer)
     (ebox-build
      `(column :id "root" :width (px 104) :height (vh 50) :overflow scroll
         (box :id "before" "before")
         (column :id "scroll" :width (px 80) :height (vh 20) :overflow scroll
           ,@(cl-loop for n below 100 collect
                      `(box :id ,(format "line-%d" n) :help-echo ,(format "Action %d" n)
                            ,(format "line %02d" n))))
         (box :id "sibling" :width (px 20) :height (lh 6) :overflow scroll
              "sibling 0\nsibling 1\nsibling 2\nsibling 3\nsibling 4\nsibling 5\nsibling 6\nsibling 7")
         ,@(cl-loop repeat 200 collect '(box "peer"))
         (box :id "after" "after"))))
    (let* ((inner (ebox-nested-scroll-test--region "scroll"))
           (outer (ebox-nested-scroll-test--region "root"))
           (other (ebox-nested-scroll-test--region "sibling"))
           (old-outer (ebox--scroll-get-state outer))
           (old-producer (plist-get old-outer :render-content-prefix))
           (count (length (plist-get old-outer :content-lines))))
      (should old-producer)
      (cl-letf (((symbol-function 'ebox-surface--render-candidate)
                 (lambda (&rest _) (ert-fail "Cached inner motion rendered root"))))
        (should (= (ebox--surface-scroll-region-by (current-buffer) inner 1 1) 1)))
      (should-not (eq old-producer (plist-get (ebox--scroll-get-state outer) :render-content-prefix)))
      (let ((lines (plist-get (ebox--scroll-get-state inner) :content-lines)))
        (cl-letf (((symbol-function 'ebox-surface--render-candidate)
                   (lambda (&rest _) (ert-fail "Independent inner motion rendered root"))))
          (should (= (ebox--surface-scroll-region-by (current-buffer) other 1 1) 1)))
        (should (eq lines (plist-get (ebox--scroll-get-state inner) :content-lines))))
      (ebox-nested-scroll-test--parity)
      (dotimes (_ 40)
        (should (= (ebox--surface-scroll-region-by (current-buffer) outer 1 1) 1)))
      (should (> (length (plist-get (ebox--scroll-get-state outer) :content-lines)) count))
      (should (= (ebox--surface-scroll-region-by (current-buffer) outer -40 1) -40))
      (ebox-nested-scroll-test--parity)
      (ebox--scroll-state-materialize-lines outer (ebox--scroll-get-state outer))
      (should (= (ebox--surface-scroll-region-by (current-buffer) outer 1 1) 1))
      (should (= (ebox--surface-scroll-region-by (current-buffer) outer -1 1) -1))
      (ebox-nested-scroll-test--parity)
      (ebox-rerender-buffer-with-context (current-buffer) 120 40)
      (ebox-nested-scroll-test--parity)
      (should (= (plist-get (ebox--scroll-get-state inner) :scroll-offset) 1))
      (should (= (plist-get (ebox--scroll-get-state other) :scroll-offset) 1))
      (should (= (ebox--surface-scroll-region-by (current-buffer) inner -1 1) -1))
      (ebox-nested-scroll-test--parity))))

(provide 'ebox-nested-scroll-tests)
;;; ebox-nested-scroll-tests.el ends here
