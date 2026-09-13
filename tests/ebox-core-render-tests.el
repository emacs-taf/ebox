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

(ert-deftest ebox-scroll-map-keeps-wheel-on-event-aware-handler ()
  "Mouse wheel bindings should use event-aware handlers, not line fallbacks."
  (should (eq (lookup-key ebox-scroll-map [wheel-down])
              #'ebox-wheel-scroll-down))
  (should (eq (lookup-key ebox-scroll-map [wheel-up])
              #'ebox-wheel-scroll-up))
  (should (eq (lookup-key ebox-scroll-map [mouse-5])
              #'ebox-wheel-scroll-down))
  (should (eq (lookup-key ebox-scroll-map [mouse-4])
              #'ebox-wheel-scroll-up))
  (should (eq (lookup-key ebox-scroll-map [right-fringe wheel-down])
              #'ebox-wheel-scroll-down))
  (should (eq (lookup-key ebox-scroll-map [right-fringe wheel-up])
              #'ebox-wheel-scroll-up))
  (should (eq (lookup-key ebox-scroll-map [mode-line wheel-down])
              #'ebox-wheel-scroll-down))
  (should (eq (lookup-key ebox-scroll-map [mode-line wheel-up])
              #'ebox-wheel-scroll-up))
  (should (eq (lookup-key ebox-scroll-map [vertical-scroll-bar wheel-down])
              #'ebox-wheel-scroll-down))
  (should (eq (lookup-key ebox-scroll-map [vertical-scroll-bar wheel-up])
              #'ebox-wheel-scroll-up))
  (should (eq (lookup-key ebox-scroll-map [remap scroll-up-command])
              #'ebox-scroll-page-down))
  (should (eq (lookup-key ebox-scroll-map [remap scroll-down-command])
              #'ebox-scroll-page-up))
  (should (eq (lookup-key ebox-scroll-map (kbd "C-v"))
              #'ebox-scroll-page-down))
  (should (eq (lookup-key ebox-scroll-map (kbd "<next>"))
              #'ebox-scroll-page-down))
  (should (eq (lookup-key ebox-scroll-map (kbd "M-v"))
              #'ebox-scroll-page-up))
  (should (eq (lookup-key ebox-scroll-map (kbd "<prior>"))
              #'ebox-scroll-page-up))
  (should (eq (lookup-key ebox-scroll-map (kbd "n"))
              #'ebox-scroll-down))
  (should (eq (lookup-key ebox-scroll-map (kbd "p"))
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
                (should-not (plist-get report :tp-full-root))
                (should (> (or (plist-get report :tp-scope-count) 0) 0))
                (should (= (plist-get peer-after :node-id) peer-node-id)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(provide 'ebox-core-render-tests)
;;; ebox-core-render-tests.el ends here
