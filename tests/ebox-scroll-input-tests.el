;;; ebox-scroll-input-tests.el --- Ebox scroll and input tests -*- lexical-binding: t; -*-

(require 'ebox-test-support)

(ert-deftest ebox-node-set-scroll-clamps-and-repaints-visible-lines ()
  (ebox-test-with-mounted (buffer root
                           '(box :id "scroller" :width (ch 4) :height (lh 2)
                                 :overflow scroll
                                 (column
                                  (text "A")
                                  (text "B")
                                  (text "C"))))
    (should (equal (ebox-test-buffer-text buffer) "A 
B "))
    (should (= (ebox-node-scroll-offset root) 0))
    (should (= (ebox-node-set-scroll root 1) 1))
    (should (equal (ebox-test-buffer-text buffer) "B 
C "))
    (should (= (ebox-node-set-scroll root 99) 1))
    (should (= (ebox-node-scroll-offset root) 1))
    (should (ebox-test-buffer-matches-render-p root buffer))))

(ert-deftest ebox-scroll-commands-use-node-at-point ()
  (let ((ebox-scroll-step 1))
    (ebox-test-with-mounted (buffer root
                             '(box :id "scroller" :width (ch 4) :height (lh 2)
                                   :overflow scroll
                                   (column
                                    (text "A")
                                    (text "B")
                                    (text "C"))))
      (goto-char (point-min))
      (ebox-scroll-down)
      (should (equal (ebox-test-buffer-text buffer) "B 
C "))
      (ebox-scroll-up)
      (should (equal (ebox-test-buffer-text buffer) "A 
B ")))))

(ert-deftest ebox-page-scroll-commands-accept-explicit-line-counts ()
  (ebox-test-with-mounted (buffer root
                           '(box :id "scroller" :width (ch 4) :height (lh 2)
                                 :overflow scroll
                                 (column
                                  (text "A") (text "B") (text "C") (text "D"))))
    (goto-char (point-min))
    (ebox-scroll-page-down 2)
    (should (equal (ebox-test-buffer-text buffer) "C 
D "))
    (ebox-scroll-page-up 1)
    (should (equal (ebox-test-buffer-text buffer) "B 
C "))))

(ert-deftest ebox-input-session-edits-visible-text-and-restores-published-content ()
  (ebox-test-with-mounted (buffer root '(box (text :id "field" "abc")))
    (let* ((field (car (ebox-selector-query root "#field")))
           (session (ebox-input-begin buffer field)))
      (should (eq (ebox-input-active-p buffer) session))
      (should (eq (ebox-input-session-node session) field))
      (should (equal (ebox-input-text session) "abc"))
      (goto-char (point-min))
      (delete-char 3)
      (insert "xyz")
      (should (equal (ebox-input-text session) "xyz"))
      (should (equal (ebox-input-end session) "xyz"))
      (should-not (ebox-input-active-p buffer))
      (should (equal (ebox-test-buffer-text buffer) "abc ")))))

(ert-deftest ebox-input-session-excludes-focusable-text-fill ()
  (ebox-test-with-mounted (buffer root '(column (text :id "field" :tab-index 0 "value")
                                                 (text "after"))
                                  :width 400)
    (let* ((field (car (ebox-selector-query root "#field")))
           (session (ebox-input-begin buffer field)))
      (should (equal (ebox-node-bounds field) '(1 . 6)))
      (should (equal (ebox-input-text session) "value"))
      (ebox-input-end session))))

(ert-deftest ebox-input-session-defers-viewport-refit ()
  (ebox-test-with-mounted (buffer root '(column (text :id "field" "abc")
                                                 (box :width (vw 50) "half"))
                                  :width 400)
    (let* ((field (car (ebox-selector-query root "#field")))
           (session (ebox-input-begin buffer field)))
      (should-not (ebox-mount-set-viewport buffer 200 10))
      (should (eql 400 (car (ebox-mount-viewport buffer))))
      (ebox-input-end session)
      (should (equal (ebox-mount-viewport buffer) '(200 . 10))))))

(ert-deftest ebox-input-session-validates-lifecycle ()
  (ebox-test-with-mounted (buffer root '(box (text :id "field" "abc")))
    (let* ((field (car (ebox-selector-query root "#field")))
           (session (ebox-input-begin buffer field)))
      (should-error (ebox-input-begin buffer field) :type 'ebox-input-error)
      (ebox-input-end session)
      (should-not (ebox-input-text session))
      (should-not (ebox-input-end session)))))

(ert-deftest ebox-call-with-input-returns-reader-value-and-closes-session ()
  (ebox-test-with-mounted (buffer root '(column (box :id "field" :tab-index 0 "abc")
                                                 (box :id "other" :tab-index 0 "def")))
    (let ((field (car (ebox-selector-query root "#field"))))
      (ebox-focus (car (ebox-selector-query root "#other")) buffer)
      (should (equal (ebox-call-with-input field (lambda () "reader-value") buffer)
                     "reader-value"))
      ;; The input target keeps logical focus after the reader returns.
      (should (eq (ebox-focused-node buffer) field))
      (should-not (ebox-input-active-p buffer))
      (should (string-prefix-p "abc" (ebox-test-buffer-text buffer))))))

;;; ebox-scroll-input-tests.el ends here
