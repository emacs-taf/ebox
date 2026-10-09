;;; ebox-update-tests.el --- Ebox retained update behaviour tests -*- lexical-binding: t; -*-

(require 'ebox-test-support)

(ert-deftest ebox-mount-exposes-root-buffer-and-viewport ()
  (ebox-test-with-mounted (buffer root '(box :width (vw 50) :height (lh 1)))
    (should (eq (ebox-buffer-root buffer) root))
    (should (eq (ebox-node-buffer root) buffer))
    (should (equal (ebox-mount-viewport buffer) '(80 . nil)))
    (should (equal (ebox-node-geometry root) '(:x 0 :y 0 :width 40 :height 1)))
    (ebox-mount-set-viewport buffer 20 5)
    (should (equal (ebox-mount-viewport buffer) '(20 . 5)))
    (should (equal (ebox-node-geometry root) '(:x 0 :y 0 :width 10 :height 1)))
    (should (ebox-test-buffer-matches-render-p root buffer))))

(ert-deftest ebox-viewport-change-hook-reports-settled-size ()
  (ebox-test-with-mounted (buffer root '(box :width (vw 50) :height (lh 1)))
    (let* ((seen nil)
           (hook (lambda (changed)
                   (push (list changed (ebox-mount-viewport changed)
                               (plist-get (ebox-node-geometry root) :width))
                         seen))))
      (add-hook 'ebox-viewport-change-functions hook)
      (unwind-protect
          (progn
            (ebox-mount-set-viewport buffer 20 5)
            (ebox-mount-set-viewport buffer 20 5)
            (should (equal seen (list (list buffer '(20 . 5) 10)))))
        (remove-hook 'ebox-viewport-change-functions hook)))))

(ert-deftest ebox-mount-viewport-follows-displaying-window ()
  (let ((buffer (get-buffer-create " *ebox-viewport-window*"))
        (config (current-window-configuration)))
    (unwind-protect
        (progn
          (set-window-buffer (selected-window) buffer)
          (let ((prospective (ebox-viewport-measure buffer)))
            (should (equal (ebox-viewport-measure buffer 33 7) '(33 . 7)))
            (ebox-mount buffer '(box :height (vh 100) "x"))
            (should (equal (ebox-mount-viewport buffer) prospective)))
          (should (equal (ebox-mount-viewport buffer)
                         (cons (ebox-viewport-window-width (selected-window))
                               (window-body-height (selected-window)))))
          (should (equal (plist-get (ebox-node-geometry (ebox-buffer-root buffer)) :height)
                         (window-body-height (selected-window)))))
      (set-window-configuration config)
      (kill-buffer buffer))))

(ert-deftest ebox-first-content-keeps-point-and-window-start-at-top ()
  (let ((buffer (get-buffer-create " *ebox-first-content*"))
        (config (current-window-configuration)))
    (unwind-protect
        (progn
          (set-window-buffer (selected-window) buffer)
          (let* ((root (ebox-mount buffer '(column :id "list")))
                 (window (selected-window)))
            (should (= (buffer-size buffer) 0))
            (ebox-node-insert root (ebox-build '(column (box "One") (box "Two") (box "Three"))))
            (with-current-buffer buffer
              (should (equal (ebox-test-buffer-text buffer) "One \nTwo \nThree "))
              (should (= (point) (point-min))))
            (should (= (window-point window) 1))
            (should (= (window-start window) 1))))
      (set-window-configuration config)
      (kill-buffer buffer))))

(ert-deftest ebox-refit-returns-a-fitting-tree-to-the-window-top ()
  (let ((buffer (get-buffer-create " *ebox-refit-start*"))
        (config (current-window-configuration)))
    (unwind-protect
        (progn
          (set-window-buffer (selected-window) buffer)
          (ebox-mount buffer '(column (box "One") (box "Two") (box "Three")))
          (let ((window (selected-window)))
            ;; A borrowed, shorter window scrolled the tree; it fits again.
            (set-window-start window (with-current-buffer buffer
                                       (save-excursion (goto-char (point-min))
                                                       (forward-line 1) (point))))
            (ebox-refit buffer)
            (should (= (window-start window) 1))))
      (set-window-configuration config)
      (kill-buffer buffer))))

(ert-deftest ebox-buffer-background-follows-root-background ()
  (let ((buffer (get-buffer-create " *ebox-canvas*")))
    (unwind-protect
        (let ((root (ebox-mount buffer '(column :background-color "#101820" "x"))))
          (with-current-buffer buffer
            (should (equal (cdr (assq 'default face-remapping-alist))
                           '((:background "#101820") default))))
          (ebox-node-put root :background-color "#203040")
          (with-current-buffer buffer
            (should (equal (cdr (assq 'default face-remapping-alist))
                           '((:background "#203040") default))))
          (ebox-unmount-buffer buffer)
          (with-current-buffer buffer
            (should-not (cdr (assq 'default face-remapping-alist)))))
      (kill-buffer buffer))))

(ert-deftest ebox-node-set-text-updates-buffer-like-fresh-render ()
  (ebox-test-with-mounted (buffer root '(column (text :id "value" "One") (box "Tail")))
    (let ((value (car (ebox-selector-query root "#value"))))
      (ebox-node-set-text value "Two")
      (should (equal (ebox-test-buffer-text buffer) "Two 
Tail "))
      (should (ebox-test-buffer-matches-render-p root buffer)))))

(ert-deftest ebox-node-put-and-set-props-restyle-visible-content ()
  (ebox-test-with-mounted (buffer root '(box :id "panel" :width (ch 4) "A"))
    (let ((panel (car (ebox-selector-query root "#panel"))))
      (ebox-node-put panel :color "#123456")
      (should (equal (get-text-property (point-min) 'face)
                     '(:foreground "#123456")))
      (ebox-node-set-props panel '(:id "panel" :width (ch 4) :background-color "#abcdef"))
      (should (equal (get-text-property (point-min) 'face)
                     '(:background "#abcdef")))
      (should (ebox-test-buffer-matches-render-p root buffer)))))

(ert-deftest ebox-parent-restyle-updates-inheriting-descendants ()
  (ebox-test-with-mounted
      (buffer root '(column :id "p" :padding-left (ch 1) :color "#111111"
                            (box :id "a" "A") (box :color "#222222" "B")))
    (let ((p (car (ebox-selector-query root "#p")))
          (a (car (ebox-selector-query root "#a"))))
      (ebox-node-put p :padding-left '(ch 2))
      (should (equal (ebox-node-geometry a) '(:x 2 :y 0 :width 78 :height 1)))
      (should (equal (get-text-property (1+ (point-min)) 'face)
                     '(:foreground "#111111")))
      (ebox-node-put p :color "#333333")
      (should (equal (get-text-property (1+ (point-min)) 'face)
                     '(:foreground "#333333")))
      (should (ebox-test-buffer-matches-render-p root buffer))))
  (ebox-test-with-mounted
      (buffer root `(column :id "p" :padding-left (ch 1)
                            (box :padding-left ,(ecss-wide-value 'inherit)
                                 (box :id "a" "A"))))
    (let ((p (car (ebox-selector-query root "#p")))
          (a (car (ebox-selector-query root "#a"))))
      (should (equal (ebox-node-geometry a) '(:x 2 :y 0 :width 78 :height 1)))
      (ebox-node-put p :padding-left '(ch 3))
      (should (equal (ebox-node-geometry a) '(:x 6 :y 0 :width 74 :height 1)))
      (should (ebox-test-buffer-matches-render-p root buffer)))))

(ert-deftest ebox-scope-root-rule-change-restyles-members ()
  (let* ((old (ebox-style-scope-create '((".accent" :color "#ff0000"))))
         (new (ebox-style-scope-with-rules old '((".accent" :color "#0000ff")))))
    (ebox-test-with-mounted
        (buffer root `(column :id "root" :ecss-scope-roots (,old)
                              (box (box :class "accent" :ecss-scopes (,old) "A"))))
      (should (equal (get-text-property (point-min) 'face) '(:foreground "#ff0000")))
      (ebox-node-put root :ecss-scope-roots (list new))
      (should (equal (get-text-property (point-min) 'face) '(:foreground "#0000ff")))
      (should (ebox-test-buffer-matches-render-p root buffer)))))

(ert-deftest ebox-node-insert-remove-move-and-replace-children-update-order ()
  (ebox-test-with-mounted (buffer root '(column :width (ch 2) (box :id "a" "A") (box :id "b" "B")))
    (let* ((a (car (ebox-selector-query root "#a")))
           (b (car (ebox-selector-query root "#b")))
           (c (ebox-node-create 'box '(:id "c") '("C"))))
      (ebox-node-insert root c 1)
      (should (equal (ebox-test-buffer-text buffer) "A 
C 
B "))
      (ebox-node-move b 0)
      (should (equal (ebox-test-buffer-text buffer) "B 
A 
C "))
      (ebox-node-remove a)
      (should (equal (ebox-test-buffer-text buffer) "B 
C "))
      (ebox-node-replace-children root (list c "D"))
      (should (equal (ebox-test-buffer-text buffer) "C 
D "))
      (should (ebox-test-buffer-matches-render-p root buffer)))))

(ert-deftest ebox-shrunk-flex-item-update-keeps-following-siblings ()
  (ebox-test-with-mounted
      (buffer root '(flex :flex-direction column :height (lh 6)
                          (column :flex-grow 1 :min-height (lh 0)
                                  (column :height (% 100) "x")
                                  (column :id "list" "1" "2" "3" "4" "5" "6" "7"))
                          (box "T") (box "F")))
    (ebox-node-insert (car (ebox-selector-query root "#list")) "8")
    (should (equal (split-string (ebox-test-buffer-text buffer) "\n") '("x " " " " " " " "T " "F ")))
    (should (ebox-test-buffer-matches-render-p root buffer))))

(ert-deftest ebox-with-batch-flushes-mutated-mount-once ()
  (ebox-test-with-mounted (buffer root '(column (text :id "a" "A") (text :id "b" "B")))
    (let ((a (car (ebox-selector-query root "#a")))
          (b (car (ebox-selector-query root "#b")))
          (before (ebox-mount-flush-count buffer)))
      (ebox-with-batch
        (ebox-node-set-text a "AA")
        (ebox-node-set-text b "BB")
        (should (= (ebox-mount-flush-count buffer) before)))
      (should (= (ebox-mount-flush-count buffer) (1+ before)))
      (should (equal (ebox-test-buffer-text buffer) "AA 
BB "))
      (should (ebox-test-buffer-matches-render-p root buffer)))))

(ert-deftest ebox-call-with-batch-returns-body-value ()
  (ebox-test-with-mounted (buffer root '(box (text :id "value" "A")))
    (let ((value (car (ebox-selector-query root "#value"))))
      (should (equal (ebox-call-with-batch
                      (lambda ()
                        (ebox-node-set-text value "B")
                        :done))
                     :done))
      (should (equal (ebox-test-buffer-text buffer) "B ")))))

(ert-deftest ebox-flush-reports-and-observers-describe-public-update ()
  (ebox-test-with-mounted (buffer root '(box (text :id "value" "A")))
    (let ((value (car (ebox-selector-query root "#value")))
          seen)
      (ebox-buffer-set-observer
       buffer (lambda (observed-buffer report)
                (setq seen (list observed-buffer report))))
      (ebox-node-set-text value "B")
      (let ((report (ebox-buffer-update-report buffer)))
        (should (eq (car seen) buffer))
        (should (equal (cadr seen) report))
        (should (eq (plist-get report :provider) 'ebox))
        (should (eq (plist-get report :strategy) 'lines))
        (should (= (plist-get report :edits) 1))
        (should (= (plist-get report :flush) (ebox-mount-flush-count buffer)))))))

(ert-deftest ebox-after-flush-hook-runs-with-updated-buffer ()
  (ebox-test-with-mounted (buffer root '(box (text :id "value" "A")))
    (let ((value (car (ebox-selector-query root "#value")))
          seen)
      (let ((ebox-after-flush-functions
             (list (lambda (flushed-buffer)
                     (setq seen (cons flushed-buffer (ebox-test-buffer-text flushed-buffer)))))))
        (ebox-node-set-text value "B"))
      (should (equal seen (cons buffer "B "))))))

(ert-deftest ebox-unmount-runs-hook-and-releases-mount ()
  (let ((buffer (generate-new-buffer " *ebox-unmount-test*")) seen)
    (unwind-protect
        (progn
          (ebox-mount buffer '(box "A"))
          (let ((ebox-unmount-functions (list (lambda (unmounted) (setq seen unmounted)))))
            (should (ebox-unmount-buffer buffer)))
          (should (eq seen buffer))
          (should-not (ebox-buffer-mount buffer))
          (should (equal (ebox-test-buffer-text buffer) "A ")))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-node-mutation-errors-leave-buffer-at-last-successful-render ()
  (ebox-test-with-mounted (buffer root '(column (box :id "a" "A") (box :id "b" "B")))
    (let ((a (car (ebox-selector-query root "#a")))
          (b (car (ebox-selector-query root "#b"))))
      (should-error (ebox-node-insert a b) :type 'ebox-error)
      (should (equal (ebox-test-buffer-text buffer) "A 
B "))
      (should-error (ebox-node-set-text a "not text") :type 'ebox-error)
      (should (ebox-test-buffer-matches-render-p root buffer)))))

;;; ebox-update-tests.el ends here
