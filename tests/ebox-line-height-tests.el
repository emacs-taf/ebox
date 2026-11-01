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

(provide 'ebox-line-height-tests)
;;; ebox-line-height-tests.el ends here
