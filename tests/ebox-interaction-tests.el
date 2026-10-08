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

(ert-deftest ebox-overlays-cover-hits-positions-and-focus-in-paint-order ()
  (ebox-test-with-mounted (buffer root
                           '(column :width (ch 20) :height (lh 4)
                                    (box :id "under" :tab-index 0 "Under")
                                    (box :id "cover" :position absolute
                                         :left (ch 0) :top (lh 0)
                                         :width (ch 20) :height (lh 4) "")
                                    (box :id "panel" :position absolute
                                         :left (ch 0) :top (lh 0)
                                         :width (ch 10) :height (lh 1)
                                         :tab-index 0 "Panel")))
    (let ((under (car (ebox-selector-query root "#under")))
          (panel (car (ebox-selector-query root "#panel"))))
      ;; The later overlay paints on top of an equal-z sibling and wins hits.
      (should (ebox-node-ancestor-p panel (ebox-node-at (point-min) buffer)))
      (should (eq (ebox-node-at (+ (point-min) 12) buffer)
                  (car (ebox-selector-query root "#cover"))))
      (should (ebox-node-position panel))
      (should-not (ebox-node-position under))
      (should-error (ebox-focus under buffer) :type 'user-error)
      (should (eq (ebox-focus-first buffer) panel)))))

(ert-deftest ebox-node-bounds-spans-first-or-every-painted-row ()
  (ebox-test-with-mounted (buffer root '(column (box :id "tall" :width (ch 4) :height (lh 2)
                                                     "ab")
                                                (box :width (ch 3) (text :id "wrap" "abc def"))))
    (let ((tall (car (ebox-selector-query root "#tall")))
          (wrap (car (ebox-selector-query root "#wrap"))))
      (pcase-let ((`(,start . ,end) (ebox-node-bounds tall)))
        (should (equal (string-trim-right (buffer-substring-no-properties start end)) "ab")))
      (pcase-let ((`(,start . ,end) (ebox-node-bounds tall t)))
        (should (equal (mapcar #'string-trim-right
                               (split-string (buffer-substring-no-properties start end) "\n"))
                       '("ab" ""))))
      (pcase-let ((`(,start . ,end) (ebox-node-bounds wrap)))
        (should (equal (buffer-substring-no-properties start end) "abc")))
      (pcase-let ((`(,start . ,end) (ebox-node-bounds wrap t)))
        (should (equal (mapcar #'string-trim-right
                               (split-string (buffer-substring-no-properties start end) "\n"))
                       '("abc" "def")))))))

(ert-deftest ebox-node-bounds-keep-hidden-flow-slots ()
  (ebox-test-with-mounted (buffer root '(box :position relative :width (ch 8) :height (lh 2)
                                             (row (box :id "slot" :visibility hidden
                                                       :width (ch 3) "abc")
                                                  (box "de"))
                                             (box :id "over" :position absolute :visibility hidden
                                                  :left (ch 0) :top (lh 1) :width (ch 2) "xy")))
    (let ((slot (car (ebox-selector-query root "#slot")))
          (over (car (ebox-selector-query root "#over"))))
      (pcase-let ((`(,start . ,end) (ebox-node-bounds slot)))
        (should (= start (point-min)))
        (should-not (string-match-p "[a-z]" (buffer-substring-no-properties start end))))
      (should-not (ebox-node-bounds over)))))

(ert-deftest ebox-descendants-inherit-or-block-native-feedback ()
  (ebox-test-with-mounted (buffer root '(box :help-echo "Outer" :pointer hand
                                             :hover-style (:background-color "#123456")
                                             (box :id "plain" "Plain")
                                             (box :id "own" :help-echo nil :pointer nil
                                                  :hover-style nil "Own")))
    (let ((plain (ebox-node-position (car (ebox-selector-query root "#plain"))))
          (own (ebox-node-position (car (ebox-selector-query root "#own")))))
      (should (equal (get-text-property plain 'help-echo) "Outer"))
      (should (eq (get-text-property plain 'pointer) 'hand))
      (should (get-text-property plain 'mouse-face))
      (should-not (get-text-property own 'help-echo))
      (should-not (get-text-property own 'pointer))
      (should-not (get-text-property own 'mouse-face)))))

(ert-deftest ebox-unanchored-overlay-has-no-position-or-focus ()
  (ebox-test-with-mounted (buffer root '(column :width (ch 20) :height (lh 4)
                                         (box :id "base" :tab-index 0 "Base")
                                         (box :id "pop" :position absolute :anchor "absent"
                                              :width (ch 10) :height (lh 1)
                                              (box :id "inner" :tab-index 0 "Inner"))))
    (let ((inner (car (ebox-selector-query root "#inner"))))
      (should-not (string-match-p "Inner" (buffer-string)))
      (should-not (ebox-node-position (car (ebox-selector-query root "#pop"))))
      (should-not (ebox-node-position inner))
      (should-error (ebox-focus inner buffer) :type 'user-error)
      (should (eq (ebox-focus-first buffer) (car (ebox-selector-query root "#base")))))))

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
