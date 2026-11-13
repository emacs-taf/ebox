;;; ebox-line-height-tests.el --- Row heights against body fonts -*- lexical-binding: t; -*-

;;; Commentary:
;; A row is one line high whatever script it holds.  Body text in a font
;; taller than the Latin one sizes that line instead of having its glyphs
;; shrunk into it.

;;; Code:

(require 'ebox-test-support)

(ert-deftest ebox-body-text-rows-keep-the-line-height ()
  "Every published row measures one line height, whatever script it holds.
A CJK font taller than the Latin one raises the line, so Chinese text stays
exactly as tall as its font instead of being scaled down to fit a Latin line."
  (skip-unless (display-graphic-p))
  (ebox-test-with-mounted (buffer root '(column :width (px 200)
                                               (row (text "0 0"))
                                               (row (text "汉汉"))
                                               (row (text "0汉0")))
                                   :width 200 :height 4)
    (let ((window (selected-window))
          (shown (window-buffer (selected-window)))
          (line (plist-get (ebox-display-metrics buffer) :line-height)))
      (unwind-protect
          (progn
            (set-window-buffer window buffer)
            (redisplay t)
            (should (= (ebox-node-h root) 3))
            ;; Ordinary text of either script fits the line it sets.
            (should (<= (ebox-test-native-height "0汉" buffer) line))
            (save-excursion
              (goto-char (point-min))
              (while (not (eobp))
                (should (= (cdr (window-text-pixel-size
                                 window (line-beginning-position)
                                 (line-end-position)))
                           line))
                (forward-line 1))))
        (set-window-buffer window shown)))))

(ert-deftest ebox-full-width-rows-keep-the-line-height ()
  "A row reaching the window's right edge keeps the line height.
The height carrier starts the row, so the truncation boundary cannot drop
it."
  (skip-unless (display-graphic-p))
  (ebox-test-with-tall-cjk
    (let* ((window (selected-window))
           (shown (window-buffer window))
           (fringes (window-fringes window))
           (buffer (generate-new-buffer " *ebox-line-height*")))
      (unwind-protect
          (progn
            (set-window-buffer window buffer)
            (set-window-fringes window 8 8 t)
            (let* ((map (ebox-keymap-create :activate (lambda () t)))
                   (root (ebox-mount buffer
                                     `(column :width 'stretch
                                              (box :height '(lh 1)
                                                   :hover-style (:background-color "#123456")
                                                   :keymap ,map
                                                   (text "0 0"))
                                              (box :height '(lh 1) :background-color "#335544"
                                                   (text "汉汉"))
                                              (box :height '(lh 1) :background-color "#443355"
                                                   (text "0 0")))
                                     :width (ebox-viewport-window-width window)
                                     :height 3)))
              (redisplay t)
              (let ((line (plist-get (ebox-display-metrics buffer) :line-height)))
                (should (= (ebox-node-h root) 3))
                (should (> line (ebox-test-native-height "0" buffer)))
                (save-excursion
                  (goto-char (point-min))
                  (while (not (eobp))
                    (should (= (cdr (window-text-pixel-size
                                     window (line-beginning-position)
                                     (line-end-position)))
                               line))
                    (let* ((start (line-beginning-position))
                           (display (get-text-property start 'display)))
                      (should (eq (char-after start) ?\u200b))
                      (should (= (car (plist-get display :height)) line)))
                    (forward-line 1)))
                (let* ((start (point-min))
                       (y (cdr (posn-x-y (posn-at-point start window))))
                       (posn (posn-at-x-y 0 y window)))
                  (should (eq (posn-point posn) start))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (set-window-buffer window shown)
        (set-window-fringes window (nth 0 fringes) (nth 1 fringes)
                            (nth 2 fringes) (nth 3 fringes))))))

(ert-deftest ebox-render-lines-carry-the-row-strut ()
  "A rendered string starts every line with the height carrier."
  (ebox-test-with-tall-cjk
    (let ((string (ebox-render '(column :width 'stretch
                                       (row :height '(lh 1) (text "0 0"))
                                       (row :height '(lh 1) (text "汉汉"))))))
      (should (eq (aref string 0) ?\u200b))
      (should (eq (aref string (1+ (string-search "\n" string))) ?\u200b)))))

(ert-deftest ebox-overline-face-keeps-the-line-fit ()
  "An overline adds no height in a canvas.
A decorated glyph that fills its line keeps the plain scale, and the
plain text after it does not inherit a fitted display."
  (ebox-test-with-tall-cjk
    (let* ((deco (propertize "焦" 'face '(:overline t)))
           (buffer (generate-new-buffer " *ebox-overline-fit*")))
      (unwind-protect
          (progn
            (ebox-mount buffer `(column :width 'stretch
                                       (row (text ,deco))
                                       (row (text "焦")))
                        :width 200 :height 20)
            (with-current-buffer buffer
              (goto-char (point-min))
              (let (displays)
                (while (not (eobp))
                  (when (search-forward "焦" (line-end-position) t)
                    (push (get-text-property (1- (point)) 'display) displays))
                  (forward-line 1))
                (should (equal (nreverse displays) '(nil nil))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest ebox-overline-fit-does-not-cross-overline-margins ()
  "Text measured with another `overline-margin' keeps its own fit.
A plain buffer counts an overline into the row height; a canvas does not,
so the fitted scale must not pass between them."
  (ebox-test-with-tall-cjk
    (ebox-clear-cache)
    (let ((plain (generate-new-buffer " *ebox-plain-render*")))
      (unwind-protect
          (with-current-buffer plain
            (setq-local overline-margin 2)
            (let* ((deco (propertize "焦" 'face '(:overline t)))
                   (rendered (ebox-render `(column (row (text ,deco))))))
              ;; The plain render sees the overline and caches a fitted scale.
              (should (get-text-property (string-search "焦" rendered)
                                         'display rendered))))
        (when (buffer-live-p plain) (kill-buffer plain))))
    (let ((canvas (generate-new-buffer " *ebox-overline-canvas*")))
      (unwind-protect
          (progn
            (ebox-mount canvas '(column :width 'stretch (row (text "焦")))
                        :width 200 :height 10)
            (with-current-buffer canvas
              (goto-char (point-min))
              (should (search-forward "焦" nil t))
              (should (null (get-text-property (1- (point)) 'display)))))
        (when (buffer-live-p canvas) (kill-buffer canvas))))))

(provide 'ebox-line-height-tests)
;;; ebox-line-height-tests.el ends here
