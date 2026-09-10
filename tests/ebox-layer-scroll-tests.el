;;; ebox-layer-scroll-tests.el --- Retained layered root scroll -*- lexical-binding: t; -*-

;;; Commentary:
;; Cached root scroll projects composed content without repositioning its layers.
;; Nested owners and active root projections keep their composition boundary.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ebox)

(defmacro ebox-layer-scroll-test--with-buffer (&rest body)
  "Run BODY in an isolated Elisp scroll buffer without native window scrolling."
  (declare (indent 0) (debug t))
  `(cl-letf (((symbol-function 'ebox-native-reflow-layout-ready-p)
              (lambda () nil)))
     (let ((ebox-viewport-width 24) (ebox-viewport-height 8)
           (ebox-native-buffer-scroll nil)
           (ebox-runtime-idle-prewarm nil)
           (ebox-runtime-idle-reflow-cache-prewarm nil)
           (ebox-scroll-lazy-idle-prefetch-lines 0))
       (with-temp-buffer ,@body))))

(defun ebox-layer-scroll-test--input (&optional chrome portal nested)
  "Build a layered scrolling root with CHROME, hidden PORTAL and NESTED owner."
  (ebox-build
   `(column :id "root" :width (ch 20) :height (lh 5) :overflow scroll
            :padding ,(pcase chrome
                        ('fractional '((lh 1) (px 1.5)))
                        ('nil '((lh 0) (ch 0)))
                        (_ '((lh 1) (ch 1))))
            :color "#102030" :background-color "#DDEEFF"
            (box :id "before" "BEFORE")
            (box :id "host" :height (lh 4)
                 (box :id "lower" "BASE0000\nBASE1111\nBASE2222\nBASE3333")
                 (box :id "upper" :position absolute :left (ch 2) :top (lh 1)
                      :width (ch 4) :height (lh 2) :background-color "#334455"
                      :color "#FFFFFF" :pointer hand :help-echo "layer action"
                      :keymap (keymap (13 . ignore)) "TOP1\nTOP2"))
            (box :id "after" "AFTER000\nAFTER111\nAFTER222\nAFTER333")
            ,@(when nested
                '((box :id "nested" :width (ch 10) :height (lh 2)
                       :overflow scroll :padding ((lh 1) (ch 1))
                       "NESTED0\nNESTED1\nNESTED2\nNESTED3")))
            ,@(when portal
                '((box :id "portal-owner" :height (lh 1)
                       (box :id "portal" :position absolute :layer root
                            :anchor "before" :visibility hidden
                            :width (ch 6) :height (lh 1) "PORTAL")))))))

(defun ebox-layer-scroll-test--root-state ()
  "Return the mounted root's current scroll state."
  (let* ((runtime (ebox--buffer-render-state (current-buffer)))
         (root (plist-get runtime :root-node)))
    (gethash (plist-get root :region-id) (plist-get runtime :scroll-state-table))))

(defun ebox-layer-scroll-test--portal-chain-input ()
  "Build two visible anchored root projections through a clipped logical owner."
  (ebox-build
   '(column :id "root" :width (ch 20) :height (lh 6) :overflow scroll
            :padding ((lh 1) (px 1.5)) :margin-left (px 0.5)
            :background-color "#EEF4F8" :color "#173047"
      (box "PRE0\nPRE1\nPRE2")
      (box :id "clipped-owner" :height (lh 1) :overflow hidden
           (box :id "trigger" :position relative :left (ch 1)
                :width (ch 6) :height (lh 1) "TRIGGER")
           ;; Source order is the reverse of the anchor dependency order.
           (box :id "dependent" :position absolute :layer root
                :anchor "provider-anchor" :placement bottom-end :z-index 9
                :width (ch 5) :height (lh 1) :background-color "#704080"
                :color "#FFFFFF" :pointer hand :help-echo "Dependent action"
                :keymap (keymap (13 . ignore)) "CHAIN")
           (box :id "provider" :position absolute :layer root :anchor "trigger"
                :placement bottom-start :width (ch 7) :height (lh 2)
                :background-color "#206050" :color "#FFFFFF"
                (box :id "provider-anchor" :position relative :left (ch 1)
                     :width (ch 4) :height (lh 1) :help-echo "Provider action"
                     :keymap (keymap (13 . ignore)) "LINK")
                (box "PANEL")))
      (box "POST0\nPOST1\nPOST2\nPOST3\nPOST4\nPOST5\nPOST6\nPOST7"))))

