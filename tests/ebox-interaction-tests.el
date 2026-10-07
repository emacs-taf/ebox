;;; ebox-interaction-tests.el --- Ebox interaction and focus tests -*- lexical-binding: t; -*-

(require 'ebox-test-support)

(ert-deftest ebox-keymap-create-installs-activation-bindings ()
  (let* ((hits 0)
         (map (ebox-keymap-create :activate (lambda () (setq hits (1+ hits)))))
         (rendered (ebox-render (list 'box :keymap map "Go"))))
    (should (keymapp (get-text-property 0 'keymap rendered)))
    (should (commandp (lookup-key (get-text-property 0 'keymap rendered) (kbd "RET"))))
    (ebox-test-with-mounted (buffer root (list 'box :keymap map "Go"))
      (goto-char (point-min))
      (ebox-activate)
      (should (= hits 1)))))

(ert-deftest ebox-help-create-runs-business-function-in-hovered-buffer ()
  (let* ((help (ebox-help-create (lambda () (buffer-name))))
         (buffer (generate-new-buffer " *ebox-help-test*")))
    (unwind-protect
        (progn
          (ebox-mount buffer (list 'box :help-echo help "Help"))
          (with-current-buffer buffer
            (let ((fn (get-text-property (point-min) 'help-echo)))
              (should (functionp fn))
              (should (equal (funcall fn nil buffer nil) (buffer-name buffer))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-interaction-properties-cover-rendered-text ()
  (let* ((map (ebox-keymap-create :bindings `(("x" . ,(lambda () :ok)))))
         (rendered (ebox-render
                    (list 'box :keymap map :help-echo "help" :pointer 'hand
                          :hover-style '(:background-color "#eeeeee")
                          "Interactive"))))
    (should (eq (get-text-property 0 'keymap rendered) map))
    (should (equal (get-text-property 0 'help-echo rendered) "help"))
    (should (eq (get-text-property 0 'pointer rendered) 'hand))
    (should (equal (get-text-property 0 'mouse-face rendered)
                   '(:background "#eeeeee")))))

(ert-deftest ebox-focus-first-next-previous-and-cycle-update-focused-node ()
  (ebox-test-with-mounted (buffer root
                           '(column
                             (box :id "a" :tab-index 0 "A")
                             (box :id "b" :tab-index 0 "B")
                             (box :id "c" :tab-index 0 "C")))
    (let ((a (car (ebox-selector-query root "#a")))
          (b (car (ebox-selector-query root "#b")))
          (c (car (ebox-selector-query root "#c"))))
      (should (eq (ebox-focus-first buffer) a))
      (should (eq (ebox-focused-node buffer) a))
      (should (eq (ebox-focus-next 1 nil buffer) b))
      (should (eq (ebox-focus-previous 1 nil buffer) a))
      (should (eq (ebox-focus-previous 1 t buffer) c))
      (should (eq (ebox-focus-next 1 t buffer) a)))))

(ert-deftest ebox-focus-within-stays-inside-container ()
  (ebox-test-with-mounted (buffer root
                           '(column
                             (box :id "outside" :tab-index 0 "Outside")
                             (column :id "group"
                                     (box :id "a" :tab-index 0 "A")
                                     (box :id "b" :tab-index 0 "B"))))
    (let ((group (car (ebox-selector-query root "#group")))
          (a (car (ebox-selector-query root "#a")))
          (b (car (ebox-selector-query root "#b"))))
      (should (eq (ebox-focus-within group 1 nil buffer) a))
      (should (eq (ebox-focus-within group 1 nil buffer) b))
      (should-error (ebox-focus-within group 1 nil buffer) :type 'user-error)
      (should (eq (ebox-focused-node buffer) b)))))

(ert-deftest ebox-focus-derived-state-matches-selector-and-styles ()
  (ebox-test-with-mounted (buffer root
                           '(column :ecss (("#a:focus" :color "#ff0000"))
                                    (box :id "a" :tab-index 0 "A")
                                    (box :id "b" :tab-index 0 "B")))
    (let ((a (car (ebox-selector-query root "#a"))))
      (ebox-focus a buffer)
      (should (equal (ebox-selector-query-buffer buffer "#a:focus") (list a)))
      (should (equal (get-text-property (point-min) 'face)
                     '(:foreground "#ff0000"))))))

(ert-deftest ebox-activate-noerror-returns-nil-without-command ()
  (ebox-test-with-mounted (buffer root '(box "Plain"))
    (goto-char (point-min))
    (should-not (ebox-activate nil t))))

(ert-deftest ebox-next-and-previous-interaction-move-between-keymap-owners ()
  (let ((map (ebox-keymap-create :bindings `(("x" . ,(lambda () :ok))))))
    (ebox-test-with-mounted (buffer root
                             (list 'column
                                   (list 'box :id "a" :keymap map "A")
                                   '(box "plain")
                                   (list 'box :id "b" :keymap map "B")))
      (goto-char (point-min))
      (should (= (ebox-next-interaction) (ebox-node-position
                                          (car (ebox-selector-query root "#b")))))
      (should (= (ebox-previous-interaction) (ebox-node-position
                                              (car (ebox-selector-query root "#a"))))))))

;;; ebox-interaction-tests.el ends here
