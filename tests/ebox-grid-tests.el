;;; ebox-grid-tests.el --- Ebox grid layout tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'seq)

(load-file (expand-file-name "../ebox.el"
                            (file-name-directory (or load-file-name
                                                     buffer-file-name))))

(defun ebox-grid-test--plain (node)
  "Render NODE and remove text properties."
  (substring-no-properties (ebox-render node)))

(ert-deftest ebox-grid-renders-row-major-cells ()
  "Grid should place unpositioned children in row-major order."
  (let ((plain
         (ebox-grid-test--plain
          (ebox-grid
           :grid-template-columns '((20) (20))
           :grid-template-rows '(1 1)
           :gap '(0 (1))
           (ebox-create :content "A")
           (ebox-create :content "B")
           (ebox-create :content "C")
           (ebox-create :content "D")))))
    (should (string-match-p "A.*B" plain))
    (should (string-match-p "C.*D" plain))))

(ert-deftest ebox-grid-supports-fractional-columns ()
  "Fractional tracks should fill a definite grid width."
  (let* ((node (ebox-grid
                :width '(120)
                :grid-template-columns '(1fr 2fr)
                (ebox-create :content "A")
                (ebox-create :content "B")))
         (lines (ebox-string-lines (ebox-render node))))
    (should (= (length lines) 1))
    (should (= (ebox--string-pixel-width (car lines)) 120))))