(defun ebox-layer-scroll-test--assert-fresh ()
  "Compare the committed window with an independent render at the same offset."
  (let* ((runtime (ebox--buffer-render-state (current-buffer)))
         (root (plist-get runtime :root-node))
         (offset (ebox-get root :scroll-offset))
         (input (plist-get (ebox-surface-buffer-snapshot (current-buffer)) :input))
         (ebox-viewport-width (plist-get runtime :viewport-width))
         (ebox-viewport-height (plist-get runtime :viewport-height))
         (set-offset
          (lambda (candidate)
            (unless (eq candidate root)
              (ebox-put candidate :scroll-offset offset)
              (ebox-put candidate :ebox-scroll-offset-controlled-p t))))
         actual fresh)
    (setq actual (buffer-string))
    ;; Bind only the first layout invocation, leaving nested scroll offsets
    ;; to the committed source used by this root-only oracle.
    (let ((render (symbol-function 'ebox--render-layout)) first)
      (cl-letf (((symbol-function 'ebox--render-layout)
                 (lambda (candidate)
                   (unless first (setq first t) (funcall set-offset candidate))
                   (funcall render candidate))))
        (setq fresh (ebox-render input))))
    (should (equal (substring-no-properties actual) (substring-no-properties fresh)))
    (should (= (length actual) (length fresh)))
    (dotimes (position (length actual))
      (dolist (property '(face font-lock-face display help-echo keymap mouse-face pointer))
        (ert-info ((format "Property %S at %d" property position))
          (should (equal (get-text-property position property actual)
                         (get-text-property position property fresh))))))))

(ert-deftest ebox-layer-scroll-root-reuses-composed-content ()
  "Pure root scroll retains layered content and skips the complete tree render."
  (dolist (chrome '(nil t fractional))
    (ebox-layer-scroll-test--with-buffer
      (ebox-render-to-buffer
       (current-buffer) (ebox-layer-scroll-test--input chrome t))
      (let* ((state (ebox-layer-scroll-test--root-state))
             (region-id (plist-get (plist-get state :box) :region-id))
             (content (plist-get state :content-lines))
             (root-renders 0)
             (render (symbol-function 'ebox-surface--render-candidate)))
        (when (eq chrome 'fractional)
          (should (plist-get (ebox--buffer-render-state (current-buffer))
                             :fractional-pixel-output-p)))
        (dolist (delta '(1 1 -1 -1))
          (cl-letf (((symbol-function 'ebox-surface--render-candidate)
                     (lambda (&rest arguments)
                       (cl-incf root-renders)
                       (apply render arguments))))
            (should (= delta (ebox--scroll-region-by region-id delta 1)))
            (should (eq content
                        (plist-get (ebox-layer-scroll-test--root-state) :content-lines)))
            (should (eq (plist-get (ebox-buffer-update-report (current-buffer))
                                   :projection-kind)
                        'scroll-patch)))
          (ebox-layer-scroll-test--assert-fresh))
        (should (= root-renders 0))))))

(ert-deftest ebox-layer-scroll-retains-input-facts-with-unready-nested-window ()
  "A nested window's chrome cannot invalidate the root's style or axis facts."
  (ebox-layer-scroll-test--with-buffer
    (ebox-render-to-buffer
     (current-buffer) (ebox-layer-scroll-test--input t nil t))
    (let* ((runtime (ebox--buffer-render-state (current-buffer)))
           (root-state (ebox-layer-scroll-test--root-state))
           (region-id (plist-get (plist-get root-state :box) :region-id))
           (axes (plist-get runtime :viewport-dependent-node-id-axes))
           (nested (car (ebox-selector-query-buffer (current-buffer) "#nested")))
           (nested-state (gethash (plist-get nested :region-id)
                                  (plist-get runtime :scroll-state-table))))
      (should nested-state)
      (should-not (ebox--scroll-state-retained-window-ready-p nested-state))
      (cl-letf (((symbol-function 'ebox-surface--context-axes)
                 (lambda (&rest _) (ert-fail "Scroll rescanned context axes")))
                ((symbol-function 'ebox-surface--inline-inheritance-required-p)
                 (lambda (&rest _) (ert-fail "Scroll rescanned inheritance")))
                ((symbol-function 'ebox-surface--apply-node-style)
                 (lambda (&rest _) (ert-fail "Scroll reapplied unchanged styles"))))
        (should (= 1 (ebox--scroll-region-by region-id 1 1))))
      (should (eq axes (plist-get (ebox--buffer-render-state (current-buffer))
                                  :viewport-dependent-node-id-axes)))
      (ebox-layer-scroll-test--assert-fresh))))

(ert-deftest ebox-layer-scroll-content-and-visibility-refresh-composed-cache ()
  "Content and visibility updates replace the cache consumed by later scrolling."
  (ebox-layer-scroll-test--with-buffer
    (ebox-render-to-buffer
     (current-buffer) (ebox-layer-scroll-test--input t))
    (let* ((root-state (ebox-layer-scroll-test--root-state))
           (region-id (plist-get (plist-get root-state :box) :region-id)))
      (should (= 1 (ebox--scroll-region-by region-id 1 1)))
      (dolist (change '((:content "NEW1\nNEW2")
                        (:visibility hidden) (:visibility visible)))
        (let ((content (plist-get (ebox-layer-scroll-test--root-state) :content-lines)))
          (apply #'ebox-region-update "upper" change)
          (should-not (eq content (plist-get (ebox-layer-scroll-test--root-state)
                                            :content-lines))))
        (ebox-layer-scroll-test--assert-fresh)
        (should (= 1 (ebox--scroll-region-by region-id 1 1)))
        (ebox-layer-scroll-test--assert-fresh)
        (should (= -1 (ebox--scroll-region-by region-id -1 1)))))))

(ert-deftest ebox-layer-scroll-rejected-publication-keeps-cache-and-input ()
  "Both publication failure stages preserve composed cache and current offset."
  (dolist (failure-step '(text client-state))
    (ebox-layer-scroll-test--with-buffer
      (ebox-render-to-buffer
       (current-buffer) (ebox-layer-scroll-test--input 'fractional))
      (let* ((runtime (ebox--buffer-render-state (current-buffer)))
             (state (ebox-layer-scroll-test--root-state))
             (region-id (plist-get (plist-get state :box) :region-id))
             (content (plist-get state :content-lines))
             (snapshot (ebox-surface-buffer-snapshot (current-buffer)))
             (revision (ebox-surface-buffer-revision (current-buffer)))
             (before (buffer-string)))
        (let ((tp--surface-publication-step-function
               (lambda (step _surface)
                 (when (eq step failure-step) (error "Reject cached root scroll")))))
          (should-error (ebox--scroll-region-by region-id 1 1)))
        (should (eq runtime (ebox--buffer-render-state (current-buffer))))
        (should (eq state (ebox-layer-scroll-test--root-state)))
        (should (eq content (plist-get state :content-lines)))
        (let* ((after (ebox-surface-buffer-snapshot (current-buffer)))
               (same-input
                (equal (ebox-canonical-input-roots (plist-get snapshot :input))
                       (ebox-canonical-input-roots (plist-get after :input)))))
          (should same-input)
          (should (= (plist-get snapshot :mount-id) (plist-get after :mount-id))))
        (should (= revision (ebox-surface-buffer-revision (current-buffer))))
        (should (equal-including-properties before (buffer-string)))
        (should (= 1 (ebox--scroll-region-by region-id 1 1)))
        (ebox-layer-scroll-test--assert-fresh)))))

(ert-deftest ebox-layer-scroll-visible-root-dependencies-retain-composed-cache ()
  "Pure root scroll slices already composed visible projections and anchors."
  (dolist (target '(portal anchor))
    (ebox-layer-scroll-test--with-buffer
      (ebox-render-to-buffer
       (current-buffer) (ebox-layer-scroll-test--input t t))
      (if (eq target 'portal)
          (ebox-region-update "portal" :visibility 'visible)
        (ebox-region-update "upper" :anchor "before"))
      (let* ((state (ebox-layer-scroll-test--root-state))
             (root (plist-get state :box))
             (region-id (plist-get root :region-id))
             (render (symbol-function 'ebox-surface--render-candidate))
             (root-renders 0))
        (should (ebox-layer-cached-root-scroll-p root state))
        (cl-letf (((symbol-function 'ebox-surface--render-candidate)
                   (lambda (&rest arguments)
                     (cl-incf root-renders)
                     (apply render arguments))))
          (should (= 1 (ebox--scroll-region-by region-id 1 1))))
        (should (= root-renders 0))
        (ebox-layer-scroll-test--assert-fresh)))))

(ert-deftest ebox-layer-scroll-anchor-provider-chain-crosses-viewport ()
  "Cached provider chains keep text and interactions when entering and leaving."
  (ebox-layer-scroll-test--with-buffer
    (ebox-render-to-buffer (current-buffer) (ebox-layer-scroll-test--portal-chain-input))
    (let* ((state (ebox-layer-scroll-test--root-state))
           (region-id (plist-get (plist-get state :box) :region-id))
           (content (plist-get state :content-lines))
           (visible 0) (outside 0))
      (should (string-match-p "CHAIN" (ebox-lines-join content)))
      (dolist (delta '(1 1 1 1 1 1 -1 -1 -1 -1 -1 -1))
        (cl-letf (((symbol-function 'ebox-surface--render-candidate)
                   (lambda (&rest _) (ert-fail "Root scroll recomposed portals"))))
          (should (= delta (ebox--scroll-region-by region-id delta 1))))
        (should (eq content (plist-get (ebox-layer-scroll-test--root-state)
                                       :content-lines)))
        (if (string-match-p "CHAIN" (buffer-string))
            (cl-incf visible)
          (cl-incf outside))
        (ebox-layer-scroll-test--assert-fresh))
      (should (> visible 0))
      (should (> outside 0)))))

(ert-deftest ebox-layer-scroll-anchor-provider-invalidation-and-rollback ()
  "Provider changes replace composed caches; rejected scrolls preserve them."
  (ebox-layer-scroll-test--with-buffer
    (ebox-render-to-buffer (current-buffer) (ebox-layer-scroll-test--portal-chain-input))
    (let* ((state (ebox-layer-scroll-test--root-state))
           (region-id (plist-get (plist-get state :box) :region-id)))
      (should (= 3 (ebox--scroll-region-by region-id 3 3)))
      (dolist (change '(("provider-anchor" :content "EDIT")
                        ("provider" :placement top-end)
                        ("trigger" :left (ch 3))
                        ("clipped-owner" :visibility hidden)
                        ("clipped-owner" :visibility visible)))
        (let ((content (plist-get (ebox-layer-scroll-test--root-state) :content-lines)))
          (apply #'ebox-region-update change)
          (should-not (eq content (plist-get (ebox-layer-scroll-test--root-state)
                                             :content-lines))))
        (ebox-layer-scroll-test--assert-fresh)
        (should (= 1 (ebox--scroll-region-by region-id 1 1)))
        (ebox-layer-scroll-test--assert-fresh)
        (should (= -1 (ebox--scroll-region-by region-id -1 1))))
      (dolist (failure-step '(text client-state))
        (let ((runtime (ebox--buffer-render-state (current-buffer)))
              (content (plist-get (ebox-layer-scroll-test--root-state) :content-lines))
              (before (buffer-string))
              (revision (ebox-surface-buffer-revision (current-buffer))))
          (let ((tp--surface-publication-step-function
                 (lambda (step _surface)
                   (when (eq step failure-step) (error "Reject anchored root scroll")))))
            (should-error (ebox--scroll-region-by region-id 1 1)))
          (should (eq runtime (ebox--buffer-render-state (current-buffer))))
          (should (eq content (plist-get (ebox-layer-scroll-test--root-state) :content-lines)))
          (should (= revision (ebox-surface-buffer-revision (current-buffer))))
          (should (equal-including-properties before (buffer-string)))))
      (should (= 1 (ebox--scroll-region-by region-id 1 1)))
      (ebox-layer-scroll-test--assert-fresh))))

(ert-deftest ebox-layer-scroll-declines-incomplete-or-changed-cache ()
  "Dirty or lazy content and simultaneous source changes cannot reuse layers."
  (ebox-layer-scroll-test--with-buffer
    (ebox-render-to-buffer
     (current-buffer) (ebox-layer-scroll-test--input t))
    (let* ((runtime (ebox--buffer-render-state (current-buffer)))
           (state (ebox-layer-scroll-test--root-state))
           (root (plist-get state :box))
           (owner (plist-get root :node-id)))
      (dolist (key '(:render-content-prefix :materialize-content-lines
                     :lazy-scroll-prefix-dirty :lazy-scroll-window-refresh-required))
        (let ((candidate (copy-sequence state)))
          (plist-put candidate :content-lines-complete-p nil)
          (setq candidate (plist-put candidate key t))
          (should-not (ebox-layer-cached-root-scroll-p root candidate))))
      (dolist (keys '((:scroll-offset :content) (:visibility) (:width)))
        (should-not
         (ebox-incremental--layer-root-scroll-p
          runtime runtime
          (list :dirty-set (list (list :node-id owner :changed-keys keys)))
          owner))))))

(ert-deftest ebox-layer-scroll-ordinary-materialized-content-builds-rendered-rows ()
  "Ordinary materialization still bootstraps its reusable physical row cache."
  (ebox-layer-scroll-test--with-buffer
    (ebox-render-to-buffer
     (current-buffer)
     (ebox-build
      `(column :id "root" :width (vw 100) :height (vh 100) :overflow scroll
               ,@(cl-loop for index below 80
                          collect `(box :padding-left (px 1.5)
                                        ,(format "ROW%02d" index))))))
    (let* ((runtime (ebox--buffer-render-state (current-buffer)))
           (state (ebox-layer-scroll-test--root-state))
           (region-id (plist-get (plist-get state :box) :region-id)))
      (should-not (plist-get runtime :layered-p))
      (should (plist-get runtime :fractional-pixel-output-p))
      (setq state (ebox--scroll-state-materialize-lines region-id state))
      (puthash region-id state (plist-get runtime :scroll-state-table))
      (should (plist-get state :content-lines-complete-p))
      (should-not (plist-get state :rendered-content-lines))
      (should (= 1 (ebox--scroll-region-by region-id 1 1)))
      (should (= -1 (ebox--scroll-region-by region-id -1 1)))
      (should (plist-get (ebox-layer-scroll-test--root-state) :rendered-content-lines))
      (cl-letf (((symbol-function 'ebox-surface--render-candidate-node)
                 (lambda (&rest _) (ert-fail "Cached ordinary scroll rendered wrapper"))))
        (should (= 1 (ebox--scroll-region-by region-id 1 1))))
      (ebox-layer-scroll-test--assert-fresh))))

(provide 'ebox-layer-scroll-tests)
;;; ebox-layer-scroll-tests.el ends here
