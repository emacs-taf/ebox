;;; ebox-update-tests.el --- Ebox retained update behaviour tests -*- lexical-binding: t; -*-

(require 'ebox-test-support)

(ert-deftest ebox-mount-exposes-root-buffer-and-viewport ()
  (ebox-test-with-mounted (buffer root '(box :width (vw 50) :height (lh 1)))
    (should (eq (ebox-buffer-root buffer) root))
    (should (eq (ebox-node-buffer root) buffer))
    (should (equal (ebox-mount-viewport buffer) '(80 . 24)))
    (should (equal (ebox-node-geometry root) '(:x 0 :y 0 :width 40 :height 1)))
    (ebox-mount-set-viewport buffer 20 5)
    (should (equal (ebox-mount-viewport buffer) '(20 . 5)))
    (should (equal (ebox-node-geometry root) '(:x 0 :y 0 :width 10 :height 1)))
    (should (ebox-test-buffer-matches-render-p root buffer))))

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
