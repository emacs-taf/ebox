;;; ebox-active-tests.el --- Pressed state and native activation -*- lexical-binding: t; -*-

;;; Commentary:
;; Observe held primary-button state through public selectors and rendered paint.

;;; Code:
(require 'ert)
(require 'ebox)

(ert-deftest ebox-primary-press-publishes-active-style-and-activates-once ()
  "A held button shares selector and paint state, then releases before activation."
  (should-error (ebox-build '(text :states active "Invalid")))
  (let ((buffer (generate-new-buffer " *ebox-active*")) (calls 0) held)
    (unwind-protect
        (save-window-excursion
          (set-window-buffer (selected-window) buffer)
          (let ((map (ebox-keymap-create
                      :activate (lambda ()
                                  (should-not (ebox-selector-query-buffer buffer ":active"))
                                  (cl-incf calls)))))
            (ebox-render-to-buffer
             buffer
             (ebox-build `(column :width (ch 30)
                                 :ecss (("#button" :color "#111111")
                                        ("#button:active" :color "#ff0000"))
                                 (box :id "button" :key button :keymap ,map "Press"))))
            (with-current-buffer buffer
              (goto-char (point-min))
              (search-forward "Press")
              (let* ((position (match-beginning 0))
                     (press (list 'down-mouse-1 (list (selected-window) position '(1 . 0) 0)))
                     (release (list 'mouse-1 (list (selected-window) position '(1 . 0) 1)))
                     (command (key-binding (vector press) nil nil position)))
                (cl-letf (((symbol-function 'read-event)
                           (lambda (&rest _)
                             (setq held (length (ebox-selector-query-buffer buffer "#button:active")))
                             (should (equal "#ff0000" (plist-get (get-text-property position 'face) :foreground)))
                             (should (= calls 0))
                             release)))
                  (funcall command press)))
              (should (= held 1))
              (should (= calls 1))
              (should-not (ebox-selector-query-buffer buffer ":active"))
              (goto-char (point-min))
              (search-forward "Press")
              (should (equal "#111111" (plist-get (get-text-property (match-beginning 0) 'face) :foreground))))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-primary-press-cancels-outside-and-releases-unrelated-input ()
  "Release over another target or unrelated input clears active without firing."
  (dolist (outside '(nil t))
    (let ((buffer (generate-new-buffer " *ebox-active-cancel*"))
          (unread-command-events nil) (calls 0))
      (unwind-protect
          (save-window-excursion
            (set-window-buffer (selected-window) buffer)
            (let ((map (ebox-keymap-create :activate (lambda () (cl-incf calls)))))
              (ebox-render-to-buffer buffer
                                    (ebox-build `(column :width (ch 30)
                                                         (box :key button :id "button" :keymap ,map "Press")
                                                         (text "Other"))))
              (with-current-buffer buffer
                (let* ((press (list 'down-mouse-1 (list (selected-window) 1 '(1 . 0) 0)))
                       (command (key-binding (vector press) nil nil 1))
                       (end (save-excursion (goto-char (point-min)) (search-forward "Other") (match-beginning 0))))
                  (cl-letf (((symbol-function 'read-event)
                             (lambda (&rest _)
                               (should (= 1 (length (ebox-selector-query-buffer buffer ":active"))))
                               (if outside
                                   (list 'drag-mouse-1 (event-start press)
                                         (list (selected-window) end '(1 . 1) 1))
                                 ?x))))
                    (funcall command press)))
                (should (= calls 0))
                (should-not (ebox-selector-query-buffer buffer ":active"))
                (unless outside (should (equal unread-command-events '(?x)))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest ebox-primary-press-uses-replaced-mouse-binding ()
  "A held target activates its latest explicit mouse binding instead of RET."
  (let ((buffer (generate-new-buffer " *ebox-active-binding*")) calls)
    (unwind-protect
        (save-window-excursion
          (set-window-buffer (selected-window) buffer)
          (ebox-render-to-buffer
           buffer (ebox-build `(text :id "button"
                                     :keymap ,(ebox-keymap-create :activate (lambda () (push 'old calls)))
                                     "Press")))
          (with-current-buffer buffer
            (let* ((press (list 'down-mouse-1 (list (selected-window) 1 '(1 . 0) 0)))
                   (release (list 'mouse-1 (list (selected-window) 1 '(1 . 0) 1)))
                   (command (key-binding (vector press) nil nil 1)))
              (cl-letf (((symbol-function 'read-event)
                         (lambda (&rest _)
                           (ebox-region-update
                            "button" :keymap
                            (ebox-keymap-create
                             :bindings (list (cons "RET" (lambda () (push 'keyboard calls)))
                                             (cons [mouse-1] (lambda () (push 'mouse calls))))))
                           (should (= 1 (length (ebox-selector-query-buffer buffer ":active"))))
                           release)))
                (funcall command press)))
            (should (equal calls '(mouse)))
            (should-not (ebox-selector-query-buffer buffer ":active"))))
      (kill-buffer buffer))))

(ert-deftest ebox-primary-press-keeps-pure-text-activation ()
  "Generated maps on pure rendered text retain ordinary native release commands."
  (let ((buffer (generate-new-buffer " *ebox-active-pure*")) (calls 0))
    (unwind-protect
        (save-window-excursion
          (set-window-buffer (selected-window) buffer)
          (with-current-buffer buffer
            (insert (ebox-render (ebox-build `(text :keymap ,(ebox-keymap-create :activate (lambda () (cl-incf calls))) "Press"))))
            (let* ((press (list 'down-mouse-1 (list (selected-window) 1 '(1 . 0) 0)))
                   (release (list 'mouse-1 (list (selected-window) 1 '(1 . 0) 1))))
              (funcall (key-binding (vector press) nil nil 1) press)
              (should (= calls 0))
              (funcall (key-binding (vector release) nil nil 1) release)
              (should (= calls 1)))))
      (kill-buffer buffer))))

(ert-deftest ebox-primary-press-clears-active-when-target-is-clipped ()
  "Clipping away a held target clears its selector state before publication."
  (let ((buffer (generate-new-buffer " *ebox-active-clip*")) (calls 0))
    (unwind-protect
        (save-window-excursion
          (set-window-buffer (selected-window) buffer)
          (ebox-render-to-buffer
           buffer
           (ebox-build `(column :id "viewport" :height (lh 2) :overflow hidden
                                (text "Header")
                                (text :id "button" :keymap ,(ebox-keymap-create :activate (lambda () (cl-incf calls))) "Press"))))
          (with-current-buffer buffer
            (goto-char (point-min)) (search-forward "Press")
            (let* ((position (match-beginning 0))
                   (press (list 'down-mouse-1 (list (selected-window) position '(1 . 1) 0)))
                   (command (key-binding (vector press) nil nil position)))
              (cl-letf (((symbol-function 'read-event)
                         (lambda (&rest _)
                           (should (= 1 (length (ebox-selector-query-buffer buffer ":active"))))
                           (ebox-region-update "viewport" :height '(lh 1))
                           (should-not (ebox-selector-query-buffer buffer ":active"))
                           (list 'mouse-1 (list (selected-window) 1 '(1 . 0) 1)))))
                (funcall command press)))
            (should (= 0 calls))
            (should-not (ebox-selector-query-buffer buffer ":active"))))
      (kill-buffer buffer))))

(provide 'ebox-active-tests)
;;; ebox-active-tests.el ends here
