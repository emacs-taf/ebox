;;; ebox-image-file-tests.el --- Ebox image and file tests -*- lexical-binding: t; -*-

(require 'ebox-test-support)

(ert-deftest ebox-image-placeholder-preparation-reports-size-and-content ()
  (let ((prepared (ebox-image-prepare '(image :type xpm :data "bad")
                                      3 2 :adapter 'placeholder)))
    (should (equal (ebox-image-info prepared)
                   '(:adapter placeholder :converter nil :columns 3 :rows 2)))
    (should (equal (substring-no-properties (ebox-image-content prepared))
                   "...
..."))))

(ert-deftest ebox-image-text-converter-result-is-renderable-image-node ()
  (let* ((converted (copy-sequence "▀▀\n▀▀"))
         (converter (lambda (_source _columns _rows)
                      (let ((s (copy-sequence converted)))
                        (dotimes (i (length s))
                          (unless (= (aref s i) ?\n)
                            (put-text-property
                             i (1+ i) 'face
                             '(:foreground "#000000" :background "#ffffff") s)))
                        s)))
         (prepared (ebox-image-prepare '(image :type xpm :data "bad")
                                       2 2 :adapter 'text
                                       :converters (list (cons 'fixture converter))))
         (node (ebox-node-create 'image (list :image prepared))))
    (should (equal (ebox-image-info prepared)
                   '(:adapter text :converter fixture :columns 2 :rows 2)))
    (should (equal (ebox-test-render-text node) "▀▀
▀▀"))
    (should (equal (get-text-property 0 'face (ebox-render node))
                   '(:foreground "#000000" :background "#ffffff")))))

(ert-deftest ebox-node-set-image-repaints-mounted-image-node ()
  (let ((one (ebox-image-prepare '(image :type xpm :data "one") 2 1 :adapter 'placeholder))
        (two (ebox-image-prepare '(image :type xpm :data "two") 3 1 :adapter 'placeholder)))
    (ebox-test-with-mounted (buffer root (ebox-node-create 'image (list :id "img" :image one)))
      (should (equal (ebox-test-buffer-text buffer) ".."))
      (ebox-node-set-image root two)
      (should (equal (ebox-test-buffer-text buffer) "..."))
      (should (ebox-test-buffer-matches-render-p root buffer)))))

(ert-deftest ebox-image-prepare-rejects-invalid-protocol-inputs ()
  (should-error (ebox-image-prepare '(image :type xpm :data "bad") 0 1))
  (should-error (ebox-image-prepare '(image :type xpm :data "bad") 1 1 :adapter 'unknown))
  (should-error (ebox-image-prepare '(not-image) 1 1)))

(ert-deftest ebox-file-read-form-accepts-exactly-one-expression ()
  (should (equal (ebox-file-read-form "(box \"Hi\")") '(box "Hi")))
  (should-error (ebox-file-read-form "") :type 'user-error)
  (should-error (ebox-file-read-form "(box \"A\") (box \"B\")") :type 'user-error))

(ert-deftest ebox-file-evaluate-form-returns-renderable-dsl ()
  (let ((dsl (ebox-file-evaluate-form ''(box :width (ch 2) "Hi"))))
    (should (equal dsl '(box :width '(ch 2) "Hi")))
    (should (equal (ebox-test-render-text (ebox-build dsl)) "Hi"))))

(ert-deftest ebox-file-evaluate-buffer-reads-current-buffer-source ()
  (with-temp-buffer
    (insert "'(box :width (ch 2) \"OK\")")
    (should (equal (ebox-file-evaluate-buffer (current-buffer))
                   '(box :width '(ch 2) "OK")))))
;
(ert-deftest ebox-file-load-companion-prefers-only-newer-bytecode ()
  "A companion loads its source unless its bytecode is newer."
  (let* ((directory (make-temp-file "ebox-companion" t))
         (base (expand-file-name "demo" directory)))
    (unwind-protect
        (progn
          (with-temp-file (concat base ".el")
            (insert ";;; -*- lexical-binding: t; -*-\n"
                    "(put 'ebox-file-load-companion 'test-origin (file-name-extension load-file-name))\n"))
          (put 'ebox-file-load-companion 'test-origin nil)
          (ebox-file-load-companion (concat base ".ebox"))
          (should (equal (get 'ebox-file-load-companion 'test-origin) "el"))
          (byte-compile-file (concat base ".el"))
          (set-file-times (concat base ".el") (time-subtract nil 60))
          (put 'ebox-file-load-companion 'test-origin nil)
          (ebox-file-load-companion (concat base ".ebox"))
          (should (equal (get 'ebox-file-load-companion 'test-origin) "elc"))
          (set-file-times (concat base ".el") (time-add nil 60))
          (put 'ebox-file-load-companion 'test-origin nil)
          (ebox-file-load-companion (concat base ".ebox"))
          (should (equal (get 'ebox-file-load-companion 'test-origin) "el")))
      (put 'ebox-file-load-companion 'test-origin nil)
      (delete-directory directory t))))

;;; ebox-image-file-tests.el ends here
