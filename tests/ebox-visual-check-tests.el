;;; ebox-visual-check-tests.el --- Tests for visual check tooling -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)

(unless load-file-name
  (error "This test file must be loaded from disk, not eval'ed directly"))

(load-file (expand-file-name "../scripts/ebox-visual-check.el"
                             (file-name-directory load-file-name)))

(ert-deftest ebox-visual-check-report-passes-all-checks ()
  (let ((report (ebox-visual-check-report)))
    (should (listp report))
    (should (cl-plusp (length report)))
    (dolist (scenario report)
      (should (plist-get scenario :name))
      (should (plist-get scenario :metrics))
      (dolist (check (plist-get scenario :checks))
        (should (plist-get check :ok))))))

(ert-deftest ebox-visual-check-renders-buffer-for-gui-inspection ()
  (let ((buffer (ebox-visual-check-render-buffer)))
    (unwind-protect
        (with-current-buffer buffer
          (should (string-match-p "Ebox Visual Check"
                                  (buffer-substring-no-properties
                                   (point-min) (point-max))))
          (should buffer-read-only))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(defun ebox-test--write-ppm (file pixels)
  "Write a small P3 PPM FILE from PIXELS.
PIXELS is a list of rows; each row is a list of (R G B) triples."
  (let ((height (length pixels))
        (width (length (car pixels))))
    (with-temp-file file
      (insert (format "P3\n%d %d\n255\n" width height))
      (dolist (row pixels)
        (dolist (pixel row)
          (insert (format "%d %d %d " (nth 0 pixel) (nth 1 pixel) (nth 2 pixel))))
        (insert "\n")))))

(ert-deftest ebox-visual-check-compares-identical-ppm-region ()
  (let* ((dir (make-temp-file "ebox-visual-check-" t))
         (expected (expand-file-name "expected.ppm" dir))
         (actual (expand-file-name "actual.ppm" dir)))
    (unwind-protect
        (progn
          (ebox-test--write-ppm
           expected
           '(((0 0 0) (10 10 10) (20 20 20))
             ((30 30 30) (40 40 40) (50 50 50))))
          (ebox-test--write-ppm
           actual
           '(((0 0 0) (10 10 10) (20 20 20))
             ((30 30 30) (40 40 40) (50 50 50))))
          (let ((result (ebox-visual-check-compare-region
                         expected actual
                         (list :x 1 :y 0 :width 2 :height 2))))
            (should (plist-get result :ok))
            (should (= (plist-get result :mismatches) 0))
            (should (= (plist-get result :samples) 4))))
      (delete-directory dir t))))

(ert-deftest ebox-visual-check-detects-ppm-region-mismatch ()
  (let* ((dir (make-temp-file "ebox-visual-check-" t))
         (expected (expand-file-name "expected.ppm" dir))
         (actual (expand-file-name "actual.ppm" dir)))
    (unwind-protect
        (progn
          (ebox-test--write-ppm
           expected
           '(((0 0 0) (10 10 10))
             ((20 20 20) (30 30 30))))
          (ebox-test--write-ppm
           actual
           '(((0 0 0) (10 10 10))
             ((20 20 20) (99 30 30))))
          (let ((result (ebox-visual-check-compare-region
                         expected actual
                         (list :x 0 :y 0 :width 2 :height 2)
                         5)))
            (should-not (plist-get result :ok))
            (should (= (plist-get result :mismatches) 1))
            (should (= (plist-get result :max-delta) 69))))
      (delete-directory dir t))))

;;; ebox-visual-check-tests.el ends here
