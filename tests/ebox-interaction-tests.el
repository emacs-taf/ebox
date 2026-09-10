;;; ebox-interaction-tests.el --- Native node interaction tests -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'ebox)
(require 'ebox-native-reflow)

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

(ert-deftest ebox-interaction-surface-compares-owned-keymap-bindings ()
  "Copied maps do not turn paint changes into interaction changes."
  (let* ((command (let ((value 1)) (lambda () (interactive) value)))
         (other (let ((value 1)) (lambda () (interactive) value)))
         (map (make-sparse-keymap "Actions"))
         (parent (make-sparse-keymap)))
    (define-key map (kbd "RET") command)
    (define-key parent (kbd "p") #'ignore)
    (set-keymap-parent map parent)
    (let ((copy (ebox-interaction--keymap-snapshot map)))
      (should-not (eq map copy))
      (should (ebox-interaction-surface-equal-p
               (list 'keymap map 'help-echo command)
               (list 'help-echo command 'keymap copy)))
      (should-not (ebox-interaction-surface-equal-p
                   (list 'help-echo command) (list 'help-echo other)))
      (define-key copy (kbd "RET") other)
      (should-not (ebox-interaction-surface-equal-p
                   (list 'keymap map) (list 'keymap copy))))))

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

(ert-deftest ebox-interaction-native-templates-reuse-owned-keymaps ()
  "Template registration preserves the identity of already owned native maps."
  (let* ((map (ebox-interaction--keymap-snapshot (make-sparse-keymap)))
         (ebox-native-reflow--compile-property-templates nil)
         (ebox-native-reflow--compile-property-template-base-count 0)
         (ebox-native-reflow--compile-retained-registry-p nil)
         (ebox-native-reflow--compile-property-template-ids
          (make-hash-table :test 'ebox-native-property-template)))
    (dotimes (_ 2)
      (should (= (ebox-native-reflow--register-property-template
                  (list 'keymap map) "surface") 0)))
    (should (eq (plist-get (plist-get
                            (car ebox-native-reflow--compile-property-templates)
                            :properties) 'keymap)
                map))
    (let ((ebox-native-reflow--compile-property-template-index
           (ebox-native-reflow--persistent-index-from-sequence
            ebox-native-reflow--compile-property-templates t))
          (ebox-native-reflow--compile-property-template-base-count 1)
          (ebox-native-reflow--compile-property-templates nil)
          (ebox-native-reflow--compile-retained-registry-p t))
      (should (= (ebox-native-reflow--register-property-template
                  (list 'keymap map) "surface") 0)))))

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

(ert-deftest ebox-interaction-direct-text-content-update-retains-node-facts ()
  "Named Text content supports replacement, no-op, batching and native facts."
  (dolist (nested '(nil t))
    (let ((buffer (generate-new-buffer " *ebox-direct-text-content*"))
          (form '(text :id "direct" :help-echo "before" :pointer hand
                       :hover-style (:background-color "blue")
                       :keymap (keymap (13 . ignore)) "old")))
      (unwind-protect
          (progn
            (ebox-render-to-buffer
             buffer (ebox-build (if nested (list 'row form '(text "sibling")) form)))
            (with-current-buffer buffer
              (let* ((handle (ebox-region-resolve buffer "direct"))
                     (region-id (cdr (ebox-selector--region-target handle)))
                     (old (ebox--root-region-box
                           (ebox--buffer-root-node buffer) region-id)))
                (should (ebox-text-node-p old))
                (ebox-region-update "direct" :content "new")
                (should (string-prefix-p "new" (buffer-string)))
                (should (equal (get-text-property (point-min) 'help-echo) "before"))
                (let* ((surface (plist-get (ebox--buffer-render-state buffer) :surface))
                       (revision (tp-surface-revision surface))
                       (report (ebox-region-update handle :content "new")))
                  (should (eq (plist-get report :strategy) 'no-op))
                  (should (= (tp-surface-revision surface) revision)))
                (ebox-region-update handle :help-echo "after" :pointer 'text
                                    :keymap '(keymap (13 . forward-char)))
                (ebox-region-update handle :content "latest")
                (should (string-prefix-p "latest" (buffer-string)))
                (ebox-incremental-begin-batch buffer)
                (ebox-region-update handle :content "batch-first")
                (ebox-region-update handle :pointer 'hand)
                (ebox-region-update handle :content "batch-final")
                (ebox-incremental-flush buffer)
                (should (string-prefix-p "batch-final" (buffer-string)))
                (when nested (should (string-suffix-p "sibling" (buffer-string))))
                (should (eq (get-text-property (point-min) 'pointer) 'hand))
                (should (equal (get-text-property (point-min) 'help-echo) "after"))
                (should (eq (lookup-key (get-text-property (point-min) 'keymap)
                                        (kbd "RET")) #'forward-char))
                (let ((current (ebox--root-region-box
                                (ebox--buffer-root-node buffer) region-id)))
                  (should (ebox-text-node-p current))
                  (should (equal (ebox-text-node-value current) "batch-final"))
                  (should (equal (plist-get current :content) "batch-final")))
                (should (equal (ebox-text-node-value old) "old"))
                (should-error (ebox-region-update handle :content nil)
                              :type 'user-error)
                (should (string-prefix-p "batch-final" (buffer-string))))))
        (kill-buffer buffer)))))

(ert-deftest ebox-interaction-stateful-callbacks-keep-distinct-identities ()
  "Equal-shaped closures remain distinct during updates and native interning."
  (let* ((factory (eval '(lambda ()
                          (let ((n 0))
                            (lambda (_window _object _position)
                              (setq n (1+ n))))) t))
         (first (funcall factory)) (second (funcall factory))
         (buffer (generate-new-buffer " *ebox-callback-identity*")))
    (should-not (eq first second))
    (should (equal first second))
    (unwind-protect
        (progn
          (ebox-render-to-buffer
           buffer (ebox-build (list 'text :id t :help-echo first "text")))
          (ebox-region-update (ebox-region-resolve buffer t) :help-echo second)
          (with-current-buffer buffer
            (should (eq (get-text-property (point-min) 'help-echo) second)))
          (dolist (hashed '(nil t))
            (let ((ebox-native-reflow--compile-property-templates nil)
                  (ebox-native-reflow--compile-property-template-base-count 0)
                  (ebox-native-reflow--compile-retained-registry-p nil)
                  (ebox-native-reflow--compile-property-template-ids
                   (and hashed (make-hash-table :test 'equal))))
              (should (= (ebox-native-reflow--register-property-template
                          (list 'help-echo first) "surface") 0))
              (should (= (ebox-native-reflow--register-property-template
                          (list 'help-echo second) "surface") 1))
              (funcall first nil nil nil)
              (should (= (ebox-native-reflow--register-property-template
                          (list 'help-echo first) "surface") 0))
              (let ((ebox-native-reflow--compile-property-template-index
                     (ebox-native-reflow--persistent-index-from-sequence
                      ebox-native-reflow--compile-property-templates t))
                    (ebox-native-reflow--compile-property-template-base-count 2)
                    (ebox-native-reflow--compile-property-templates nil)
                    (ebox-native-reflow--compile-retained-registry-p t))
                (should (= (ebox-native-reflow--register-property-template
                            (list 'help-echo first) "surface") 0))
                (should (= (ebox-native-reflow--register-property-template
                            (list 'help-echo second) "surface") 1))))))
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
                     (:activate ignore :bindings (("RET" . ignore)))
                     (:activate ignore :bindings (([mouse-1] . ignore)))))
    (should-error (apply #'ebox-keymap-create options))))

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
                      (ebox-interaction-test--dispatch-mouse (car events) window 1)
                      (should (= calls before))
                      (ebox-interaction-test--dispatch-mouse (cadr events) window 1)
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
  (dolist (props '((:help-echo 1) (:pointer invalid) (:keymap (bogus))
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

(defun ebox-interaction-test--hover-input ()
  "Return a nested hover sample with distinct paint and every border role."
  (ebox-build
   '(box :id "frame" :width (ch 30) :padding ((lh 1) (ch 1))
         :margin ((lh 1) (ch 1)) :color "#273B42"
         :background-color "#F8EDDC"
         :border-width (px 1) :border-style solid :border-color "#804020"
         :hover-style (:background-color "#F6D6AB" :text-decoration-line none)
         :help-echo "frame" :keymap (keymap (13 . ignore))
         (row (text "base") (text :color "#123456" "child")
              (text :hover-style nil "blocked")))))

(defun ebox-interaction-test--assert-hover-paint (text foreground)
  "Assert one owner's hover paint in TEXT retains FOREGROUND and box chrome."
  (let ((base (ebox-interaction-test--position text "base"))
        (child (ebox-interaction-test--position text "child"))
        (blocked (ebox-interaction-test--position text "blocked"))
        (sides 0) (corners 0) (padding 0))
    (should (equal (ebox-interaction--face-attribute
                    (get-text-property base 'mouse-face text) :foreground)
                   (list :foreground foreground)))
    (should (equal (ebox-interaction--face-attribute
                    (get-text-property child 'mouse-face text) :foreground)
                   (list :foreground foreground)))
    (should (eq (get-text-property base 'mouse-face text)
                (get-text-property child 'mouse-face text)))
    (should (equal (ebox-interaction--face-attribute
                    (get-text-property child 'face text) :foreground)
                   '(:foreground "#123456")))
    (should-not (get-text-property blocked 'mouse-face text))
    (dotimes (position (length text))
      (let* ((normal (get-text-property position 'face text))
             (hover (get-text-property position 'mouse-face text))
             (side (or (get-text-property position 'ebox-bl text)
                       (get-text-property position 'ebox-br text)))
             (top (get-text-property position 'ebox-bt text))
             (bottom (get-text-property position 'ebox-bb text)))
        (when side
          (cl-incf sides)
          (when (or top bottom) (cl-incf corners))
          (should-not hover)
          (should (equal (ebox-interaction--face-attribute normal :background)
                         '(:background "#804020")))
          (should (keymapp (get-text-property position 'keymap text)))
          (should (equal (get-text-property position 'help-echo text) "frame")))
        (when hover
          (dolist (entry (list (cons top :overline) (cons bottom :underline)))
            (when (car entry)
              (should (equal (ebox-interaction--face-attribute hover (cdr entry))
                             (ebox-interaction--face-attribute normal (cdr entry))))))
          (when (and (not side)
                     (cl-some (lambda (property)
                                (get-text-property position property text))
                              '(ebox-pl ebox-pr ebox-pt ebox-pb)))
            (cl-incf padding)
            (should (equal (ebox-interaction--face-attribute hover :background)
                           '(:background "#F6D6AB")))))))
    (should (> sides 0))
    (should (> corners 0))
    (should (> padding 0))))

(ert-deftest ebox-interaction-hover-preserves-base-paint-and-borders ()
  "Shared native hover uses its owner's paint and keeps every border."
  (let ((text (ebox-render
               (ebox-build
                (list 'box :hover-style '(:background-color "blue")
                      (list 'text (propertize "native" 'mouse-face 'highlight)))))))
    (should (eq (get-text-property 0 'mouse-face text) 'highlight))
    (should-not (get-text-property 0 'ebox--hover-style text)))
  (let ((input (ebox-interaction-test--hover-input))
        (buffer (generate-new-buffer " *ebox-hover-paint*")))
    (unwind-protect
        (progn
          (ebox-interaction-test--assert-hover-paint (ebox-render input) "#273B42")
          (ebox-render-to-buffer buffer input)
          (with-current-buffer buffer
            (ebox-interaction-test--assert-hover-paint (buffer-string) "#273B42")
            (ebox-region-update "frame" :color "#445566")
            (ebox-interaction-test--assert-hover-paint (buffer-string) "#445566")
            (ebox-region-update "frame" :hover-style nil)
            (should-not (text-property-not-all (point-min) (point-max)
                                              'mouse-face nil))))
      (kill-buffer buffer))))

(ert-deftest ebox-interaction-native-hover-preserves-base-paint-and-borders ()
  "The native template projection retains the same owner hover appearance."
  (skip-unless (ebox-native-reflow-layout-ready-p))
  (let ((buffer (generate-new-buffer " *ebox-native-hover*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer buffer (ebox-interaction-test--hover-input))
          (let ((node (plist-get (ebox--buffer-render-state buffer) :root-node)))
            (dolist (width '(100 160))
              (let ((frame (ebox-native-reflow-execute-sync
                            node (list :key width :viewport-width width
                                       :viewport-height 30 :root-width width
                                       :runtime-revision 0 :context-hash 0
                                       :complete t))))
                (should (plist-get frame :native-frame))
                (ebox-interaction-test--assert-hover-paint
                 (plist-get frame :rendered) "#273B42")))))
      (kill-buffer buffer))))

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

(ert-deftest ebox-interaction-hover-is-one-native-row-group ()
  "Text and both paddings share identity through snapshots and retained paint."
  (let* ((input (ebox-build
                 '(box :id "action" :width (ch 24)
                       :padding ((lh 1) (ch 2)) :color "#123456"
                       :background-color "#EEEEEE"
                       :border-width (px 1) :border-style solid
                       :border-color "#804020"
                       :hover-style (:background-color "#ACDCEC") "action")))
         (buffer (generate-new-buffer " *ebox-one-hover-row*")))
    (unwind-protect
        (progn
          (let ((rendered (ebox-render input)))
            (ebox-interaction-test--assert-hover-row rendered)
            (ebox-interaction-test--assert-hover-row (tp-text-snapshot rendered)))
          (ebox-render-to-buffer buffer input)
          (with-current-buffer buffer
            (ebox-interaction-test--assert-hover-row (buffer-string))
            (ebox-region-update "action" :color "#654321")
            (ebox-interaction-test--assert-hover-row (buffer-string))
            (ebox-region-update "action" :content "action again")
            (ebox-interaction-test--assert-hover-row (buffer-string))
            (ebox-region-update "action" :background-color "#DDDDDD")
            (ebox-interaction-test--assert-hover-row (buffer-string))
            (ebox-region-update "action" :hover-style '(:background-color "#CDEECC"))
            (ebox-interaction-test--assert-hover-row (buffer-string)))
          (when (ebox-native-reflow-layout-ready-p)
            (let ((node (plist-get (ebox--buffer-render-state buffer) :root-node)))
              (dolist (width '(100 160))
                (let ((frame (ebox-native-reflow-execute-sync
                              node (list :key width :viewport-width width
                                         :viewport-height 30 :root-width width
                                         :runtime-revision 0 :context-hash 0
                                         :complete t))))
                  (should (plist-get frame :native-frame))
                  (ebox-interaction-test--assert-hover-row
                   (plist-get frame :rendered)))))))
      (kill-buffer buffer))))

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

(defun ebox-interaction-test--cached-hover-sample (owner)
  "Return a projected hover string owned by OWNER for cache lifecycle tests."
  (let ((text (propertize
               (copy-sequence "hover") 'ebox--hover-style
               (list :owner owner :face (list :background "#ACDCEC")
                     :base (list :foreground "#123456")))))
    (ebox-interaction--refresh-hover! text 0 (length text))))

(defun ebox-interaction-test--populate-discarded-hover-faces ()
  "Populate transient hover faces without retaining the resulting strings."
  (dotimes (owner 16)
    (ebox-interaction-test--cached-hover-sample owner)))

(defun ebox-interaction-test--live-hover-cache-cycle ()
  "Return cache counts and identity proof from a temporary live buffer.
The helper keeps face objects out of the caller's ERT assertion temporaries."
  (with-temp-buffer
    (insert (ebox-interaction-test--cached-hover-sample 100))
    (ebox-interaction-test--populate-discarded-hover-faces)
    (let ((before (hash-table-count ebox-interaction--hover-face-cache)))
      (garbage-collect)
      (list before (hash-table-count ebox-interaction--hover-face-cache)
            (eq (get-text-property (point-min) 'mouse-face)
                (get-text-property
                 0 'mouse-face
                 (ebox-interaction-test--cached-hover-sample 100)))))))

(ert-deftest ebox-interaction-hover-cache-releases-unreferenced-faces ()
  "GC releases retired faces while a live buffer keeps its shared hover identity."
  (let ((ebox-interaction--hover-face-cache
         (make-hash-table :test #'equal :weakness 'value)))
    (should (equal (ebox-interaction-test--live-hover-cache-cycle) '(17 1 t)))
    (garbage-collect)
    (should (zerop (hash-table-count ebox-interaction--hover-face-cache)))))

(ert-deftest ebox-interaction-partial-hover-decoration-composes-with-base ()
  "Color and style overrides retain the other decoration components per run."
  (let* ((input
          (ebox-build
           '(box (text :id "decoration" :color "#123456"
                       :text-decoration-line (underline overline)
                       :text-decoration-color "red" :text-decoration-style dashed
                       "sample"))))
         (buffer (generate-new-buffer " *ebox-hover-decoration*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer buffer input)
          (dolist (case '(((:text-decoration-color "blue")
                          (:color "blue" :style dashes) "blue")
                         ((:text-decoration-style wavy)
                          (:color "red" :style wave) "red")
                         ((:text-decoration-color currentColor)
                          (:style dashes) t)
                         ((:text-decoration-line underline)
                          (:color "red" :style dashes) nil)
                         ((:text-decoration-line none) nil nil)))
            (with-current-buffer buffer
              (ebox-region-update "decoration" :hover-style (car case)))
            (let* ((node (plist-get (ebox--buffer-render-state buffer) :root-node))
                   (strings (list (with-current-buffer buffer (buffer-string)))))
              (when (ebox-native-reflow-layout-ready-p)
                (push (plist-get
                       (ebox-native-reflow-execute-sync
                        node '(:key 1 :viewport-width 80 :viewport-height 20
                               :root-width 80 :runtime-revision 0
                               :context-hash 0 :complete t)) :rendered)
                      strings))
              (dolist (text strings)
                (let ((hover (get-text-property 0 'mouse-face text)))
                  (should (equal (ebox-interaction--face-attribute hover :underline)
                                 (list :underline (nth 1 case))))
                  (should (equal (ebox-interaction--face-attribute hover :overline)
                                 (list :overline (nth 2 case))))
                  (should (equal (ebox-interaction--face-attribute hover :foreground)
                                 '(:foreground "#123456")))))))
          (with-current-buffer buffer
            (ebox-region-update "decoration" :hover-style nil)
            (should-not (get-text-property (point-min) 'mouse-face))))
      (kill-buffer buffer))))

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

(ert-deftest ebox-interaction-native-template-preserves-inner-nil ()
  "Native template expansion shares Elisp presence and newline rules."
  (let* ((text (copy-sequence "child\nouter"))
         (inner '(:kind surface :properties
                        (help-echo nil pointer nil mouse-face nil keymap nil)))
         (outer '(:kind surface :properties
                        (help-echo "outer" pointer hand
                         mouse-face (:foreground "red") keymap (keymap)))))
    (ebox-native-reflow--apply-property-template-span text 0 5 inner)
    (ebox-native-reflow--apply-property-template-span text 0 (length text) outer)
    (dolist (property '(help-echo pointer mouse-face keymap))
      (should-not (get-text-property 0 property text))
      (should-not (get-text-property 5 property text))
      (should (get-text-property 6 property text)))))

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

(ert-deftest ebox-interaction-native-execution-and-resize ()
  "Actual native frames preserve native input scopes at different widths."
  (skip-unless (ebox-native-reflow-layout-ready-p))
  (let* ((input (ebox-build
                 '(box :width (px 60) :padding-inline (px 2)
                       :margin-inline (px 3) :help-echo "outer"
                       :pointer hand :hover-style (:color "red")
                       :keymap (keymap (13 . ignore))
                       (text :help-echo nil :pointer nil :keymap nil
                             :hover-style nil "child"))))
         (node (ebox-canonical-input--single-root input "Native interactions")))
    (dolist (width '(80 120))
      (let* ((frame (ebox-native-reflow-execute-sync
                     node (list :key width :viewport-width width
                                :viewport-height 20 :root-width width
                                :runtime-revision 0 :context-hash 0 :complete t)))
             (text (plist-get frame :rendered))
             (position (ebox-interaction-test--position text "child")))
        (should (plist-get frame :native-frame))
        (dolist (property '(help-echo pointer mouse-face keymap))
          (should-not (get-text-property position property text)))
        (should (cl-loop for index below (length text)
                         thereis (equal (get-text-property index 'help-echo text)
                                        "outer")))
        (dotimes (index (length text))
          (when (or (get-text-property index 'ebox-ml text)
                    (get-text-property index 'ebox-mr text)
                    (= (aref text index) ?\n))
            (should-not (get-text-property index 'help-echo text))))))))

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

(ert-deftest ebox-interaction-source-typed-and-retained-updates ()
  "Typed input ownership, declarative removal and viewport updates stay coherent."
  (let* ((builder (ebox-source-builder-create))
         (interactions '(:help-echo "typed" :pointer hand :keymap (keymap)))
         (handle (ebox-source-builder-bind builder :id "text"
                                           :interactions interactions))
         (node (ebox-text-create
                :source-handle handle :value "typed"
                :owned-facts (ebox-canonical-facts-from-declarations
                              'text nil interactions)))
         (input (ebox-canonical-input-create
                 (list node) (ebox-source-builder-finish builder)))
         (buffer (generate-new-buffer " *ebox-interaction-retained*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer buffer input)
          (ebox-region-update (ebox-region-resolve buffer "text")
                              :help-echo "new" :pointer 'text
                              :keymap '(keymap (13 . forward-char))
                              :hover-style '(:color "red"))
          (ebox-region-update (ebox-region-resolve buffer "text") :color "blue")
          (ebox-rerender-buffer-with-context buffer 120 30)
          (with-current-buffer buffer
            (should (equal (get-text-property (point-min) 'help-echo) "new"))
            (should (eq (get-text-property (point-min) 'pointer) 'text))
            (should (equal (ebox-interaction--face-attribute
                            (get-text-property (point-min) 'mouse-face) :foreground)
                           '(:foreground "red")))
            (should (eq (lookup-key (get-text-property (point-min) 'keymap)
                                   (kbd "RET")) #'forward-char)))
          (ebox-commit buffer (ebox-build '(text :id "text" "typed")))
          (with-current-buffer buffer
            (dolist (property '(help-echo pointer keymap mouse-face))
              (should-not (get-text-property (point-min) property)))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

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

(ert-deftest ebox-interaction-navigation-keymap-prefixes-parents-and-menus ()
  "Inspect native binding graphs without executing dynamic menu predicates."
  (let* ((map (make-sparse-keymap))
         (prefix (make-sparse-keymap))
         (parent (make-sparse-keymap))
         (calls 0))
    (define-key prefix "r" map)
    (define-key map "p" prefix)
    (should-not (ebox-interaction--navigable-keymap-p map))
    (define-key parent (kbd "RET") #'ignore)
    (set-keymap-parent map parent)
    (should (ebox-interaction--navigable-keymap-p map))
    (define-key map (kbd "RET") #'undefined)
    (should-not (ebox-interaction--navigable-keymap-p map))
    (define-key map (kbd "RET") nil)
    (should-not (lookup-key map (kbd "RET")))
    (should-not (ebox-interaction--navigable-keymap-p map))
    (keymap-unset map "RET" t)
    (should (ebox-interaction--navigable-keymap-p map))
    (set-keymap-parent map nil)
    (define-key map [menu-bar item]
      (list 'menu-item "Action" #'ignore
            :enable '(progn (cl-incf calls) nil)
            :filter (lambda (definition) (cl-incf calls) definition)))
    (should (ebox-interaction--navigable-keymap-p map))
    (should (= calls 0)))
  (let ((full (make-keymap)) (parent (make-sparse-keymap)))
    (define-key parent (kbd "RET") #'ignore)
    (set-keymap-parent full parent)
    (set-char-table-range (nth 1 full) t #'undefined)
    (should-not (ebox-interaction--navigable-keymap-p full))
    (define-key full (kbd "RET") nil)
    (should-not (lookup-key full (kbd "RET")))
    (should-not (ebox-interaction--navigable-keymap-p full))
    (define-key full (kbd "RET") #'ignore)
    (should (ebox-interaction--navigable-keymap-p full))))

(ert-deftest ebox-interaction-navigation-inherits-effective-prefix-bindings ()
  "Native prefix inheritance remains navigable without losing child blocking."
  (let ((map (make-sparse-keymap))
        (parent (make-sparse-keymap))
        (prefix (make-sparse-keymap))
        (calls 0))
    (define-key parent "pr" #'ignore)
    (define-key map "p" prefix)
    (set-keymap-parent map parent)
    (should (eq (lookup-key map "pr") #'ignore))
    (should (ebox-interaction--navigable-keymap-p map))
    (with-temp-buffer
      (ebox-render-to-buffer
       (current-buffer)
       (ebox-build (list 'column '(text "intro") (list 'text :keymap map "action"))))
      (goto-char (point-min))
      (ebox-next-interaction)
      (should (looking-at "action"))
      (should (eq (key-binding "pr") #'ignore)))
    (define-key prefix "r" #'undefined)
    (should (eq (lookup-key map "pr") #'undefined))
    (should-not (ebox-interaction--navigable-keymap-p map))
    (keymap-unset prefix "r" t)
    (define-key parent "pr"
      (list 'menu-item "Inherited" #'ignore
            :filter (lambda (definition) (cl-incf calls) definition)))
    (should (ebox-interaction--navigable-keymap-p map))
    (should (= calls 0))
    (should (eq (car (lookup-key parent "p")) 'keymap))
    ;; Inspection must retain the original menu wrapper and callback.
    (should (eq (car (cdr (assq ?r (cdr (lookup-key parent "p"))))) 'menu-item))
    (define-key map "p" #'undefined)
    (should-not (ebox-interaction--navigable-keymap-p map))
    (should (= calls 0))))

(provide 'ebox-interaction-tests)

;;; ebox-interaction-tests.el ends here
