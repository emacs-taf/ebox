;;; ebox-interaction-tests.el --- Public API acceptance -*- lexical-binding: t; -*-

;;; Commentary:
;; Test supported package inputs, outputs, errors and lifecycle.
;; Internal implementation details are outside this contract.

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'ebox)

(defun ebox-interaction-test--position (string text)
  "Return the position of TEXT in STRING, asserting that it exists."
  (or (string-match (regexp-quote text) string) (ert-fail text)))

(ert-deftest ebox-help-create-adapts-literal-business-functions ()
  "Help callbacks use buffer, overlay and displayed-string contexts lazily."
  (let ((target (generate-new-buffer " *ebox-help-target*"))
        (calls 0) observed)
    (unwind-protect
        (save-window-excursion
          (let* ((selected (selected-window))
                 (help (ebox-help-create
                        (lambda () (cl-incf calls)
                          (setq observed (list (current-buffer) (point)
                                               (selected-window)))
                          "help")))
                 overlay)
            (with-current-buffer target
              (insert "target") (goto-char 3)
              (setq overlay (make-overlay 1 3)))
            (ebox-build (list 'text :help-echo help "text"))
            (should (= calls 0))
            (dolist (object (list target overlay))
              (should (equal (funcall help nil object 1) "help"))
              (should (equal observed (list target 3 selected))))
            (set-window-buffer selected target)
            (should (equal (funcall help selected "displayed" 0) "help"))
            (should (equal observed (list target 3 selected)))
            (should (= calls 3))
            (delete-overlay overlay)
            (should-error (funcall help nil overlay 1) :type 'user-error)
            (should-error (funcall help nil "displayed" 0) :type 'user-error)
            (should-not (funcall (ebox-help-create #'ignore) nil target 1))
            (should-error (funcall (ebox-help-create (lambda () 7)) nil target 1))
            (should-error (ebox-help-create nil))
            (should-error (ebox-help-create (lambda (required) required)))))
      (kill-buffer target))))

(ert-deftest ebox-interaction-full-keymap-is-an-owned-snapshot ()
  "Full character-table maps cannot mutate rendered or future input snapshots."
  (let ((map (make-keymap)))
    (define-key map (kbd "RET") #'ignore)
    (let* ((input (ebox-build (list 'text :keymap map "text")))
           (rendered (ebox-render input)))
      (define-key map (kbd "RET") #'forward-char)
      (dolist (text (list rendered (ebox-render input)))
        (should (eq (lookup-key (get-text-property 0 'keymap text) (kbd "RET"))
                    #'ignore))))))

(ert-deftest ebox-interaction-named-keymap-graphs-are-owned-snapshots ()
  "Named root, prefix and parent maps cannot mutate an accepted node."
  (let* ((name (make-symbol "root-map"))
         (prefix-name (make-symbol "prefix-map"))
         (parent-name (make-symbol "parent-map"))
         (map (make-keymap))
         (prefix (make-sparse-keymap))
         (parent (make-sparse-keymap)))
    (fset name map)
    (fset prefix-name prefix)
    (fset parent-name parent)
    (define-key map (kbd "RET") #'ignore)
    (define-key prefix (kbd "x") #'forward-char)
    (define-key prefix (kbd "r") name)
    (define-key parent (kbd "p") #'backward-char)
    (define-key map (kbd "C-c") prefix-name)
    (define-key map [menu-bar item] (list 'menu-item "Prefix" prefix-name))
    (set-keymap-parent map parent-name)
    (let* ((input (ebox-build (list 'text :keymap name "text")))
           (rendered (ebox-render input)))
      (define-key map (kbd "RET") #'forward-char)
      (define-key prefix (kbd "x") #'ignore)
      (define-key parent (kbd "p") #'ignore)
      (fset name (make-sparse-keymap))
      (dolist (text (list rendered (ebox-render input)))
        (let ((actual (get-text-property 0 'keymap text)))
          (should-not (symbolp actual))
          (should (eq (lookup-key actual (kbd "RET")) #'ignore))
          (should (eq (lookup-key actual (kbd "C-c x")) #'forward-char))
          (should (eq (lookup-key actual (kbd "p")) #'backward-char))
          (should (eq (lookup-key actual (kbd "C-c r")) actual))
          (should (eq (lookup-key actual (vconcat [menu-bar item] (kbd "x")))
                      #'forward-char)))))))

(ert-deftest ebox-interaction-batch-reads-the-current-source-generation ()
  "Two updates to one node in a batch retain every accumulated native fact."
  (let ((buffer (generate-new-buffer " *ebox-interaction-batch*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer
           buffer (ebox-build '(text :id t :help-echo "old" :pointer hand "text")))
          (let ((handle (ebox-region-resolve buffer t)))
            (ebox-incremental-begin-batch buffer)
            (ebox-region-update handle :help-echo "new")
            (ebox-region-update handle :pointer 'text)
            (ebox-incremental-flush buffer))
          (with-current-buffer buffer
            (should (equal (get-text-property (point-min) 'help-echo) "new"))
            (should (eq (get-text-property (point-min) 'pointer) 'text))))
      (kill-buffer buffer))))

(ert-deftest ebox-keymap-create-wraps-literal-local-callbacks ()
  "Reusable maps expose activation and extra keys as ordinary native commands."
  (let* ((activations 0) (extras 0)
         (map (ebox-keymap-create
               :activate (lambda () (cl-incf activations))
               :bindings (list (cons "x" (lambda () (cl-incf extras)))
                               (cons [f5] (lambda () (cl-incf extras)))))))
    (should (keymapp map))
    (should (= activations 0))
    (should (= extras 0))
    (dolist (key '("RET" [return] "SPC" [mouse-1]))
      (should (commandp (lookup-key map (if (stringp key) (kbd key) key)))))
    (let ((last-input-event ?\r))
      (call-interactively (lookup-key map (kbd "RET")))
      (call-interactively (lookup-key map "x"))
      (call-interactively (lookup-key map [f5])))
    (should (= activations 1))
    (should (= extras 2))
    (with-temp-buffer
      (insert (ebox-render (ebox-build (list 'text :keymap map "action"))))
      (goto-char (point-min))
      (should (eq (key-binding (kbd "RET")) (lookup-key map (kbd "RET"))))))
  (should (keymapp (ebox-keymap-create)))
  (should-not (lookup-key (ebox-keymap-create :activate nil :bindings nil)
                          (kbd "RET"))))

(ert-deftest ebox-keymap-create-rejects-malformed-and-overlapping-bindings ()
  "Invalid callbacks and duplicate or shadowed key sequences fail at creation."
  (dolist (options '((:unknown t) (:activate) (:activate ignore :activate ignore)
                     (:activate 2) (:activate (lambda (required) required))
                     (:bindings malformed) (:bindings (invalid))
                     (:bindings ((nil . ignore)))
                     (:bindings (("x" . nil)))
                     (:bindings (("" . ignore)))
                     (:bindings (([] . ignore)))
                     (:bindings (([1.5] . ignore)))
                     (:bindings (("x" . ignore) ([120] . ignore)))
                     (:bindings (("C-m" . ignore) ("RET" . ignore)))
                     (:bindings (("x" . ignore) ("x y" . ignore)))
                     (:bindings (("x y" . ignore) ("x" . ignore)))
                     (:drag-lock-modifier shift)
                     (:drag (lambda (_gesture) nil) :drag-lock-modifier invalid)
                     (:activate ignore :bindings (("RET" . ignore)))
                     (:activate ignore :bindings (([mouse-1] . ignore)))))
    (should-error (apply #'ebox-keymap-create options))))

(ert-deftest ebox-keymap-create-supports-drag-lock-modifier ()
  "A supported modifier creates a native locked-drag keymap."
  (let ((map (ebox-keymap-create
              :drag (lambda (_gesture) nil)
              :drag-lock-modifier 'shift)))
    (should (keymapp map))
    (should (commandp (lookup-key map [down-mouse-1])))))

(ert-deftest ebox-keymap-create-mouse-uses-event-buffer-without-moving-focus ()
  "Mouse callbacks target the clicked buffer even when another buffer is current."
  (let ((target (generate-new-buffer " *ebox-keymap-target*"))
        (other (generate-new-buffer " *ebox-keymap-other*"))
        observed)
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (set-window-buffer (selected-window) other)
          (let* ((selected (selected-window))
                 (window (split-window-right))
                 (map (ebox-keymap-create
                       :activate (lambda ()
                                   (setq observed
                                         (list (current-buffer) (point)
                                               (selected-window))))))
                 (command (lookup-key map [mouse-1])))
            (set-window-buffer window target)
            (with-current-buffer target (insert "target") (goto-char 4))
            (with-current-buffer other
              (insert "other") (goto-char 2)
              (let ((last-input-event
                     (list 'mouse-1 (list window 1 '(1 . 1) 0))))
                (call-interactively command))
              (should (equal observed (list target 4 selected)))
              (should (eq (current-buffer) other))
              (should (= (point) 2))
              (should (eq (selected-window) selected))
              (setq observed nil)
              (dolist (position '(mode-line -1 100))
                (should-error
                 (funcall command (list 'mouse-1
                                        (list window position '(1 . 1) 0)))
                 :type 'user-error))
              (should-error (funcall command 'mouse-1) :type 'user-error)
              (delete-window window)
              (should-error (funcall command
                                     (list 'mouse-1 (list window 1 '(1 . 1) 0)))
                            :type 'user-error)
              (should-not observed))))
      (kill-buffer target)
      (kill-buffer other))))

(defun ebox-interaction-test--mouse-event (type window position)
  "Return an event of TYPE at WINDOW's POSITION with its native click count."
  (append (list type (list window position '(1 . 1) 0))
          (cond
           ((memq 'drag (event-modifiers type))
            (list (list window (1+ position) '(2 . 1) 1)))
           ((memq 'triple (event-modifiers type)) '(3))
           ((memq 'double (event-modifiers type)) '(2)))))

(defun ebox-interaction-test--dispatch-mouse (type window position)
  "Dispatch a native event of TYPE at WINDOW's POSITION without moving point."
  (let* ((event (ebox-interaction-test--mouse-event type window position))
         (keys (vector event))
         (command (with-current-buffer (window-buffer window)
                    (key-binding keys nil nil position)))
         (map (with-current-buffer (window-buffer window)
                (get-text-property position 'keymap))))
    ;; Resolve the event's actual window/position, not the caller's point.
    ;; Fail before invoking a global drag command that would read more input.
    (should (commandp command))
    (should (eq command (lookup-key map (vector type))))
    (let ((last-input-event event))
      (call-interactively command nil keys))))

(ert-deftest ebox-keymap-create-repeated-clicks-preserve-point-and-selection ()
  "Press/release/drag sequences activate once per click without text selection."
  (let ((target (generate-new-buffer " *ebox-click-target*"))
        (other (generate-new-buffer " *ebox-click-other*"))
        (calls 0) seen)
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (set-window-buffer (selected-window) other)
          (let* ((selected (selected-window))
                 (window (split-window-right))
                 (map (ebox-keymap-create
                       :activate (lambda ()
                                   (cl-incf calls)
                                   (push (current-buffer) seen)
                                   (ebox-region-update "action" :help-echo
                                                       (number-to-string calls))))))
            (ebox-render-to-buffer
             target (ebox-build (list 'column
                                     (list 'text :id "action" :keymap map "action")
                                     '(text "ordinary text"))))
            (set-window-buffer window target)
            (with-current-buffer other
              (insert "other") (goto-char 2) (set-mark 4)
              (setq mark-active nil)
              (dolist (active '(nil t))
                (with-current-buffer target
                  (setq buffer-read-only t)
                  (goto-char (- (point-max) 2)) (set-mark 3)
                  (setq mark-active active))
                (let ((point-before (with-current-buffer target (point)))
                      (window-point-before (window-point window)))
                  (dolist (events '((down-mouse-1 mouse-1)
                                     (double-down-mouse-1 double-mouse-1)
                                     (triple-down-mouse-1 triple-mouse-1)))
                    (let ((before calls))
                      (cl-letf (((symbol-function 'read-event)
                                 (lambda (&rest _)
                                   (should (= calls before))
                                   (list (cadr events) (list window 1 '(1 . 1) 0)))))
                        (ebox-interaction-test--dispatch-mouse (car events) window 1))
                      (should (= calls (1+ before)))))
                  (let ((before calls))
                    (dolist (type '(drag-mouse-1 double-drag-mouse-1
                                               triple-drag-mouse-1))
                      (ebox-interaction-test--dispatch-mouse type window 1))
                    (should (= calls before)))
                  (with-current-buffer target
                    (should (= (point) point-before))
                    (should (= (mark) 3))
                    (should (eq mark-active active)))
                  (should (= (window-point window) window-point-before))
                  (should (eq (current-buffer) other))
                  (should (= (point) 2))
                  (should (= (mark) 4))
                  (should-not mark-active)
                  (should (eq (selected-window) selected)))))
            (should (= calls 6))
            (should (cl-every (lambda (buffer) (eq buffer target)) seen))))
      (kill-buffer target)
      (kill-buffer other))))

(ert-deftest ebox-keymap-create-click-defaults-follow-replacement-and-removal ()
  "Native click defaults follow published maps while explicit bindings win."
  (let ((buffer (generate-new-buffer " *ebox-click-lifecycle*"))
        (activations 0) (overrides 0))
    (unwind-protect
        (save-window-excursion
          (let ((window (selected-window))
                (map (ebox-keymap-create :activate (lambda ()
                                                    (cl-incf activations)))))
            (ebox-render-to-buffer
             buffer (ebox-build (list 'text :id "action" :keymap map "action")))
            (set-window-buffer window buffer)
            (with-current-buffer buffer
              (ebox-region-update "action" :color "red")
              (ebox-rerender-buffer-with-context buffer 80 30)
              (ebox-interaction-test--dispatch-mouse 'double-mouse-1 window 1)
              (should (= activations 1))
              (ebox-region-update
               "action" :keymap
               (ebox-keymap-create
                :activate (lambda () (cl-incf activations))
                :bindings (mapcar (lambda (key)
                                    (cons (vector key)
                                          (lambda () (cl-incf overrides))))
                                  '(down-mouse-1 double-mouse-1 triple-mouse-1
                                                drag-mouse-1))))
              (dolist (type '(down-mouse-1 double-mouse-1 triple-mouse-1
                                         drag-mouse-1))
                (ebox-interaction-test--dispatch-mouse type window 1))
              (should (= overrides 4))
              (should (= activations 1))
              (ebox-interaction-test--dispatch-mouse 'mouse-1 window 1)
              (should (= activations 2))
              ;; A raw map remains literal; replacing/removing the helper
              ;; restores native selection instead of leaving stale guards.
              (ebox-region-update "action" :keymap '(keymap (mouse-1 . ignore)))
              (let ((event (list 'down-mouse-1 (list window 1 '(1 . 1) 0))))
                (should (eq (key-binding (vector event))
                            (global-key-binding [down-mouse-1]))))
              (should-not (lookup-key (get-text-property 1 'keymap)
                                      [double-mouse-1]))
              (ebox-region-update "action" :keymap nil)
              (dolist (type '(down-mouse-1 mouse-1 drag-mouse-1))
                (let ((event (list type (list window 1 '(1 . 1) 0))))
                  (should (eq (key-binding (vector event))
                              (global-key-binding (vector type)))))))))
      (kill-buffer buffer))))

(ert-deftest ebox-region-update-semantic-id-keeps-handle-lifecycle ()
  "IDs resolve locally and opaque handles retain their owning surface checks."
  (let ((first (generate-new-buffer " *ebox-id-first*"))
        (second (generate-new-buffer " *ebox-id-second*")))
    (unwind-protect
        (progn
          (dolist (buffer (list first second))
            (ebox-render-to-buffer
             buffer (ebox-build '(column
                                  (box :id "target" "before")
                                  (box :id 7 "integer")
                                  (box :id "duplicate" "first")
                                  (box :id "duplicate" "second")))))
          (let ((handle (ebox-region-resolve first "target")))
            (with-current-buffer second
              (ebox-region-update 'target :content "local")
              (ebox-region-update 7 :content "seven")
              (should (string-match-p "local" (buffer-string)))
              (should (string-match-p "seven" (buffer-string)))
              (ebox-region-update handle :content "other")
              (dolist (id '(nil 1.5 [] (target)))
                (should-error (ebox-region-update id :content "invalid")
                              :type 'wrong-type-argument))
              (should-error (ebox-region-update "missing" :content "invalid")
                            :type 'user-error)
              (should-error (ebox-region-update "duplicate" :content "invalid")
                            :type 'user-error))
            (with-current-buffer first
              (should (string-match-p "other" (buffer-string))))
            (ebox-commit first (ebox-build '(box :id "replacement" "new")))
            (with-current-buffer second
              (should-error (ebox-region-update handle :content "stale")
                            :type 'user-error))
            (with-current-buffer first
              (should (equal (buffer-substring-no-properties
                              (point-min) (point-max)) "new"))))
          (with-temp-buffer
            (should-error (ebox-region-update "target" :content "invalid")
                          :type 'user-error)))
      (kill-buffer first)
      (kill-buffer second))))

(ert-deftest ebox-interaction-closed-node-contract ()
  "The four capabilities are validated independently from the style schema."
  (dolist (tag '(text box row column flex grid))
    (let* ((input (ebox-build
                   (list tag :help-echo "Hint" :pointer 'hand
                         :hover-style '(:color "red"
                                       :background-color "blue"
                                       :text-decoration-line underline)
                         :keymap (make-sparse-keymap) "hello")))
           (text (ebox-render input))
           (position (ebox-interaction-test--position text "hello")))
      (should (equal (get-text-property position 'help-echo text) "Hint"))
      (should (eq (get-text-property position 'pointer text) 'hand))
      (should (keymapp (get-text-property position 'keymap text)))
      (should (equal (get-text-property position 'mouse-face text)
                     '(:underline t :overline nil :strike-through nil
                       :foreground "red" :background "blue")))))
  (dolist (props '((:help-echo 1) (:pointer invalid) (:hover-content 1)
                   (:keymap (bogus))
                   (:hover-style (:font-weight bold))
                   (:hover-style (:padding (px 2)))
                   (:hover-style (:face highlight))
                   (:hover-style (:color red))
                   (:hover-style (:color "red" :color "blue"))
                   (:pointer hand :pointer text)
                   (:tps (help-echo "x")) (:local-map nil)
                   (:surface-properties (help-echo "x"))))
    (should-error (ebox-build (append '(box) props '("x"))))))

(ert-deftest ebox-interaction-scope-and-explicit-nil ()
  "Inner nil blocks outer values without extending own effects to margins."
  (let* ((text (ebox-render
                (ebox-build
                 '(box :width (ch 30) :padding ((lh 1) (ch 1))
                       :margin ((lh 1) (ch 1))
                       :border-width (px 1) :border-style solid :border-color "red"
                       :help-echo "outer" :pointer hand
                       :hover-style (:background-color "blue")
                       :keymap (keymap (13 . ignore))
                       (row (text :help-echo nil :pointer nil
                                  :hover-style nil :keymap nil "blocked")
                            (text :help-echo "child" "child")
                            "inherited")))))
         (blocked (ebox-interaction-test--position text "blocked"))
         (child (ebox-interaction-test--position text "child"))
         (inherited (ebox-interaction-test--position text "inherited")))
    (dolist (property '(help-echo pointer mouse-face keymap))
      (should (plist-member (text-properties-at blocked text) property))
      (should-not (get-text-property blocked property text))
      (should (get-text-property inherited property text)))
    (should (equal (get-text-property child 'help-echo text) "child"))
    (dotimes (position (length text))
      (when (or (= (aref text position) ?\n)
                (cl-some (lambda (property)
                           (get-text-property position property text))
                         '(ebox-ml ebox-mr ebox-mt ebox-mb)))
        (dolist (property '(help-echo pointer mouse-face keymap))
          (should-not (get-text-property position property text)))))))

(defun ebox-interaction-test--assert-hover-row (text)
  "Assert TEXT contains one native hover group from left to right padding."
  (let* ((position (ebox-interaction-test--position text "action"))
         (line-start (1+ (or (cl-position ?\n text :end position :from-end t) -1)))
         (line-end (or (cl-position ?\n text :start position) (length text)))
         (mouse-face (get-text-property position 'mouse-face text))
         (interior 0) (sides 0) (padding 0))
    (should mouse-face)
    (cl-loop for index from line-start below line-end do
             (cond
              ((or (get-text-property index 'ebox-bl text)
                   (get-text-property index 'ebox-br text))
               (cl-incf sides)
               (should-not (get-text-property index 'mouse-face text)))
              ((get-text-property index 'ebox--hover-style text)
               (cl-incf interior)
               (when (or (get-text-property index 'ebox-pl text)
                         (get-text-property index 'ebox-pr text))
                 (cl-incf padding))
               ;; Emacs discovers native hover boundaries by identity, not by
               ;; equal face attributes.  A per-run copy would split this row.
               (should (eq mouse-face
                           (get-text-property index 'mouse-face text))))))
    (should (> interior (length "action")))
    (should (= sides 2))
    (should (= padding 2))))

(ert-deftest ebox-interaction-child-update-keeps-parent-hover-group ()
  "A child-only publication cannot separate its parent's native hover identity."
  (let ((buffer (generate-new-buffer " *ebox-hover-child-patch*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer
           buffer
           (ebox-build
            '(box :id "frame" :width (ch 24) :padding ((lh 1) (ch 2))
                  :color "#123456" :background-color "#EEEEEE"
                  :border-width (px 1) :border-style solid :border-color "#804020"
                  :hover-style (:background-color "#ACDCEC")
                  (text :id "label" "action1"))))
          (with-current-buffer buffer
            (dolist (label '("action2" "action3" "action longer"))
              (ebox-region-update "label" :content label)
              (ebox-interaction-test--assert-hover-row (buffer-string)))
            (ebox-region-update "label" :help-echo "child hint")
            (ebox-interaction-test--assert-hover-row (buffer-string))
            (ebox-region-update "label" :keymap '(keymap (13 . ignore)))
            (ebox-interaction-test--assert-hover-row (buffer-string))))
      (kill-buffer buffer))))

(ert-deftest ebox-interaction-equal-explicit-child-hover-is-another-group ()
  "An explicit child hover owns a different group even with equal paint."
  (let* ((text (ebox-render
                (ebox-build
                 '(row :color "#123456" :hover-style (:background-color "#ACDCEC")
                       (text "outer")
                       (text :hover-style (:background-color "#ACDCEC") "inner")
                       (text :hover-style nil "blocked")))))
         (outer (get-text-property
                 (ebox-interaction-test--position text "outer") 'mouse-face text))
         (inner (get-text-property
                 (ebox-interaction-test--position text "inner") 'mouse-face text)))
    (should (equal outer inner))
    (should-not (eq outer inner))
    (should-not (get-text-property
                 (ebox-interaction-test--position text "blocked") 'mouse-face text))))

(ert-deftest ebox-interaction-literal-callback-and-cyclic-keymap ()
  "Callbacks remain literal and a recursive keymap can be safely snapshotted."
  (let* ((calls 0)
         (hint (lambda (_window _object _position)
                 (cl-incf calls) "dynamic"))
         (map (make-sparse-keymap)))
    (define-key map [prefix] map)
    (define-key map (kbd "RET") #'ignore)
    (let* ((input (ebox-build (list 'box :help-echo hint :keymap map "x")))
           (text (ebox-render input))
           (actual (get-text-property 0 'keymap text)))
      (should (= calls 0))
      (should (eq (get-text-property 0 'help-echo text) hint))
      (should (eq (lookup-key actual [prefix]) actual))
      (define-key map (kbd "RET") #'forward-char)
      (should (eq (lookup-key actual (kbd "RET")) #'ignore))
      (should (equal (funcall (get-text-property 0 'help-echo text) nil text 0)
                     "dynamic"))
      (should (= calls 1)))))

(ert-deftest ebox-interaction-public-update-replace-clear-and-rollback ()
  "Mounted interaction changes publish atomically and replace or clear maps."
  (let* ((ebox-native-reflow-module-path nil)
         (buffer (ebox-render-to-buffer
                  (generate-new-buffer-name " *ebox-interaction-test*")
                  (ebox-build '(box :id "target" :width (ch 20)
                                    :help-echo "before" :pointer hand
                                    :keymap (keymap (13 . ignore)) "value")))))
    (unwind-protect
        (with-current-buffer buffer
          (let ((handle (ebox-region-resolve buffer "target"))
                (map (make-sparse-keymap)))
            (define-key map (kbd "RET") #'forward-char)
            (ebox-region-update handle :keymap map :help-echo "after"
                                :pointer 'text
                                :hover-style '(:color "red"))
            (goto-char (point-min))
            (search-forward "value")
            (let ((position (- (point) 5)))
              (should (equal (get-text-property position 'help-echo) "after"))
              (should (eq (lookup-key (get-text-property position 'keymap)
                                     (kbd "RET")) #'forward-char))
              (should (eq (get-text-property position 'pointer) 'text))
              (should (equal (get-text-property position 'mouse-face)
                             '(:foreground "red")))
              (let ((before (buffer-substring (point-min) (point-max))))
                (should-error (ebox-region-update handle :help-echo "bad"
                                                 :pointer 'invalid))
                (should (equal-including-properties
                         before (buffer-substring (point-min) (point-max)))))
              (ebox-region-update handle :help-echo nil :pointer nil
                                  :hover-style nil :keymap nil)
              (dolist (property '(help-echo pointer mouse-face keymap))
                (should-not (get-text-property position property))))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-interaction-hidden-and-zero-height-have-no-actions ()
  "Hidden and empty surfaces cannot expose commands or ancestor hover effects."
  (dolist (tag '(box row column flex grid))
    (let ((text (ebox-render
                 (ebox-build
                  (list 'box :help-echo "parent" :pointer 'hand
                        :keymap '(keymap (13 . ignore))
                        :hover-style '(:color "red")
                        (list tag :visibility 'hidden :keymap '(keymap)
                              :help-echo "hidden" "hidden"))))))
      (dotimes (position (length text))
        (dolist (property '(help-echo pointer mouse-face keymap))
          (should-not (get-text-property position property text))))))
  (should (equal (ebox-render
                  (ebox-build '(box :height (lh 0) :keymap (keymap)
                                    :help-echo "empty" "content"))) "")))

(ert-deftest ebox-interaction-keymap-boundaries-use-current-node ()
  "First characters, nil overrides, margins and the end use the correct map."
  (with-temp-buffer
    (let ((map (make-sparse-keymap)))
      (define-key map (kbd "RET") #'backward-char)
      (use-local-map map))
    (insert (ebox-render
             (ebox-build
              '(row :keymap (keymap (13 . ignore))
                    (text "parent")
                    (text :keymap nil "blocked")
                    (box :keymap (keymap (13 . forward-char))
                         :margin-inline (px 2) "child")
                    (text "tail")))))
    (dolist (entry '(("parent" . ignore) ("blocked" . backward-char)
                     ("child" . forward-char) ("tail" . ignore)))
      (goto-char (point-min))
      (search-forward (car entry))
      (goto-char (- (point) (length (car entry))))
      (should (eq (key-binding (kbd "RET")) (cdr entry))))
    (goto-char (point-max))
    (should (eq (key-binding (kbd "RET")) #'backward-char))))

(ert-deftest ebox-interaction-parent-update-preserves-child-and-rolls-back ()
  "Ancestor changes keep local nil and a failed commit restores current maps."
  (let ((buffer (generate-new-buffer " *ebox-interaction-parent*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer
           buffer (ebox-build '(row :id "parent" :keymap (keymap (13 . ignore))
                                    :help-echo "old"
                                    (text :keymap nil :help-echo nil "blocked")
                                    (text :keymap (keymap (13 . forward-char))
                                          :help-echo "child" "child")
                                    "parent")))
          (ebox-region-update (ebox-region-resolve buffer "parent")
                              :keymap '(keymap (13 . backward-char))
                              :help-echo "new")
          (with-current-buffer buffer
            (let* ((text (buffer-string))
                   (blocked (1+ (ebox-interaction-test--position text "blocked")))
                   (child (1+ (ebox-interaction-test--position text "child")))
                   (parent (1+ (ebox-interaction-test--position text "parent"))))
              (should-not (get-text-property blocked 'keymap))
              (should-not (get-text-property blocked 'help-echo))
              (should (eq (lookup-key (get-text-property child 'keymap)
                                     (kbd "RET")) #'forward-char))
              (should (equal (get-text-property child 'help-echo) "child"))
              (should (eq (lookup-key (get-text-property parent 'keymap)
                                     (kbd "RET")) #'backward-char))
              (should (equal (get-text-property parent 'help-echo) "new"))
              (let ((revision (ebox-surface-buffer-revision buffer)))
                (should-error
                 (ebox-commit buffer (ebox-build '(row :id "parent"
                                                      :keymap (keymap) "changed"))
                              (lambda (_report) (error "Reject interaction"))))
                (should (= revision (ebox-surface-buffer-revision buffer)))
                (should (equal-including-properties text (buffer-string)))))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-interaction-scroll-replaces-the-visible-actions ()
  "Scrolling clipped content publishes only the currently visible binding."
  (let ((buffer (generate-new-buffer " *ebox-interaction-scroll*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer
           buffer (ebox-build '(box :id "scroll" :height (lh 1) :width (ch 20)
                                    :overflow scroll
                                    (column
                                     (text :help-echo "first"
                                           :keymap (keymap (13 . forward-char))
                                           "first")
                                     (text :help-echo "second"
                                           :keymap (keymap (13 . backward-char))
                                           "second")))))
          (ebox-region-update (ebox-region-resolve buffer "scroll") :scroll-offset 1)
          (with-current-buffer buffer
            (should-not (string-match-p "first" (buffer-string)))
            (goto-char (point-min))
            (search-forward "second")
            (goto-char (- (point) 6))
            (should (equal (get-text-property (point) 'help-echo) "second"))
            (should (eq (key-binding (kbd "RET")) #'backward-char))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-interaction-navigation-nested-owners-and-boundaries ()
  "Inherited fragments form one stop while explicit nested maps stay distinct."
  (with-temp-buffer
    (ebox-render-to-buffer
     (current-buffer)
     (ebox-build '(column
                  (text "intro")
                  (box :keymap (keymap (13 . ignore))
                       (column (text "parent-one")
                               (text :keymap nil "blocked")
                               (text :keymap (keymap (13 . forward-char)) "child")
                               (text "parent-two")))
                  (text :keymap (keymap (13 . ignore)) "last"))))
    (let* ((text (buffer-string))
           (parent (1+ (ebox-interaction-test--position text "parent-one")))
           (child (1+ (ebox-interaction-test--position text "child")))
           (tail (1+ (ebox-interaction-test--position text "parent-two")))
           (last (1+ (ebox-interaction-test--position text "last"))))
      (goto-char (point-min))
      (should (= (ebox-next-interaction) parent))
      (should (= (ebox-next-interaction) child))
      (should (= (ebox-next-interaction) last))
      (should-error (ebox-next-interaction) :type 'user-error)
      (should (= (point) last))
      (should (= (ebox-previous-interaction 2) parent))
      (should-error (ebox-previous-interaction) :type 'user-error)
      (should (= (point) parent))
      (should (= (ebox-next-interaction 0) parent))
      (should (= (ebox-previous-interaction -1) child))
      (should (= (ebox-next-interaction -1) parent))
      (goto-char tail)
      (should (= (ebox-previous-interaction) child))
      (goto-char tail)
      (should (= (ebox-next-interaction) last))
      (goto-char (point-min))
      (should-error (ebox-next-interaction 4) :type 'user-error)
      (should (= (point) (point-min)))
      (should-error (ebox-next-interaction 1.5) :type 'wrong-type-argument))))

(ert-deftest ebox-interaction-navigation-uses-live-mount-and-declared-maps ()
  "Buffer keymaps, copied rendering and empty or blocked maps are not stops."
  (with-temp-buffer
    (insert (ebox-render (ebox-build '(text :keymap (keymap (13 . ignore)) "copy"))))
    (should-error (ebox-next-interaction) :type 'user-error))
  (with-temp-buffer
    (use-local-map (let ((map (make-sparse-keymap)))
                     (define-key map (kbd "RET") #'ignore) map))
    (ebox-render-to-buffer
     (current-buffer)
     (ebox-build '(column (text "intro")
                         (text :keymap (keymap) "empty")
                         (text :keymap (keymap (13 . undefined)) "disabled")
                         (box :visibility hidden :keymap (keymap (13 . ignore)) "hidden")
                         (box :height (lh 0) :overflow hidden
                              :keymap (keymap (13 . ignore)) "clipped")
                         (text :keymap (keymap (13 . ignore)) "active"))))
    (let* ((text (buffer-string))
           (active (1+ (ebox-interaction-test--position text "active"))))
      (goto-char (point-min))
      (should (= (ebox-next-interaction) active))
      (should-error (ebox-next-interaction) :type 'user-error)
      (should-error (ebox-previous-interaction) :type 'user-error))))

(ert-deftest ebox-interaction-navigation-narrowing-and-invisible-text ()
  "Only accessible visible characters contribute a stop, without widening."
  (with-temp-buffer
    (ebox-render-to-buffer
     (current-buffer)
     (ebox-build '(column (text :keymap (keymap (13 . ignore)) "first")
                         (text :keymap (keymap (13 . forward-char)) "second")
                         (text :keymap (keymap (13 . backward-char)) "third"))))
    (let* ((text (buffer-string))
           (first (1+ (ebox-interaction-test--position text "first")))
           (second (1+ (ebox-interaction-test--position text "second")))
           (third (1+ (ebox-interaction-test--position text "third"))))
      (save-restriction
        (narrow-to-region (+ first 2) third)
        (goto-char (point-max))
        (should (= (ebox-previous-interaction) second))
        (should (= (ebox-previous-interaction) (point-min)))
        (should-error (ebox-previous-interaction) :type 'user-error)
        (should (= (point-min) (+ first 2))))
      (let ((overlay (make-overlay second (+ second 6))))
        (unwind-protect
            (progn
              (overlay-put overlay 'invisible t)
              (goto-char first)
              (should (= (ebox-next-interaction) third))
              (move-overlay overlay second (+ second 2))
              (goto-char first)
              (should (= (ebox-next-interaction) (+ second 2))))
          (delete-overlay overlay))))))

(ert-deftest ebox-interaction-navigation-padding-and-native-overrides ()
  "Nested padding resolves to its own box; foreign maps do not create stops."
  (with-temp-buffer
    (ebox-render-to-buffer
     (current-buffer)
     (ebox-build '(column (text "intro")
                         (row :keymap (keymap (13 . ignore))
                              (box :padding-left (ch 2)
                                   :keymap (keymap (13 . forward-char)) "child")
                              (text "parent"))
                         (text "ordinary"))))
    (let* ((text (buffer-string))
           (child (1+ (ebox-interaction-test--position text "child")))
           (parent (1+ (ebox-interaction-test--position text "parent")))
           (ordinary (1+ (ebox-interaction-test--position text "ordinary"))))
      (goto-char (point-min))
      (let ((padding (ebox-next-interaction)))
        (should (< padding child))
        (should (eq (key-binding (kbd "RET")) #'forward-char))
        (should (= (ebox-next-interaction) parent)))
      (let ((inhibit-read-only t))
        (put-text-property ordinary (+ ordinary 8) 'keymap '(keymap (13 . ignore))))
      (should-error (ebox-next-interaction) :type 'user-error)
      (let ((overlay (make-overlay ordinary (+ ordinary 8))))
        (unwind-protect
            (progn
              (overlay-put overlay 'keymap '(keymap (13 . forward-char)))
              (should-error (ebox-next-interaction) :type 'user-error))
          (delete-overlay overlay))))))

(ert-deftest ebox-interaction-navigation-follows-updates-and-scroll ()
  "Updated, removed and newly visible actions are read from the publication."
  (with-temp-buffer
    (ebox-render-to-buffer
     (current-buffer)
     (ebox-build '(column
                  (text "intro")
                  (text :id "first" :keymap (keymap (13 . ignore)) "first")
                  (box :id "scroll" :height (lh 1) :width (ch 20) :overflow scroll
                       (column
                        (text :keymap (keymap (13 . forward-char)) "second")
                        (text :keymap (keymap (13 . backward-char)) "third"))))))
    (goto-char (point-min))
    (ebox-next-interaction)
    (should (looking-at "first"))
    (ebox-region-update (ebox-region-resolve (current-buffer) "first") :keymap nil)
    (goto-char (point-min))
    (ebox-next-interaction)
    (should (looking-at "second"))
    (ebox-region-update (ebox-region-resolve (current-buffer) "scroll") :scroll-offset 1)
    (goto-char (point-min))
    (ebox-next-interaction)
    (should (looking-at "third"))
    (ebox-region-update (ebox-region-resolve (current-buffer) "first")
                        :keymap '(keymap (13 . ignore)) :content "restored")
    (goto-char (point-min))
    (ebox-next-interaction)
    (should (looking-at "restored"))
    (should-error
     (ebox-commit (current-buffer) (ebox-build '(text "rejected"))
                  (lambda (_report) (error "Reject navigation change"))))
    (goto-char (point-min))
    (ebox-next-interaction)
    (should (looking-at "restored"))
    (ebox-commit (current-buffer) (ebox-build '(text "no interactions")))
    (should-error (ebox-next-interaction) :type 'user-error)))

(ert-deftest ebox-activate-uses-live-node-ownership ()
  "Activation respects nested native maps and explicit nil without moving point."
  (let (events)
    (with-temp-buffer
      (ebox-render-to-buffer
       (current-buffer)
       (ebox-build
        (list 'column :keymap (ebox-keymap-create :activate (lambda () (push 'parent events) 'parent-result))
              '(text "Parent")
              (list 'text :keymap (ebox-keymap-create :activate (lambda () (push 'child events) 'child-result)) "Child")
              '(text :keymap nil "Blocked"))))
      (goto-char (point-max))
      (let ((origin (point)) (window (selected-window)))
        (dolist (case '(("Parent" parent-result) ("Child" child-result)))
          (let ((position (+ (point-min) (string-match (car case) (buffer-string)))))
            (should (eq (cadr case) (ebox-activate position)))))
        (should (= origin (point)))
        (should (eq window (selected-window))))
      (should (equal events '(child parent)))
      (let ((position (+ (point-min) (string-match "Blocked" (buffer-string)))))
        (should-error (ebox-activate position) :type 'user-error))
      (should (equal events '(child parent))))))

(ert-deftest ebox-activate-resolves-layout-filler-keymaps ()
  "Filler cells activate the node that declared their keymap.
A flex gap or a clipped surface's trailing cell can carry a node's keymap
while its region belongs to an ancestor, so region ownership alone cannot
name the owner."
  (let (events)
    (with-temp-buffer
      (ebox-render-to-buffer
       (current-buffer)
       (ebox-build
        (list 'column
              (list 'flex
                    :keymap (ebox-keymap-create
                             :activate (lambda () (push 'flex events) 'flex-result))
                    (list 'box :width '(ch 3) :height '(lh 1) (list 'text "A"))
                    (list 'box :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 0)
                          :height '(lh 1) :overflow 'hidden (list 'text "label")))
              (list 'box
                    :keymap (ebox-keymap-create
                             :activate (lambda () (push 'clipped events) 'clipped-result))
                    :height '(lh 1) :width '(ch 20) :overflow 'scroll
                    (list 'column (list 'text "row"))))))
      (goto-char (point-min))
      (search-forward "A")
      (should (eq 'flex-result (ebox-activate (point))))
      (goto-char (point-min))
      (search-forward "row")
      (should (eq 'clipped-result (ebox-activate (point))))
      (should (equal events '(clipped flex))))))

(ert-deftest ebox-press-without-live-owner-is-unclaimed ()
  "A press whose keymap names no live owner does not fail its command.
Foreign maps can reach the text surface; Ebox leaves such a press and its
release to Emacs instead of signalling that no drag target exists."
  (let ((target (generate-new-buffer " *ebox-unowned-target*"))
        (calls 0))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (let* ((window (selected-window))
                 (map (ebox-keymap-create :activate (lambda () (cl-incf calls)))))
            (ebox-render-to-buffer target (ebox-build '(column (text "ordinary text"))))
            (set-window-buffer window target)
            (with-current-buffer target
              (setq buffer-read-only t)
              (let ((inhibit-read-only t))
                (put-text-property (point-min) (1+ (point-min)) 'keymap map)))
            (cl-letf (((symbol-function 'read-event)
                       (lambda (&rest _)
                         (should (= calls 0))
                         (list 'mouse-1 (list window 1 '(1 . 1) 0)))))
              (ebox-interaction-test--dispatch-mouse 'down-mouse-1 window 1))
            (should (= calls 0))))
      (kill-buffer target))))

(ert-deftest ebox-activate-follows-publication-and-unmount ()
  "Replaced and rejected callbacks follow the committed surface, then disappear on unmount."
  (with-temp-buffer
    (let ((value nil))
      (cl-labels ((input (next)
                    (ebox-build (list 'text :keymap
                                      (ebox-keymap-create :activate (lambda () (setq value next)))
                                      "Action"))))
        (ebox-render-to-buffer (current-buffer) (input 'first))
        (ebox-activate (point-min))
        (should (eq value 'first))
        (ebox-commit (current-buffer) (input 'second))
        (should-error (ebox-commit (current-buffer) (input 'rejected)
                                  (lambda (_report) (error "Reject activation candidate"))))
        (ebox-activate (point-min))
        (should (eq value 'second))
        (ebox-unmount-buffer (current-buffer))
        (should-error (ebox-activate (point-min)) :type 'user-error)))))

(ert-deftest ebox-activate-rejects-unowned-and-inaccessible-positions ()
  "Global and overlay maps, line breaks, foreign markers and narrowing create no target."
  (with-temp-buffer
    (should-error (ebox-activate) :type 'user-error)
    (should-not (ebox-activate nil t))
    (let ((map (ebox-keymap-create :activate (lambda () (ert-fail "Unowned callback")))))
      (ebox-render-to-buffer (current-buffer) (ebox-build '(column (text "One") (text "Two"))))
      (use-local-map map)
      (let ((overlay (make-overlay (point-min) (point-max))))
        (unwind-protect
            (progn (overlay-put overlay 'keymap map)
                   (should-error (ebox-activate (point-min)) :type 'user-error))
          (delete-overlay overlay))))
    (ebox-commit (current-buffer)
                 (ebox-build (list 'column :keymap (ebox-keymap-create :activate (lambda () 'ok))
                                   '(text "One") '(text "Two"))))
    (should-error (ebox-activate (point-max)) :type 'user-error)
    (let ((newline (save-excursion (goto-char (point-min)) (search-forward "\n") (1- (point)))))
      (should-error (ebox-activate newline) :type 'user-error))
    (let ((outside (copy-marker (point-min))))
      (unwind-protect
          (save-restriction
            (narrow-to-region (1+ (point-min)) (point-max))
            (should-error (ebox-activate outside) :type 'user-error))
        (set-marker outside nil)))
    (let ((foreign (with-temp-buffer (point-marker))))
      (should-error (ebox-activate foreign) :type 'user-error))
    (ebox-commit (current-buffer)
                 (ebox-build (list 'text :keymap
                                   (ebox-keymap-create :activate (lambda () (user-error "Callback failed")))
                                   "Failure")))
    (should-error (ebox-activate (point-min) t) :type 'user-error)))

(ert-deftest ebox-interaction-hover-content-uses-retained-updates ()
  "Hover content swaps through Ebox updates and restores on pointer leave.
The surface uses local mouse tracking only for a node declaring the capability;
it does not create an overlay or enter the primary-button drag loop."
  (let ((buffer (generate-new-buffer " *ebox-hover-content*")))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (let ((window (selected-window)))
            (ebox-render-to-buffer
             buffer (ebox-build
                     '(text :id "control" :hover-content "×" "●")))
            (set-window-buffer window buffer)
            (with-current-buffer buffer
              (should (eq track-mouse t))
              (let ((command (lookup-key ebox-buffer-mode-map [mouse-movement])))
                (should (commandp command))
                (funcall command
                         (list 'mouse-movement
                               (list window (point-min) '(1 . 1) 0)))
                (should (equal "×" (substring-no-properties (buffer-string))))
                (funcall command
                         (list 'mouse-movement
                               (list window (point-max) '(50 . 50) 0)))
                (should (equal "●" (substring-no-properties (buffer-string))))))))
      (when (buffer-live-p buffer)
        (ebox-unmount-buffer buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-interaction-hover-content-group-updates-siblings-in-one-transition ()
  "Entering one grouped hover target updates and restores all group members."
  (let ((buffer (generate-new-buffer " *ebox-hover-content-group*")))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (let ((window (selected-window)))
            (ebox-render-to-buffer
             buffer
             (ebox-build
              '(row
                (text :id "close" :hover-group traffic
                      :hover-content "×" "⬤")
                (text :id "min" :hover-group traffic
                      :hover-content "−" "⬤")
                (text :id "max" :hover-group traffic
                      :hover-content "+" "⬤"))))
            (set-window-buffer window buffer)
            (with-current-buffer buffer
              (let ((command (lookup-key ebox-buffer-mode-map [mouse-movement])))
                (funcall command
                         (list 'mouse-movement
                               (list window (point-min) '(1 . 1) 0)))
                (should (equal "×−+" (substring-no-properties (buffer-string))))
                (funcall command
                         (list 'mouse-movement
                               (list window (point-max) '(50 . 50) 0)))
                (should (equal "⬤⬤⬤" (substring-no-properties (buffer-string))))))))
      (when (buffer-live-p buffer)
        (ebox-unmount-buffer buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-interaction-hover-content-follows-retained-geometry ()
  "A retained geometry update refreshes hover bounds without any input.

A desktop that tiles windows moves hover targets by updating geometry, so a
hover target must be discoverable at its committed position before the user
touches the buffer again."
  (let ((buffer (generate-new-buffer " *ebox-hover-geometry*")))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (let ((window (selected-window)))
            (ebox-render-to-buffer
             buffer
             (ebox-build
              '(column
                (text :id "prefix" "ab")
                (text :id "control" :hover-content "×" "●"))))
            (set-window-buffer window buffer)
            (with-current-buffer buffer
              (ebox-region-update "prefix" :content "abcd")
              (let* ((position (save-excursion
                                 (goto-char (point-min))
                                 (search-forward "●")
                                 (match-beginning 0)))
                     (command (lookup-key ebox-buffer-mode-map [mouse-movement])))
                (should (commandp command))
                (funcall command
                         (list 'mouse-movement
                               (list window position '(1 . 1) 0)))
                (should (equal "abcd\n× " (substring-no-properties (buffer-string))))))))
      (when (buffer-live-p buffer)
        (ebox-unmount-buffer buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-interaction-prepared-geometry-updates-hover-bounds ()
  "Prepared movement discovers hover controls at their new or newly revealed positions."
  (dolist (covered '(nil t))
    (let ((buffer (generate-new-buffer " *ebox-prepared-hover*")))
      (unwind-protect
          (save-window-excursion
            (let ((window (selected-window)))
              (set-window-buffer window buffer)
              (ebox-render-to-buffer
               buffer
               (ebox-build
                `(box :width (px 80) :height (lh 8)
                      (box :id "moving" :position absolute :left (px 2) :top (lh 1)
                           :width (px 20) :height (lh 2) :z-index 2
                           ,(if covered "Cover" '(text :id "control" :hover-content "×" "●")))
                      ,@(when covered
                          '((box :id "lower" :position absolute :left (px 2) :top (lh 1)
                                 :width (px 20) :height (lh 2) :z-index 1
                                 (text :id "control" :hover-content "×" "●")))))))
              (with-current-buffer buffer
                (when covered (should-not (string-match-p "●" (buffer-string))))
                (let* ((reject t)
                       (before (buffer-string))
                       (operation (ebox-geometry-prepare
                                   buffer "moving" [:left :top :z-index]
                                   (lambda () (when reject (error "Reject hover relocation"))) #'ignore)))
                  (should operation)
                  (should-error (ebox-geometry-apply operation [(px 30) (lh 3) 2]))
                  (should (equal-including-properties before (buffer-string)))
                  (setq reject nil)
                  (should (ebox-geometry-apply operation [(px 30) (lh 3) 2])))
                (let* ((position (save-excursion (goto-char (point-min))
                                                 (search-forward "●") (match-beginning 0)))
                       (command (lookup-key ebox-buffer-mode-map [mouse-movement])))
                  (should (eq track-mouse t))
                  (funcall command (list 'mouse-movement (list window position '(1 . 1) 0)))
                  (should (string-match-p "×" (buffer-string)))
                  (should-not (string-match-p "●" (buffer-string)))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest ebox-interaction-prepared-occlusion-declines-changing-focus-style ()
  "Visible focused translation stays prepared; style-changing occlusion declines untouched."
  (with-temp-buffer
    (ebox-render-to-buffer
     (current-buffer)
     (ebox-build
      '(box :width (px 80) :height (lh 8)
            :ecss (("#moving:focus" :color "#ff0000"))
            (box :id "moving" :tab-index 0 :position absolute
                 :left (px 2) :top (lh 1) :width (px 20) :height (lh 2)
                 :z-index 2 "Moving")
            (box :id "peer" :position absolute
                 :left (px 2) :top (lh 1) :width (px 20) :height (lh 2)
                 :z-index 1 "Peer"))))
    (ebox-focus-first)
    (let ((operation (ebox-geometry-prepare (current-buffer) "moving" [:left :top :z-index])))
      (should operation)
      (should (ebox-geometry-apply operation [(px 30) (lh 3) 2]))
      (let ((before (buffer-string))
            (point-before (point))
            (revision (ebox-surface-buffer-revision (current-buffer)))
            (focused (ebox-focused-host-ref)))
        (should-not (ebox-geometry-apply operation [(px 2) (lh 1) 0]))
        (should (equal-including-properties before (buffer-string)))
        (should (= point-before (point)))
        (should (= revision (ebox-surface-buffer-revision (current-buffer))))
        (should (equal focused (ebox-focused-host-ref)))
        (should (= 1 (length (ebox-selector-query-buffer (current-buffer) "#moving:focus"))))))))

(provide 'ebox-interaction-tests)
;;; ebox-interaction-tests.el ends here