(ert-deftest ebox-grid-constrains-auto-width-children-to-track-size ()
  "Auto-width grid children should render within their assigned track."
  (let* ((ebox-viewport-width 120)
         (node (ebox-grid
                :width '(120)
                :grid-template-columns '((50) (50))
                :gap '(0 (10))
                :border "#334155"
                (ebox-create :content "A\nA-long" :padding '(0 (4)))
                (ebox-create :content "B\nB-long" :padding '(0 (4)))))
         (lines (ebox-string-lines (ebox-render node)))
         (widths (mapcar #'ebox--string-pixel-width lines)))
    (should (equal widths (make-list (length widths) 120)))))

(ert-deftest ebox-grid-sizes-auto-row-after-assigned-width-wrap ()
  "Auto rows should use the height of width-constrained child content."
  (let* ((node (ebox-grid
                :width '(40)
                :grid-template-columns '((38))
                :border "#334155"
                (ebox-create
                 :content "WIDE CONTENT WIDE CONTENT WIDE CONTENT WIDE CONTENT"
                 :wrap-mode 'word)))
         (lines (ebox-string-lines (ebox-render node)))
         (widths (mapcar #'ebox--string-pixel-width lines)))
    (should (= (length lines) 2))
    (should (equal widths (make-list (length widths) 40)))))

(ert-deftest ebox-grid-aligns-every-line-before-border-render ()
  "Grid wrapper borders should stay on one right edge across child lines."
  (let* ((node (ebox-grid
                :width '(120)
                :grid-template-columns '((30) auto 1fr)
                :grid-template-rows '(2)
                :gap '(1 (4))
                :justify-content 'space-between
                :border "#334155"
                (ebox-create :content "FIXED\n30 PX")
                (ebox-create :content "AUTO\nINTRINSIC")
                (ebox-create :content "1FR\nREMAINDER")))
         (lines (ebox-string-lines (ebox-render node)))
         (widths (mapcar #'ebox--string-pixel-width lines)))
    (should (equal widths (make-list (length widths) 120)))))

(ert-deftest ebox-grid-keeps-padded-items-inside-column-width ()
  "Stack padding should use the widest Grid line instead of its first line."
  (let* ((header (ebox-create :content "Header" :width '(720)))
         (grid (ebox-grid
                :width '(718)
                :grid-template-columns '((220) 1fr)
                :gap '(1 (12))
                :border "#C97252"
                (ebox-create :content "Fixed" :width '(196)
                             :padding '(1 (12)))
                (ebox-create :content "Fractional" :width '(460)
                             :padding '(1 (12)))))
         (lines (ebox-string-lines (ebox-render (ebox-column header grid))))
         (widths (mapcar #'ebox--string-pixel-width lines)))
    (should (= (apply #'max widths) 720))))

(ert-deftest ebox-grid-supports-explicit-placement-and-span ()
  "Explicit placement should support a cell spanning two columns."
  (let ((plain
         (ebox-grid-test--plain
          (ebox-grid
           :grid-template-columns '((20) (20))
           :grid-template-rows '(1 1)
           (ebox-grid-item (ebox-create :content "Header")
                           :grid-column '(1 :span 2))
           (ebox-grid-item (ebox-create :content "Left")
                           :grid-row 2 :grid-column 1)
           (ebox-grid-item (ebox-create :content "Right")
                           :grid-row 2 :grid-column 2)))))
    (should (string-match-p "Header" plain))
    (should (string-match-p "Left.*Right" plain))))

(ert-deftest ebox-grid-uses-implicit-track-templates ()
  "Implicit columns should use `:grid-auto-columns' when they grow."
  (let* ((node (ebox-grid
                :grid-template-columns '((20))
                :grid-auto-columns '((30))
                :grid-auto-flow 'column
                (ebox-create :content "A")
                (ebox-create :content "B")))
         (line (car (ebox-string-lines (ebox-render node)))))
    (should (= (ebox--string-pixel-width line) 50))))

(ert-deftest ebox-grid-preserves-template-width-when-rows-grow ()
  "Implicit rows should retain the declared template column count."
  (let ((plain
         (ebox-grid-test--plain
          (ebox-grid
           :grid-template-columns '((20) (20) (20))
           (ebox-create :content "A")
           (ebox-create :content "B")
           (ebox-create :content "C")
           (ebox-create :content "D")
           (ebox-create :content "E")
           (ebox-create :content "F")))))
    (dolist (letter '("A" "B" "C" "D" "E" "F"))
      (should (string-match-p letter plain)))))

(ert-deftest ebox-grid-supports-repeat-minmax-and-content-alignment ()
  "Grid should normalize repeat/minmax tracks and align fixed tracks."
  (let* ((node (ebox-grid
                :width '(100)
                :justify-content 'center
                :grid-template-columns '((minmax (20) (30)) (repeat 1 (20)))
                (ebox-create :content "A")
                (ebox-create :content "B")))
         (line (car (ebox-string-lines (ebox-render node)))))
    (should (= (ebox--string-pixel-width line) 100))
    (should (= (length (seq-filter (lambda (char) (= char ?\s)) line))
               4))))

(ert-deftest ebox-grid-validates-flow-and-spans ()
  "Invalid flow and non-positive spans should be rejected."
  (should-error
   (ebox-render
    (ebox-grid :grid-auto-flow 'diagonal (ebox-create :content "A"))))
  (should-error
   (ebox-render
    (ebox-grid
     (ebox-grid-item (ebox-create :content "A") :grid-column-span 0))))
  (should-error
   (ebox-render
    (ebox-grid
     (ebox-grid-item (ebox-create :content "A") :grid-column 0)))))

(ert-deftest ebox-grid-rejects-invalid-ecss-placement-before-layout ()
  "ECSS rules should reject invalid Grid placement before layout runs."
  (let ((ebox-style-stylesheet (ecss-stylesheet-create)))
    (dolist (declarations
             '((:grid-column-span 0)
               (:grid-row-span 0)
               (:grid-column 0)
               (:grid-row (1 :span 0))))
      (should-error (ebox-style-add-rule ".invalid" declarations)))
    (dolist (placement '(1 (1) (1 :span 2) (1 3)))
      (should (ebox-style-add-rule ".valid" (list :grid-column placement))))))

(ert-deftest ebox-grid-region-update-reflows-grid-child ()
  "Grid children should retain region updates through buffer rendering."
  (let* ((left (ebox-create :content "A" :id "left" :width 20))
         (right (ebox-create :content "B" :id "right" :width 20))
         (node (ebox-grid :grid-template-columns '((20) (20)) left right))
         (buffer (ebox-render-to-buffer
                  (generate-new-buffer-name " *ebox-grid-update*") node)))
    (unwind-protect
        (progn
          (should (with-current-buffer buffer
                    (and (string-match-p "A" (buffer-string))
                         (string-match-p "B" (buffer-string)))))
          (ebox-region-update (ebox-region-resolve buffer "left")
                              :content "Updated")
          (let ((updated (with-current-buffer buffer (buffer-string))))
            (should (string-match-p "Updated" updated))
            (should (string-match-p "B" updated))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-build-compiles-grid-layout ()
  "The public Ebox DSL should compile a grid node."
  (let ((node
         (ebox-build
          '(grid :grid-template-columns ((20) (20))
             (box :content "A")
             (box :content "B")))))
    (should (eq (plist-get node :ebox-type) 'grid))
    (should (string-match-p "A" (ebox-grid-test--plain node)))
    (should (string-match-p "B" (ebox-grid-test--plain node)))))

(ert-deftest ebox-build-compiles-grid-item-placement ()
  "The Ebox DSL should preserve grid-item placement metadata."
  (let ((node
         (ebox-build
          '(grid :grid-template-columns ((20) (20))
             (grid-item :grid-column (1 :span 2)
                        (box :content "Header"))))))
    (should (string-match-p "Header" (ebox-grid-test--plain node)))
    (should (equal (plist-get (car (plist-get node :children)) :grid-column)
                   '(1 :span 2)))))

(provide 'ebox-grid-tests)

;;; ebox-grid-tests.el ends here
