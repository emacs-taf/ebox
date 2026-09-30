;;; ebox-core-render-tests.el --- Public API acceptance -*- lexical-binding: t; -*-

;;; Commentary:
;; Test supported package inputs, outputs, errors and lifecycle.
;; Internal implementation details are outside this contract.

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'ebox)

;; Core tests assert named Elisp render/patch strategies.  Keep optional local
;; native artifacts from replacing those strategies; native execution has
;; separate module and integration gates.
(defvar ebox-native-reflow-module-path)

(ert-deftest ebox-canonical-column-viewport-height-measures-text-as-text ()
  "A typed Text leaf must not enter legacy Box geometry measurement."
  (let ((ebox-viewport-width 640)
        (ebox-viewport-height 24))
    (should
     (string-match-p
      "Viewport"
      (substring-no-properties
       (ebox-render
        (ebox-build
         '(column :width (vw 100) :height (vh 100)
           "Viewport"))))))))

(ert-deftest ebox-buffer-mode-keeps-event-aware-wheel-bindings ()
  "Mouse wheel bindings should use event-aware handlers, not line fallbacks."
  (should (eq (lookup-key ebox-buffer-mode-map [wheel-down])
              #'ebox-wheel-scroll-down))
  (should (eq (lookup-key ebox-buffer-mode-map [wheel-up])
              #'ebox-wheel-scroll-up))
  (should (eq (lookup-key ebox-buffer-mode-map [mouse-5])
              #'ebox-wheel-scroll-down))
  (should (eq (lookup-key ebox-buffer-mode-map [mouse-4])
              #'ebox-wheel-scroll-up))
  (should (eq (lookup-key ebox-buffer-mode-map [right-fringe wheel-down])
              #'ebox-wheel-scroll-down))
  (should (eq (lookup-key ebox-buffer-mode-map [right-fringe wheel-up])
              #'ebox-wheel-scroll-up))
  (should (eq (lookup-key ebox-buffer-mode-map [mode-line wheel-down])
              #'ebox-wheel-scroll-down))
  (should (eq (lookup-key ebox-buffer-mode-map [mode-line wheel-up])
              #'ebox-wheel-scroll-up))
  (should (eq (lookup-key ebox-buffer-mode-map [vertical-scroll-bar wheel-down])
              #'ebox-wheel-scroll-down))
  (should (eq (lookup-key ebox-buffer-mode-map [vertical-scroll-bar wheel-up])
              #'ebox-wheel-scroll-up))
  (should (eq (lookup-key ebox-buffer-mode-map [remap scroll-up-command])
              #'ebox-scroll-page-down))
  (should (eq (lookup-key ebox-buffer-mode-map [remap scroll-down-command])
              #'ebox-scroll-page-up))
  (should (eq (lookup-key ebox-buffer-mode-map (kbd "C-v"))
              #'ebox-scroll-page-down))
  (should (eq (lookup-key ebox-buffer-mode-map (kbd "<next>"))
              #'ebox-scroll-page-down))
  (should (eq (lookup-key ebox-buffer-mode-map (kbd "M-v"))
              #'ebox-scroll-page-up))
  (should (eq (lookup-key ebox-buffer-mode-map (kbd "<prior>"))
              #'ebox-scroll-page-up))
  (should (eq (lookup-key ebox-buffer-mode-map (kbd "n"))
              #'ebox-scroll-down))
  (should (eq (lookup-key ebox-buffer-mode-map (kbd "p"))
              #'ebox-scroll-up)))

(ert-deftest ebox-buffer-mode-overrides-pixel-scroll-bindings ()
  "Ebox buffers should keep their own scroll bindings under pixel scrolling."
  (unless (fboundp 'pixel-scroll-precision-mode)
    (ert-skip "pixel-scroll-precision-mode is unavailable"))
  (let ((was-enabled pixel-scroll-precision-mode))
    (unwind-protect
        (with-temp-buffer
          (pixel-scroll-precision-mode 1)
          (ebox-buffer-mode 1)
          (should (eq (key-binding [wheel-down])
                      #'ebox-wheel-scroll-down))
          (should (eq (key-binding [wheel-up])
                      #'ebox-wheel-scroll-up))
          (should (eq (key-binding [right-fringe wheel-down])
                      #'ebox-wheel-scroll-down))
          (should (eq (key-binding [mode-line wheel-down])
                      #'ebox-wheel-scroll-down))
          (should (eq (key-binding [vertical-scroll-bar wheel-down])
                      #'ebox-wheel-scroll-down))
          (should (eq (key-binding (kbd "<next>"))
                      #'ebox-scroll-page-down))
          (should (eq (key-binding (kbd "<prior>"))
                      #'ebox-scroll-page-up)))
      (unless was-enabled
        (pixel-scroll-precision-mode -1)))))

(ert-deftest ebox-typed-local-updates-keep-publication-scoped ()
  "Paint and geometry updates keep an unrelated keyed peer outside full-root work."
  (dolist (update '((:background-color "#DBEAFE") (:width (px 120))))
    (let ((buffer (generate-new-buffer " *ebox-typed-scoped-update*")))
      (unwind-protect
          (progn
            (ebox-render-to-buffer
             buffer
             (ebox-build
              '(row :width (px 260)
                (box :id target :width (px 100) "Target")
                (box :id peer :width (px 100) "Peer"))))
            (let* ((target (ebox-region-resolve buffer "target"))
                   (peer (car (ebox-selector-query-buffer buffer "#peer")))
                   (peer-node-id (plist-get peer :node-id)))
              (apply #'ebox-region-update target update)
              (let ((report (ebox-buffer-update-report buffer))
                    (peer-after
                     (car (ebox-selector-query-buffer buffer "#peer"))))
                (should-not (plist-get report :full-rerender))
                (should-not (plist-get report :publication-full-root))
                (should (> (or (plist-get report :publication-scope-count) 0) 0))
                (should (= (plist-get peer-after :node-id) peer-node-id)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(defun ebox-core-render--presented-text (text)
  "Return TEXT's visible characters and public presentation facts."
  (list (substring-no-properties text)
        (vconcat
         (cl-loop for index below (length text)
                  collect (mapcar (lambda (property)
                                    (get-text-property index property text))
                                  '(display face font-lock-face))))))

(defun ebox-core-render--definite-slot-view (clock width)
  "Build rows with a definite CLOCK slot and a definite meter at WIDTH%."
  (ebox-build
   `(flex :flex-direction column :width (px 40)
          (flex :width stretch :height (lh 1) (text "Row A"))
          (flex :width stretch :height (lh 1) (text "Row B"))
          (flex :width stretch :height (lh 1) :align-items center
                (box :id meter :width (% ,width) :flex-shrink 0
                     :min-width (px 1) :background-color "#EC4141")
                (box :width (% 100) :flex-grow 1 :min-width (px 0)
                     :background-color "#232832"))
          (box :id clock :height (lh 1) ,clock))))

(defun ebox-core-render--assert-local-slot-update (buffer operation)
  "Apply OPERATION to BUFFER and require one owner-scoped publication."
  (funcall (cdr operation) (car operation))
  (let ((report (ebox-buffer-update-report buffer)))
    (ert-info ((format "projection=%S dirty=%S patch=%S"
                       (plist-get report :projection-kind)
                       (plist-get report :dirty-count)
                       (plist-get report :patch-count)))
      (should (memq (plist-get report :projection-kind)
                    '(span-patch owner-scoped)))
      (should (= (plist-get report :dirty-count) 1))
      (should (= (plist-get report :patch-count) 1))
      (should-not (plist-get report :publication-full-root)))))

(ert-deftest ebox-definite-flex-slot-updates-keep-local-projection ()
  "Content and size writes in definite flex slots stay owner-scoped.
An automatic basis with a definite main size publishes its own slot instead
of widening the update to the containing formatting context."
  (let* ((ebox-native-reflow-module-path nil)
         (live (ebox-render-to-buffer
                (generate-new-buffer " *ebox-definite-slot-update*")
                (ebox-core-render--definite-slot-view "0:00" 30)))
         (fresh (ebox-core-render--definite-slot-view "9:59" 45)))
    (unwind-protect
        (with-current-buffer live
          (ebox-core-render--assert-local-slot-update
           live (cons (ebox-region-resolve live "clock")
                      (lambda (handle)
                        (ebox-region-update handle :content "9:59"))))
          (ebox-core-render--assert-local-slot-update
           live (cons (ebox-region-resolve live "meter")
                      (lambda (handle)
                        (ebox-region-update-geometry handle :width '(% 45)))))
          (should (equal (ebox-core-render--presented-text (buffer-string))
                         (ebox-core-render--presented-text (ebox-render fresh)))))
      (when (buffer-live-p live)
        (when (ebox-surface-buffer-mounted-p live) (ebox-unmount-buffer live))
        (kill-buffer live)))))

(provide 'ebox-core-render-tests)
;;; ebox-core-render-tests.el ends here
