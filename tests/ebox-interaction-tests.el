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

(ert-deftest ebox-clipped-overlay-keeps-interaction-on-blank-rows ()
  (let* ((map (ebox-keymap-create :bindings `(("x" . ,(lambda () :ok)))))
         (rendered
          (ebox-render
           `(column :width (ch 12) :height (lh 3) :padding ((lh 0) (ch 2))
                    "page"
                    (column :position absolute :left (ch 0) :top (lh 0)
                            :width (% 100) :height (lh 3) :keymap ,map :pointer hand
                            :background-color "#101010"
                            (box :height (lh 1))
                            "over"
                            (box :height (lh 1))))))
         (covered 0))
    (dotimes (pos (length rendered))
      (when (equal (get-text-property pos 'face rendered) '(:background "#101010"))
        (setq covered (1+ covered))
        (should (eq (get-text-property pos 'keymap rendered) map))
        (should (eq (get-text-property pos 'pointer rendered) 'hand))))
    (should (> covered 4))))

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

(defun ebox-test--node (root id)
  "Return ROOT's node with ID."
  (car (ebox-selector-query root (concat "#" id))))

(ert-deftest ebox-focus-change-functions-report-each-move ()
  (ebox-test-with-mounted (buffer root
                           '(column
                             (box :id "a" :tab-index 0 "A")
                             (box :id "b" :tab-index 0 "B")))
    (let ((a (ebox-test--node root "a"))
          (b (ebox-test--node root "b"))
          changes)
      (with-current-buffer buffer
        (add-hook 'ebox-focus-change-functions
                  (lambda (old new) (push (cons old new) changes)) nil t))
      (ebox-focus a buffer)
      (ebox-focus a buffer)
      (ebox-focus-next 1 t buffer)
      (ebox-focus nil buffer)
      (should (equal (nreverse changes)
                     (list (cons nil a) (cons a b) (cons b nil)))))))

(ert-deftest ebox-focus-group-is-one-tab-stop-roved-by-arrows ()
  (ebox-test-with-mounted (buffer root
                           '(column
                             (box :id "before" :tab-index 0 "Before")
                             (column :id "list" :focus-group vertical
                                     (box :id "a" :tab-index 0 "A")
                                     (box :id "b" :tab-index 0
                                          :attributes (("aria-selected" . "true")) "B")
                                     (box :id "c" :tab-index 0 "C"))
                             (box :id "after" :tab-index 0 "After"))
                           :width 200 :height 10)
    (cl-flet ((node (id) (ebox-test--node root id)))
      (ebox-focus (node "before") buffer)
      (should (eq (ebox-focus-next 1 nil buffer) (node "b")))
      (should (eq (ebox-focus-direction 'down buffer) (node "c")))
      (should (eq (ebox-focus-next 1 nil buffer) (node "after")))
      (should (eq (ebox-focus-previous 1 nil buffer) (node "c")))
      (should (eq (ebox-focus-direction 'down buffer) (node "after")))
      (should (eq (ebox-focus-direction 'up buffer) (node "c")))
      (should (eq (ebox-focus-edge nil buffer) (node "a")))
      (should (eq (ebox-focus-direction 'up buffer) (node "before")))
      (should (eq (ebox-focus-direction 'up buffer) nil))
      (should (eq (ebox-focused-node buffer) (node "before"))))))

(ert-deftest ebox-focus-direction-moves-to-nearest-stop-and-enters-grids ()
  (ebox-test-with-mounted (buffer root
                           '(column
                             (row (box :id "left" :tab-index 0 :width (ch 6) "Left")
                                  (box :id "right" :tab-index 0 :width (ch 6) "Right"))
                             (row :id "grid" :focus-group grid
                                  (column :width (ch 6)
                                          (box :id "g1" :tab-index 0 "G1")
                                          (box :id "g3" :tab-index 0 "G3"))
                                  (column :width (ch 6)
                                          (box :id "g2" :tab-index 0 "G2")
                                          (box :id "g4" :tab-index 0 "G4"))))
                           :width 300 :height 10)
    (cl-flet ((node (id) (ebox-test--node root id)))
      (ebox-focus (node "left") buffer)
      (should (eq (ebox-focus-direction 'right buffer) (node "right")))
      (should-not (ebox-focus-direction 'right buffer))
      (should (eq (ebox-focus-direction 'left buffer) (node "left")))
      (should (eq (ebox-focus-direction 'down buffer) (node "g1")))
      (should (eq (ebox-focus-direction 'right buffer) (node "g2")))
      (should (eq (ebox-focus-direction 'down buffer) (node "g4")))
      (should (eq (ebox-focus-direction 'left buffer) (node "g3")))
      (should (eq (ebox-focus-direction 'up buffer) (node "g1")))
      (should (eq (ebox-focus-direction 'up buffer) (node "left"))))))

(ert-deftest ebox-modal-focus-scope-confines-navigation ()
  (ebox-test-with-mounted (buffer root
                           '(column
                             (box :id "outside" :tab-index 0 "Outside")
                             (column :id "dialog" :focus-scope modal
                                     (box :id "x" :tab-index 0 "X")
                                     (box :id "y" :tab-index 0 "Y")))
                           :width 200 :height 10)
    (cl-flet ((node (id) (ebox-test--node root id)))
      (should (eq (ebox-focus-scope buffer) (node "dialog")))
      (should (equal (ebox-focus-stops buffer) (list (node "x") (node "y"))))
      (should (eq (ebox-focus-first buffer) (node "x")))
      (should (eq (ebox-focus-next 1 t buffer) (node "y")))
      (should (eq (ebox-focus-next 1 t buffer) (node "x")))
      (should-not (ebox-focus-direction 'up buffer))
      (ebox-node-remove (node "dialog"))
      (ebox-flush)
      (should (eq (ebox-focus-scope buffer) root))
      (should (eq (ebox-focus-first buffer) (node "outside"))))))

(ert-deftest ebox-focus-reveals-node-inside-scroller ()
  (ebox-test-with-mounted (buffer root
                           `(column :id "list" :height (lh 3) :overflow scroll
                                    ,@(mapcar (lambda (i)
                                                `(box :id ,(format "i%d" i) :tab-index 0
                                                      ,(format "Item %d" i)))
                                              (number-sequence 0 9)))
                           :width 200 :height 6)
    (let ((list (ebox-test--node root "list"))
          (last (ebox-test--node root "i9")))
      (ebox-focus last buffer)
      (should (> (ebox-node-scroll-offset list) 0))
      (should (ebox-node-ancestor-p last (ebox-node-at (point) buffer)))
      (should (equal (string-trim (buffer-substring-no-properties
                                   (line-beginning-position) (line-end-position)))
                     "Item 9")))))

(ert-deftest ebox-focus-navigation-resumes-near-a-removed-node ()
  (ebox-test-with-mounted (buffer root
                           '(column
                             (box :id "a" :tab-index 0 "A")
                             (box :id "b" :tab-index 0 "B")
                             (box :id "c" :tab-index 0 "C"))
                           :width 200 :height 6)
    (cl-flet ((node (id) (ebox-test--node root id)))
      (ebox-focus (node "b") buffer)
      (ebox-node-remove (node "b"))
      (ebox-flush)
      (should-not (ebox-focused-node buffer))
      (should (eq (ebox-focus-next 1 nil buffer) (node "c")))
      (ebox-focus (node "c") buffer)
      (ebox-node-remove (node "c"))
      (ebox-flush)
      (should (eq (ebox-focus-direction 'up buffer) (node "a"))))))

(ert-deftest ebox-focus-shows-hover-content ()
  (ebox-test-with-mounted (buffer root
                           '(column
                             (box :id "row" :tab-index 0 :hover-content "Play" "Song")
                             (box :id "other" :tab-index 0 "Other"))
                           :width 200 :height 6)
    (cl-flet ((node (id) (ebox-test--node root id)))
      (ebox-focus (node "row") buffer)
      (ebox-flush)
      (should (string-match-p "Play" (buffer-substring-no-properties
                                      (point-min) (point-max))))
      (ebox-focus (node "other") buffer)
      (ebox-flush)
      (should (string-match-p "Song" (buffer-substring-no-properties
                                      (point-min) (point-max)))))))

(ert-deftest ebox-buffer-mode-arrows-move-focus-and-scroll-at-the-end ()
  (ebox-test-with-mounted (buffer root
                           '(column (box :id "a" :tab-index 0 "A")
                                    (box :id "b" :tab-index 0 "B"))
                           :width 200 :height 6)
    (cl-flet ((node (id) (ebox-test--node root id)))
      (ebox-focus (node "a") buffer)
      (call-interactively (key-binding (kbd "<down>")))
      (should (eq (ebox-focused-node buffer) (node "b")))
      (call-interactively (key-binding (kbd "C-p")))
      (should (eq (ebox-focused-node buffer) (node "a")))
      (call-interactively (key-binding (kbd "<end>")))
      (should (eq (ebox-focused-node buffer) (node "b"))))))

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

(ert-deftest ebox-buffer-mode-keeps-paren-matching-off-painted-text ()
  (require 'paren)
  (let ((global show-paren-mode))
    (unwind-protect
        (progn
          (show-paren-mode 1)
          (ebox-test-with-mounted (buffer _root '(column (text "a (b")))
            (with-current-buffer buffer
              (should ebox-buffer-mode)
              (should-not show-paren-mode)
              (ebox-buffer-mode -1)
              (should show-paren-mode)
              (should-not (local-variable-p 'show-paren-mode)))))
      (show-paren-mode (if global 1 -1)))))

(ert-deftest ebox-buffer-mode-shows-no-region-on-the-canvas ()
  (let ((buffer (get-buffer-create " *ebox-no-region*"))
        (config (current-window-configuration))
        (transient-mark-mode t))
    (unwind-protect
        (progn
          (set-window-buffer (selected-window) buffer)
          (set-buffer buffer)
          (ebox-mount buffer '(column (text "one") (text "two")))
          (execute-kbd-macro (kbd "C-SPC C-n"))
          (should-not (region-active-p))
          (ebox-buffer-mode -1)
          (execute-kbd-macro (kbd "C-SPC"))
          (should (region-active-p)))
      (set-window-configuration config)
      (kill-buffer buffer))))

(ert-deftest ebox-node-at-resolves-padding-cells-to-their-box ()
  (ebox-test-with-mounted (buffer root
                           '(column :width (ch 20)
                                    (box :id "first" "One")
                                    (box :id "second" :padding-top (lh 1)
                                         :padding-left (ch 2) "Two")))
    (let ((second (car (ebox-selector-query root "#second"))))
      ;; The padding line and the indent carry no node property; the hit
      ;; still resolves to the box that owns those cells.
      (should (eq (ebox-node-at (ebox-node-position second) buffer) second))
      (save-excursion
        (goto-char (point-min))
        (forward-line 2)
        (should (eq (ebox-node-at (point) buffer) second))))))

(ert-deftest ebox-node-at-resolves-scrolled-padding-cells-to-their-box ()
  (ebox-test-with-mounted (buffer root
                           '(column :width (ch 20) :height (lh 6)
                                    :overflow scroll
                                    (box :id "first" "One")
                                    (box :id "second" :padding-top (lh 1)
                                         :padding-left (ch 2) "Two")))
    (let ((second (car (ebox-selector-query root "#second"))))
      ;; The scroller's own cells cover its children's blank padding; the
      ;; innermost box covering the cell still owns it.
      (should (eq (ebox-node-at (ebox-node-position second) buffer) second))
      (save-excursion
        (goto-char (point-min))
        (forward-line 2)
        (should (eq (ebox-node-at (point) buffer) second))))))

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

(ert-deftest ebox-node-bounds-include-cells-under-own-overlays ()
  (ebox-test-with-mounted (buffer root '(column :width (ch 10)
                                                (box :id "track" :position relative
                                                     :width (ch 8) "--------"
                                                     (box :position absolute :left (ch 0)
                                                          :top (lh 0) :width (ch 3) "==="))))
    ;; An overlay inside the node paints the node itself; its bounds still
    ;; start at the node's first cell.
    (pcase-let ((`(,start . ,end) (ebox-node-bounds (car (ebox-selector-query root "#track")))))
      (should (= start (point-min)))
      (should (equal (buffer-substring-no-properties start end) "===-----")))))

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

(ert-deftest ebox-hover-paints-over-a-nodes-own-background ()
  ;; Hover paint is unconditional: whether a selected element keeps its own
  ;; surface is application policy (declare :hover-style nil for it), because
  ;; only the application knows which state counts as selected.
  (let ((rendered (ebox-render '(box :background-color "#ffffff"
                                     :hover-style (:background-color "#123456")
                                     "Filled"))))
    (should (equal (get-text-property 0 'mouse-face rendered)
                   '(:background "#123456")))))

(ert-deftest ebox-hover-spans-every-row-of-a-multiline-node ()
  (ebox-test-with-mounted (buffer root '(column :width 'stretch
                                               (box :id "tall" :width 'stretch
                                                    :hover-style (:background-color "#123456")
                                                    (column "aa" "aa" "aa"))
                                               (box :id "after" :height (lh 1) "zz")))
    (let* ((start (ebox-node-position (car (ebox-selector-query root "#tall"))))
           (hover (get-text-property start 'mouse-face)))
      (should hover)
      ;; Every painted cell of the element shares the hover face, so the
      ;; native mouse-face run covers the element's whole area instead of only
      ;; the row under the pointer.  The newlines between its rows carry the
      ;; same face.
      (save-excursion
        (goto-char start)
        (forward-line 1)
        (should (eq hover (get-text-property (1- (point)) 'mouse-face)))
        (forward-line 1)
        (should (eq hover (get-text-property (1- (point)) 'mouse-face)))
        ;; A row that does not continue the element does not carry the run.
        (forward-line 1)
        (should-not (get-text-property (1- (point)) 'mouse-face))))))

(ert-deftest ebox-hover-keeps-a-single-row-element-within-its-cells ()
  (ebox-test-with-mounted (buffer root '(column :width 'stretch
                                               (box :id "one" :width 'stretch
                                                    :hover-style (:background-color "#123456") "AB")
                                               (box :height (lh 1) "zz")))
    (let ((start (ebox-node-position (car (ebox-selector-query root "#one")))))
      (should (get-text-property start 'mouse-face))
      ;; The newline after the element's only row carries no face, so hover
      ;; feedback cannot bleed into the rest of the screen row.
      (save-excursion
        (goto-char start)
        (forward-line 1)
        (should-not (get-text-property (1- (point)) 'mouse-face))))))

(ert-deftest ebox-render-carries-hover-across-rendered-rows ()
  (let* ((rendered (ebox-render '(box :width (ch 6)
                                       :hover-style (:background-color "#123456")
                                       (column "aa" "aa" "aa"))))
         (first (string-search "\n" rendered))
         (second (and first (string-search "\n" rendered (1+ first))))
         (hover (get-text-property 0 'mouse-face rendered)))
    (should hover)
    (should first)
    (should second)
    (should (eq hover (get-text-property first 'mouse-face rendered)))
    (should (eq hover (get-text-property second 'mouse-face rendered)))
    (should (eq hover (get-text-property (1- (length rendered)) 'mouse-face rendered)))))

(ert-deftest ebox-hidden-node-paints-no-interaction-feedback ()
  ;; A hidden node keeps its layout slot to preserve the surrounding layout,
  ;; but paints nothing; that includes interaction feedback, so an empty list
  ;; slot offers no hover highlight, pointer or help.
  (ebox-test-with-mounted (buffer root '(column :width (ch 8)
                                               (box :height (lh 1)
                                                    :hover-style (:background-color "#123456")
                                                    :help-echo "shown" :pointer hand
                                                    "SHOW")
                                               (box :height (lh 1) :visibility hidden
                                                    :hover-style (:background-color "#123456")
                                                    :help-echo "hidden" :pointer hand
                                                    "HIDE")))
    (should (get-text-property (point-min) 'mouse-face))
    (save-excursion
      (goto-char (point-min))
      (forward-line 1)
      (let ((start (point)) (end (line-end-position)))
        (should (> end start))
        (should (string-blank-p (buffer-substring-no-properties start end)))
        (while (< (point) end)
          (should-not (get-text-property (point) 'mouse-face))
          (should-not (get-text-property (point) 'help-echo))
          (should-not (get-text-property (point) 'pointer))
          (forward-char))))))

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
