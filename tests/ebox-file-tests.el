;;; ebox-file-tests.el --- Ebox file organization tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'ebox)

(defvar ebox-file-test-value nil)

(ert-deftest ebox-file-loads-ebox-el-and-ecss-companions ()
  (let* ((base (make-temp-file "ebox-file-"))
         (ebox (concat base ".ebox"))
         (el (concat base ".el"))
         (ecss (concat base ".ecss")))
    (unwind-protect
        (progn
          (with-temp-file el
            (insert ";;; -*- lexical-binding: t; -*-\n"
                    "(setq ebox-file-test-value 'loaded)\n"))
          (with-temp-file ecss
            (insert "'((\"&\" :color \"#123456\")\n"
                    "(\".card\" :font-weight bold))"))
          (with-temp-file ebox
            (insert "'(box :id \"root\" (box :class \"card\" \"ready\"))"))
          (setq ebox-file-test-value nil)
          (let ((buffer (generate-new-buffer " *ebox-file-test*")))
            (unwind-protect
                (with-current-buffer buffer
                  (insert-file-contents ebox)
                  (setq buffer-file-name ebox)
                  (let ((node (ebox-build (ebox-file-evaluate-buffer))))
                    (should node)
                    (should (member '(:foreground "#123456")
                                    (get-text-property 0 'face (ebox-render node))))
                    (should (eq ebox-file-test-value 'loaded))))
              (kill-buffer buffer))))
      (dolist (file (list base ebox el ecss))
        (when (file-exists-p file) (delete-file file))))))

(provide 'ebox-file-tests)

(ert-deftest ebox-file-dynamic-root-merges-companion-before-local-rules ()
  (let ((dir (make-temp-file "ebox-files-" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "app.ecss" dir)
            (insert "'((\"&\" :color \"#ff0000\"))"))
          (let* ((form '(let ((label "dynamic"))
                         (list 'column :ecss '(("&" :color "#0000ff")) label)))
                 (dsl (ebox-file-evaluate-form form (expand-file-name "app.ebox" dir)))
                 (rules (plist-get (car (ebox-dsl--split (cdr dsl))) :ecss)))
            (should (equal rules '(("&" :color "#ff0000")
                                   ("&" :color "#0000ff"))))
            (should (string-match-p "dynamic" (ebox-render (ebox-build dsl))))))
      (delete-directory dir t))))

(ert-deftest ebox-file-relative-nested-styles-are-inert-snapshots ()
  (let ((dir (make-temp-file "ebox-files-" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "panel.ecss" dir)
            (insert "'((\".item\" :color \"#ff0000\")) ; trailing comment\n"))
          (let* ((dsl (ebox-file-evaluate-form
                       ''(box (box :ecss-file "panel.ecss"
                                   (box :class "item" "inside"))
                              (box :class "item" :color "#00ff00" "outside"))
                       (expand-file-name "app.ebox" dir)))
                 (input (ebox-build dsl))
                 (rendered (ebox-render input)))
            (delete-file (expand-file-name "panel.ecss" dir))
            (should (equal-including-properties rendered (ebox-render input)))
            (should (equal (plist-get (get-text-property
                                       (string-match "inside" rendered) 'face rendered)
                                      :foreground) "#ff0000"))
            (should (equal (plist-get (get-text-property
                                       (string-match "outside" rendered) 'face rendered)
                                      :foreground) "#00ff00"))))
      (delete-directory dir t))))
;;; ebox-file-tests.el ends here
