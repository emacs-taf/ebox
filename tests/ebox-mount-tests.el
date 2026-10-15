;;; -*- lexical-binding: t; -*-
;;; ebox-mount-tests.el --- Public mount-time observer acceptance

(require 'ert)
(require 'ebox)

(ert-deftest ebox-mount-observer-reports-first-flush-and-validates-before-replace ()
  "A mount observer sees initial paint and later writes; invalid options keep the mount."
  (with-temp-buffer
    (let ((text (ebox-text-create "First")) reports)
      (ebox-mount (current-buffer) text :width 200 :height 10
                  :observer (lambda (_buffer report) (push report reports)))
      (let ((report (car reports)))
        (should (eq (plist-get report :provider) 'ebox))
        (should (> (plist-get report :lines) 0))
        (should (numberp (plist-get report :duration-ms))))
      (setq reports nil)
      (ebox-node-set-text text "Second")
      (let ((report (car reports)))
        (should (> (plist-get report :lines) 0))
        (should (numberp (plist-get report :duration-ms))))
      (let ((failed (condition-case nil
                        (progn (ebox-mount (current-buffer) '(text "Invalid") :observer 42) nil)
                      (wrong-type-argument t)))
            (current (buffer-substring-no-properties (point-min) (point-max))))
        (should failed)
        (should (equal (string-trim current) "Second")))
      (ebox-node-set-text text "Still mounted")
      (let ((current (buffer-substring-no-properties (point-min) (point-max))))
        (should (equal (string-trim current) "Still mounted"))))))

(ert-deftest ebox-remounted-subtree-restores-absolute-descendants ()
  "Reparenting a mounted tree preserves overlays and subsequent child updates."
  (with-temp-buffer
    (let* ((content (ebox-node-create 'flex '(:flex-direction column)
                                      (list (ebox-node-create 'box nil (list "Before")))))
           (overlay (ebox-node-create 'box '(:position absolute :top (lh 1) :left (ch 1))
                                      (list content)))
           (root (ebox-node-create 'box '(:width (ch 60) :height (lh 20)) (list overlay)))
           (wrapper (ebox-node-create 'column '(:width (ch 60) :height (lh 20)))))
      (ebox-mount (current-buffer) root :width 600 :height 25)
      (dotimes (_ 2)
        (ebox-with-batch
          (ebox-node-insert wrapper root)
          (ebox-mount (current-buffer) wrapper :width 600 :height 25))
        (ebox-with-batch
          (ebox-node-remove root)
          (ebox-mount (current-buffer) root :width 600 :height 25))
        (let ((text (buffer-substring-no-properties (point-min) (point-max)))
              (position (ebox-node-position content)))
          (should (string-match-p "Before" text))
          (should position)))
      (ebox-with-batch
        (ebox-node-put overlay :width '(ch 40))
        (ebox-node-replace-children content (list (ebox-node-create 'column nil (list "After")))))
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "After" text))
        (should-not (string-match-p "Before" text))))))

(provide 'ebox-mount-tests)
