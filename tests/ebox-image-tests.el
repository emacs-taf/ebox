;;; ebox-image-tests.el --- Public image content acceptance -*- lexical-binding: t; -*-

;;; Commentary:
;; The real converter entry points run fixture executables.  No chafa/ffmpeg
;; installation or graphical display is required by batch acceptance.

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'ebox)

(defconst ebox-image-test--directory
  (file-name-directory (or load-file-name buffer-file-name)))

(defun ebox-image-test--svg (color)
  "Generate a tiny SVG source with COLOR."
  (format (concat "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"24\" height=\"24\">"
                  "<rect width=\"24\" height=\"24\" fill=\"%s\"/></svg>") color))

(defun ebox-image-test--fixture (callback)
  "Call CALLBACK with a local source, fixture directory, and invocation log."
  (let* ((directory (make-temp-file
                     (expand-file-name "fixtures/image-test-" ebox-image-test--directory) t))
         (source (expand-file-name "cover.svg" directory))
         (log (expand-file-name "calls" directory))
         ;; These adapter scenarios exercise the dependency-free Elisp path;
         ;; do not load the optional native module into later acceptance cases.
         (ebox-native-reflow-module-path nil)
         (exec-path (list directory))
         (process-environment (copy-sequence process-environment)))
    (unwind-protect
        (progn
          (dolist (name '("chafa" "ffmpeg"))
            (let ((file (expand-file-name name directory)))
              (copy-file (expand-file-name "fixtures/image-converter.py"
                                           ebox-image-test--directory) file)
              (set-file-modes file #o755)))
          (with-temp-file source (insert (ebox-image-test--svg "red")))
          (setenv "EBOX_IMAGE_FIXTURE_LOG" log)
          (setenv "EBOX_IMAGE_FIXTURE_FAIL" nil)
          (setenv "EBOX_IMAGE_FIXTURE_BAD" nil)
          (ebox-image-cache-clear)
          (funcall callback source directory log))
      (ebox-image-cache-clear)
      (delete-directory directory t))))

(defun ebox-image-test--calls (log)
  "Read converter invocations from LOG."
  (if (not (file-exists-p log)) nil
    (with-temp-buffer
      (insert-file-contents log)
      (split-string (buffer-string) "\n" t))))

(defun ebox-image-test--input (prepared &optional siblings)
  "Create canonical image PREPARED, with optional lyric SIBLINGS."
  (let* ((builder (ebox-source-builder-create))
         (cover (ebox-image-create prepared builder :identity 'cover :id "cover"))
         (nodes (list cover)))
    (when siblings
      (setq nodes
            (list
             (ebox-box-create
              :layout (ebox-column-layout-create)
              :source-handle (ebox-source-builder-bind builder :identity 'player)
              :owned-facts (ebox-canonical-facts-from-declarations 'column nil)
              :source-builder builder
              :children
              (list cover
                    (ebox-text-create
                     :value "The lyric stays here"
                     :source-handle (ebox-source-builder-bind
                                     builder :identity 'lyric :id "lyric")
                     :owned-facts (ebox-canonical-facts-from-declarations 'text nil)))))))
    (ebox-canonical-input-create nodes (ebox-source-builder-finish builder))))

(defun ebox-image-test--graphics (source columns rows &optional metrics)
  "Prepare graphical SOURCE with portable display METRICS for batch tests.
Only Emacs display capabilities are simulated; create-image and Ebox's entire
preparation, layout, ownership and publication paths execute normally."
  (pcase-let ((`(,cw ,lh ,ascent) (or metrics '(1 1 1))))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _frame) t))
              ((symbol-function 'frame-char-width) (lambda (&optional _frame) cw))
              ((symbol-function 'frame-char-height) (lambda (&optional _frame) lh))
              ((symbol-function 'font-info)
               (lambda (&rest _args) (vector nil nil lh lh 0 nil nil cw ascent (- lh ascent))))
              ((symbol-function 'image-type-available-p) (lambda (_type) t))
              ((symbol-function 'image-size)
               (lambda (spec &rest _args)
                 (cons (plist-get (cdr spec) :width) (plist-get (cdr spec) :height)))))
      (ebox-image-prepare source columns rows))))

(ert-deftest ebox-image-text-converter-prepares-once-and-owns-grid ()
  "Truecolor cells survive public render/update without conversion in the hot path."
  (ebox-image-test--fixture
   (lambda (source _directory log)
     (let* ((prepared (ebox-image-prepare source 24 12 :adapter 'text))
            (content (ebox-image-content prepared)))
       (should (equal (ebox-image-info prepared)
                      '(:adapter text :converter chafa :columns 24 :rows 12)))
       (should (eq prepared (ebox-image-prepare source 24 12 :adapter 'text)))
       (should (equal (ebox-image-test--calls log) '("chafa")))
       (should (= (length content) (+ (* 24 12) 11)))
       (should (equal (get-text-property 0 'face content)
                      '(:foreground "#DD0000" :background "#110101")))
       (put-text-property 0 1 'face '(:foreground "#ffffff") content)
       (setcar (get-text-property 1 'face content) :invalid)
       (should (= (aref (ebox-image-content prepared) 0) ?▀))
       (should (plist-get (get-text-property 1 'face (ebox-image-content prepared))
                          :foreground))
       (let ((input (ebox-image-test--input prepared t)))
         (cl-letf (((symbol-function 'call-process)
                    (lambda (&rest _args) (ert-fail "Converter ran during render")))
                   ((symbol-function 'create-image)
                    (lambda (&rest _args) (ert-fail "Image created during render"))))
           (with-temp-buffer
             (unwind-protect
                 (progn
                   (ebox-render-to-buffer (current-buffer) input)
                   (should (= (cl-count ?▀ (buffer-string)) 288))
                   (should (string-match-p "The lyric stays here" (buffer-string)))
                   (ebox-region-update "cover" :content (ebox-image-content prepared))
                   (ebox-render input))
               (ebox-unmount-buffer (current-buffer))))))))))

(ert-deftest ebox-image-converter-order-and-raw-rgb ()
  "Failed or malformed chafa output falls through to exact RGB pixel pairs."
  (ebox-image-test--fixture
   (lambda (source _directory log)
     (setenv "EBOX_IMAGE_FIXTURE_BAD" "chafa")
     (let* ((prepared (ebox-image-prepare source 2 2 :adapter 'text))
            (content (ebox-image-content prepared)))
       (should (eq (plist-get (ebox-image-info prepared) :converter) 'ffmpeg))
       (should (equal (substring-no-properties content) "▀▀\n▀▀"))
       (should (equal (get-text-property 0 'face content)
                      '(:foreground "#dd0000" :background "#dd0001")))
       (should (equal (get-text-property 4 'face content)
                      '(:foreground "#dd0102" :background "#dd0103")))
       (should (equal (ebox-image-test--calls log) '("chafa" "ffmpeg")))
       (should (eq prepared (ebox-image-prepare source 2 2 :adapter 'text)))
       (should (equal (ebox-image-test--calls log) '("chafa" "ffmpeg")))))))

(ert-deftest ebox-image-graphics-caches-descriptor-and-cell-slices ()
  "Generated SVG cells reuse one descriptor and exact slices across rendering."
  (ebox-image-test--fixture
   (lambda (source _directory log)
     (let ((create (symbol-function 'create-image)) (calls 0))
       (cl-letf (((symbol-function 'create-image)
                  (lambda (&rest args) (cl-incf calls) (apply create args))))
         (let* ((prepared (ebox-image-test--graphics source 24 12))
                (content (ebox-image-content prepared))
                (descriptor (cadr (get-text-property 0 'display content)))
                (input (ebox-image-test--input prepared t)))
           (should (eq (plist-get (ebox-image-info prepared) :adapter) 'graphics))
           (should (eq prepared (ebox-image-test--graphics source 24 12)))
           (should (= calls 1))
           (dotimes (y 12)
             (dotimes (x 24)
               (let* ((offset (+ x (* y 25)))
                      (display (get-text-property offset 'display content)))
                 (should (equal (car display) (list 'slice x y 1 1)))
                 (should (eq (cadr display) descriptor))
                 (should (eq display (get-text-property
                                      offset 'display (ebox-image-content prepared)))))))
           (dotimes (_ 2)
             (let ((rendered (ebox-render input)))
               (should (eq (get-text-property 0 'display rendered)
                           (get-text-property 0 'display content)))
               (should (= (cl-loop for i below (length rendered)
                                  count (eq (car-safe (car-safe
                                                      (get-text-property i 'display rendered)))
                                            'slice)) 288))))
           (should (= calls 1))
           (should-not (ebox-image-test--calls log))))))))

(ert-deftest ebox-image-graphics-uses-font-ascent-without-pixel-minimum ()
  "Small fonts set cell slices and ascent from their real metrics."
  (ebox-image-test--fixture
   (lambda (source _directory _log)
     (dolist (metrics '((3 8 6) (7 13 9) (7 16 13)))
       (pcase-let* ((`(,cw ,lh ,ascent) metrics)
                    (prepared (ebox-image-test--graphics source 2 2 metrics))
                    (display (get-text-property 4 'display (ebox-image-content prepared)))
                    (descriptor (cdr (cadr display))))
         (should (equal (car display) (list 'slice cw lh cw lh)))
         (should (= (plist-get descriptor :width) (* 2 cw)))
         (should (= (plist-get descriptor :height) (* 2 lh)))
         (should (= (plist-get descriptor :ascent) (ceiling (* 100 ascent) lh)))
         (should (= (floor (* lh (plist-get descriptor :ascent)) 100) ascent)))))))

(ert-deftest ebox-image-source-change-publishes-only-cover-and-rolls-back ()
  "Same-size source replacement changes one committed block and preserves the lyric."
  (ebox-image-test--fixture
   (lambda (source directory _log)
     (let* ((other (expand-file-name "other.svg" directory))
            (first (ebox-image-prepare source 24 12 :adapter 'text))
            second)
       (with-temp-file other (insert (ebox-image-test--svg "blue")))
       (setq second (ebox-image-prepare other 24 12 :adapter 'text))
       (with-temp-buffer
         (unwind-protect
             (progn
               (ebox-render-to-buffer (current-buffer) (ebox-image-test--input first t))
               (ebox-buffer-set-observer (current-buffer) #'ignore)
               (let ((before (buffer-string))
                     (revision (ebox-surface-buffer-revision (current-buffer))))
                 (let ((candidate (ebox-candidate-begin (current-buffer))) reached)
                   (ebox-candidate-replace-host-ref
                    candidate 'cover (ebox-image-test--input second))
                   (should-error (ebox-commit (current-buffer) candidate
                                              (lambda (_report)
                                                (setq reached t)
                                                (error "Reject cover"))))
                   (should reached))
                 (should (= revision (ebox-surface-buffer-revision (current-buffer))))
                 (should (equal-including-properties before (buffer-string)))
                 (let* ((start (save-excursion
                                 (goto-char (point-min))
                                 (search-forward "The lyric stays here")
                                 (match-beginning 0)))
                        (lyric (buffer-substring start (point-max))))
                   (cl-letf (((symbol-function 'call-process)
                              (lambda (&rest _args) (ert-fail "Converter ran during commit"))))
                     (ebox-region-update "cover" :content (ebox-image-content second)))
                   (let ((report (ebox-buffer-update-report (current-buffer))))
                     (ert-info ((format "%S" (cl-loop for key in
                                                      '(:strategy :projection-kind :dirty-count
                                                        :patch-count :projection-rejections)
                                                      append (list key (plist-get report key)))))
                       (should (memq (plist-get report :projection-kind) '(span-patch owner-scoped))))
                     (should-not (plist-get report :full-rerender))
                     (should-not (plist-get report :publication-full-root))
                     (should (= (plist-get report :dirty-count) 1))
                     (should (= (plist-get report :patch-count) 1)))
                   (should (equal-including-properties
                            lyric (buffer-substring start (point-max)))))
                 (dolist (actual (list (buffer-string)
                                      (ebox-render (plist-get
                                                    (ebox-surface-buffer-snapshot (current-buffer))
                                                    :input))))
                   (let ((expected (ebox-render (ebox-image-test--input second t))))
                     (should (equal (substring-no-properties actual)
                                    (substring-no-properties expected)))
                     (dotimes (i (length actual))
                       (should (equal (get-text-property i 'face actual)
                                      (get-text-property i 'face expected)))
                       (should (equal (get-text-property i 'display actual)
                                      (get-text-property i 'display expected))))))))
           (ebox-unmount-buffer (current-buffer))))))))

(ert-deftest ebox-image-graphics-source-change-retains-slices-locally ()
  "Graphics descriptor changes publish only the cover through canonical replacement."
  (ebox-image-test--fixture
   (lambda (source directory _log)
     (let* ((other (expand-file-name "other.svg" directory))
            (first (ebox-image-test--graphics source 24 12)) second)
       (with-temp-file other (insert (ebox-image-test--svg "blue")))
       (setq second (ebox-image-test--graphics other 24 12))
       (with-temp-buffer
         (unwind-protect
             (progn
               (ebox-render-to-buffer (current-buffer) (ebox-image-test--input first t))
               (dolist (prepared (list second first))
                 (let ((candidate (ebox-candidate-begin (current-buffer))))
                   (ebox-candidate-replace-host-ref
                    candidate 'cover (ebox-image-test--input prepared))
                   (cl-letf (((symbol-function 'create-image)
                              (lambda (&rest _args) (ert-fail "Image creation during commit"))))
                     (ebox-commit (current-buffer) candidate)))
                 (let ((report (ebox-buffer-update-report (current-buffer)))
                       (content (ebox-image-content prepared)))
                   (should (memq (plist-get report :projection-kind) '(span-patch owner-scoped)))
                   (should (= (plist-get report :dirty-count) 1))
                   (should (= (plist-get report :patch-count) 1))
                   (should-not (plist-get report :publication-full-root))
                   (dotimes (y 12)
                     (dotimes (x 24)
                       (let ((offset (+ x (* y 25))))
                         (should (eq (get-text-property (1+ offset) 'display)
                                     (get-text-property offset 'display content)))))))))
           (ebox-unmount-buffer (current-buffer))))))))

(ert-deftest ebox-image-placeholder-and-missing-image-types ()
  "Unavailable graphics falls back through converters to an exact ASCII area."
  (ebox-image-test--fixture
   (lambda (source _directory log)
     (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _frame) t))
               ((symbol-function 'font-info)
                (lambda (&rest _args) [nil nil 1 1 0 nil nil 1 1 0]))
               ((symbol-function 'image-type-available-p) (lambda (_type) nil)))
       (should (eq (plist-get (ebox-image-info (ebox-image-prepare source 3 2)) :adapter) 'text)))
     (should (equal (ebox-image-test--calls log) '("chafa")))
     (ebox-image-cache-clear)
     (setenv "EBOX_IMAGE_FIXTURE_FAIL" "both")
     (let ((prepared (ebox-image-prepare source 3 2 :adapter 'text)))
       (should (eq (plist-get (ebox-image-info prepared) :adapter) 'placeholder))
       (should (equal (ebox-image-content prepared) "...\n..."))
       (should (equal (ebox-render (ebox-image-test--input prepared)) "...\n...")))
     (let ((calls (ebox-image-test--calls log)))
       (should (eq (plist-get (ebox-image-info
                              (ebox-image-prepare source 2 1 :adapter 'placeholder))
                             :adapter) 'placeholder))
       (should (equal calls (ebox-image-test--calls log)))))))

(ert-deftest ebox-image-cache-keys-source-size-and-converter ()
  "Changed bytes, dimensions and converter identities cannot reuse a stale raster."
  (ebox-image-test--fixture
   (lambda (source _directory log)
     (let ((first (ebox-image-prepare source 2 2 :adapter 'text)))
       (with-temp-file source (insert (ebox-image-test--svg "blue")))
       (let ((next (ebox-image-prepare source 2 2 :adapter 'text)))
         (should-not (eq next first))
         (should-not (equal-including-properties (ebox-image-content next)
                                                 (ebox-image-content first))))
       (should (= (plist-get (ebox-image-info (ebox-image-prepare source 3 2 :adapter 'text))
                            :columns) 3))
       (should (eq (plist-get (ebox-image-info
                              (ebox-image-prepare source 2 2 :adapter 'text :converters nil))
                             :adapter) 'placeholder))
       (should (equal (ebox-image-test--calls log) '("chafa" "chafa" "chafa")))))))

(ert-deftest ebox-image-descriptor-source-and-converter-validation ()
  "Descriptor data is detached; pluggable output cannot inject display or native props."
  (ebox-image-test--fixture
   (lambda (_source _directory _log)
     (let* ((source (list 'image :type 'svg :data
                          (concat (ebox-image-test--svg "red") "<!-- 音乐 é -->")))
            (prepared (ebox-image-prepare source 2 1 :adapter 'text)))
       (should (eq (plist-get (ebox-image-info prepared) :converter) 'chafa))
       (setf (plist-get (cdr source) :data) (ebox-image-test--svg "blue"))
       (should-not (equal-including-properties
                    (ebox-image-content prepared)
                    (ebox-image-content (ebox-image-prepare source 2 1 :adapter 'text)))))
     (let* ((calls 0)
            (converters
             (list (cons 'bad (lambda (&rest _args) (error "Converter failed")))
                   (cons 'fixture
                         (lambda (_source _columns _rows)
                           (cl-incf calls)
                           (propertize "▀" 'face '(:foreground "#010203" :background "#040506")
                                       'display "unsafe" 'keymap (make-sparse-keymap))))))
            (prepared (ebox-image-prepare "missing" 1 1 :adapter 'text :converters converters))
            (content (ebox-image-content prepared)))
       (should (eq (plist-get (ebox-image-info prepared) :converter) 'fixture))
       (should-not (get-text-property 0 'display content))
       (should-not (get-text-property 0 'keymap content))
       (should (= calls 1)))
     (dolist (size '((0 1) (1 -1) (1.5 2)))
       (should-error (ebox-image-prepare "missing" (car size) (cadr size)))))))

(provide 'ebox-image-tests)
;;; ebox-image-tests.el ends here
