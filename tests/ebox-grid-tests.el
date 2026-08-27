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
          (ebox-test-grid
           :grid-template-columns '((20) (20))
           :grid-template-rows '(1 1)
           :gap '(0 (1))
           (ebox-test-box :content "A")
           (ebox-test-box :content "B")
           (ebox-test-box :content "C")
           (ebox-test-box :content "D")))))
    (should (string-match-p "A.*B" plain))
    (should (string-match-p "C.*D" plain))))

(ert-deftest ebox-grid-supports-fractional-columns ()
  "Fractional tracks should fill a definite grid width."
  (let* ((node (ebox-test-grid
                :width '(120)
                :grid-template-columns '(1fr 2fr)
                (ebox-test-box :content "A")
                (ebox-test-box :content "B")))
         (lines (ebox-string-lines (ebox-render node))))
    (should (= (length lines) 1))
    (should (= (ebox--string-pixel-width (car lines)) 120))))

(ert-deftest ebox-grid-repeated-render-reuses-construction-time-config ()
  "Grid render and resize paths should not reparse canonical track config."
  (let* ((node (ebox-test-grid :width '(120)
                          :grid-template-columns '(1fr 2fr)
                          (ebox-test-box :content "A")
                          (ebox-test-box :content "B")))
         (calls 0)
         (original (symbol-function 'ebox-grid--normalize-config-props)))
    (cl-letf (((symbol-function 'ebox-grid--normalize-config-props)
               (lambda (props)
                 (cl-incf calls)
                 (funcall original props))))
      (ebox-render node)
      (ebox-render node))
    (should (zerop calls))))

(ert-deftest ebox-grid-minmax-fractional-columns-fill-and-shrink ()
  "Zero-minimum fractional maxima should remain responsive to width."
  (dolist (width '(120 60))
    (let* ((node (ebox-test-grid
                  :width (list width)
                  :grid-template-columns
                  '((minmax (0) (fr 1)) (minmax (0) (fr 2)))
                  (ebox-test-box :content "A" :width 'stretch)
                  (ebox-test-box :content "B" :width 'stretch)))
           (lines (ebox-string-lines (ebox-render node))))
      (should (= (ebox--string-max-pixel-width
                  (car lines)) width)))))

(ert-deftest ebox-grid-stretch-children-fill-fractional-tracks ()
  "Stretch-width children must reflow to their assigned fractional tracks."
  (let* ((left (ebox-test-box :content "left" :width 'stretch))
         (calls 0)
         (entry-left (list :node left :column 1 :column-span 1))
         (rendered (make-hash-table :test #'eq)))
    (puthash left "left" rendered)
    (cl-letf (((symbol-function 'ebox--render-with-cache)
               (lambda (&rest _)
                 (cl-incf calls)
                 "track-width")))
      (should (equal "track-width"
                     (ebox-grid--entry-source
                      entry-left rendered 100 '(:justify-items stretch))))
      (should (= calls 1)))))

(ert-deftest ebox-grid-constrains-auto-width-children-to-track-size ()
  "Auto-width grid children should render within their assigned track."
  (let* ((ebox-viewport-width 120)
         (node (ebox-test-grid
                :width '(120)
                :grid-template-columns '((50) (50))
                :gap '(0 (10))
                :border "#334155"
                (ebox-test-box :content "A\nA-long" :padding '(0 (4)))
                (ebox-test-box :content "B\nB-long" :padding '(0 (4)))))
         (lines (ebox-string-lines (ebox-render node)))
         (widths (mapcar #'ebox--string-pixel-width lines)))
    (should (equal widths (make-list (length widths) 120)))))

(ert-deftest ebox-grid-composite-auto-row-respects-track-width ()
  "A composite auto-width row must not duplicate its Grid track viewport."
  (let* ((node (ebox-test-grid
                :width '(120)
                :grid-template-columns '((120))
                (ebox-test-row
                 (ebox-test-box :content "Left" :border t)
                 (ebox-test-box :content "Right" :border t))))
         (widths (mapcar #'ebox--string-pixel-width
                         (ebox-string-lines (ebox-render node)))))
    (should (equal widths '(120)))))

(ert-deftest ebox-grid-sizes-auto-row-after-assigned-width-wrap ()
  "Auto rows should use the height of width-constrained child content."
  (let* ((node (ebox-test-grid
                :width '(40)
                :grid-template-columns '((38))
                :border "#334155"
                (ebox-test-box
                 :content "WIDE CONTENT WIDE CONTENT WIDE CONTENT WIDE CONTENT"
                 :wrap-mode 'word)))
         (lines (ebox-string-lines (ebox-render node)))
         (widths (mapcar #'ebox--string-pixel-width lines)))
    (should (= (length lines) 2))
    (should (equal widths (make-list (length widths) 40)))))

(ert-deftest ebox-grid-sizes-column-row-after-assigned-width-wrap ()
  "A composite Column row should use its final track-width text height."
  (let* ((node
          (ebox-test-grid
           :width '(20)
           :grid-template-columns '((20))
           :grid-auto-rows 'auto
           (ebox-test-column
            :width '(20)
            (ebox-test-box
             :content "fractional symbols\n1fr distributes by weight"
             :padding '(0 (2)) :border "#B85C3C"
             :wrap-mode 'word)
            (ebox-test-box :content "body" :height 1))))
         (lines (ebox-string-lines (ebox-render node)))
         (plain (mapcar #'substring-no-properties lines)))
    (should (> (length lines) 3))
    (should (equal (mapcar #'ebox--string-pixel-width lines)
                   (make-list (length lines) 20)))
    (should (cl-some (lambda (line) (string-match-p "weight" line)) plain))
    (should (string-match-p "body" (car (last plain))))))

(ert-deftest ebox-grid-aligns-every-line-before-border-render ()
  "Grid wrapper borders should stay on one right edge across child lines."
  (let* ((node (ebox-test-grid
                :width '(120)
                :grid-template-columns '((30) auto 1fr)
                :grid-template-rows '(2)
                :gap '(1 (4))
                :justify-content 'space-between
                :border "#334155"
                (ebox-test-box :content "FIXED\n30 PX")
                (ebox-test-box :content "AUTO\nINTRINSIC")
                (ebox-test-box :content "1FR\nREMAINDER")))
         (lines (ebox-string-lines (ebox-render node)))
         (widths (mapcar #'ebox--string-pixel-width lines)))
    (should (equal widths (make-list (length widths) 120)))))

(ert-deftest ebox-grid-keeps-padded-items-inside-column-width ()
  "Stack padding should use the widest Grid line instead of its first line."
  (let* ((header (ebox-test-box :content "Header" :width '(720)))
         (grid (ebox-test-grid
                :width '(718)
                :grid-template-columns '((220) 1fr)
                :gap '(1 (12))
                :border "#C97252"
                (ebox-test-box :content "Fixed" :width '(196)
                             :padding '(1 (12)))
                (ebox-test-box :content "Fractional" :width '(460)
                             :padding '(1 (12)))))
         (lines (ebox-string-lines (ebox-render (ebox-test-column header grid))))
         (widths (mapcar #'ebox--string-pixel-width lines)))
    (should (= (apply #'max widths) 720))))

(ert-deftest ebox-grid-supports-explicit-placement-and-span ()
  "Explicit placement should support a cell spanning two columns."
  (let ((plain
         (ebox-grid-test--plain
          (ebox-test-grid
           :grid-template-columns '((20) (20))
           :grid-template-rows '(1 1)
           (ebox-test-box :content "Header" :grid-column '(1 :span 2))
           (ebox-test-box :content "Left" :grid-row 2 :grid-column 1)
           (ebox-test-box :content "Right" :grid-row 2 :grid-column 2)))))
    (should (string-match-p "Header" plain))
    (should (string-match-p "Left.*Right" plain))))

(ert-deftest ebox-grid-uses-implicit-track-templates ()
  "Implicit columns should use `:grid-auto-columns' when they grow."
  (let* ((node (ebox-test-grid
                :grid-template-columns '((20))
                :grid-auto-columns '((30))
                :grid-auto-flow 'column
                (ebox-test-box :content "A")
                (ebox-test-box :content "B")))
         (line (car (ebox-string-lines (ebox-render node)))))
    (should (= (ebox--string-pixel-width line) 50))))

(ert-deftest ebox-grid-preserves-template-width-when-rows-grow ()
  "Implicit rows should retain the declared template column count."
  (let ((plain
         (ebox-grid-test--plain
          (ebox-test-grid
           :grid-template-columns '((20) (20) (20))
           (ebox-test-box :content "A")
           (ebox-test-box :content "B")
           (ebox-test-box :content "C")
           (ebox-test-box :content "D")
           (ebox-test-box :content "E")
           (ebox-test-box :content "F")))))
    (dolist (letter '("A" "B" "C" "D" "E" "F"))
      (should (string-match-p letter plain)))))

(ert-deftest ebox-grid-supports-repeat-minmax-and-content-alignment ()
  "Grid should normalize repeat/minmax tracks and align fixed tracks."
  (let* ((node (ebox-test-grid
                :width '(100)
                :justify-content 'center
                :grid-template-columns '((minmax (20) (30)) (repeat 1 (20)))
                (ebox-test-box :content "A")
                (ebox-test-box :content "B")))
         (line (car (ebox-string-lines (ebox-render node)))))
    (should (= (ebox--string-pixel-width line) 100))
    (should (= (length (seq-filter (lambda (char) (= char ?\s)) line))
               4))))

(ert-deftest ebox-grid-validates-flow-and-spans ()
  "Invalid flow and non-positive spans should be rejected."
  (should-error
   (ebox-render
    (ebox-test-grid :grid-auto-flow 'diagonal (ebox-test-box :content "A"))))
  (should-error
   (ebox-render
    (ebox-test-grid
     (ebox-test-box :content "A" :grid-column-span 0))))
  (should-error
   (ebox-render
    (ebox-test-grid
     (ebox-test-box :content "A" :grid-column 0)))))

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
  "Replacing one typed Grid child should reflow and preserve its sibling."
  (let* ((left (ebox-test-box :content "A" :host-ref 'left :width 20))
         (right (ebox-test-box :content "B" :id "right" :width 20))
         (node (ebox-test-grid :grid-template-columns '((20) (20)) left right))
         (buffer (ebox-render-to-buffer
                  (generate-new-buffer-name " *ebox-grid-update*") node)))
    (unwind-protect
        (progn
          (should (with-current-buffer buffer
                    (and (string-match-p "A" (buffer-string))
                         (string-match-p "B" (buffer-string)))))
          (let ((candidate (ebox-candidate-begin buffer)))
            (ebox-candidate-replace-host-ref
             candidate 'left
             (ebox-test-box :content "Updated" :host-ref 'left :width 20))
            (ebox-commit buffer candidate))
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
             (box "A")
             (box "B")))))
    (should (ebox-box-node-p node))
    (should (eq (ebox-layout-config-kind (ebox-box-node-layout node)) 'grid))
    (should (string-match-p "A" (ebox-grid-test--plain node)))
    (should (string-match-p "B" (ebox-grid-test--plain node)))))

(ert-deftest ebox-build-compiles-direct-grid-placement ()
  "The Ebox DSL should preserve direct child Box placement metadata."
  (let ((node
         (ebox-build
          '(grid :grid-template-columns ((20) (20))
             (box :grid-column (1 :span 2) "Header")))))
    (should (string-match-p "Header" (ebox-grid-test--plain node)))
    (should (equal (ebox-style-node-specified-value
                    (car (ebox-box-node-children node)) :grid-column)
                   '(1 :span 2)))))

(provide 'ebox-grid-tests)

;;; ebox-grid-tests.el ends here
