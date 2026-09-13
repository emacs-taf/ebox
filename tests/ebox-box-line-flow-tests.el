;;; ebox-box-line-flow-tests.el --- Box line flow contracts -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)
(setq load-prefer-newer t)
(load-file (expand-file-name "../ebox.el"
                            (file-name-directory load-file-name)))

(defun ebox-box-line-test--previous-pad (string height &optional offset padding)
  "Apply the frozen string padding algorithm to STRING at HEIGHT."
  (let* ((lines (ebox-string-lines string))
         (count (length lines)))
    (when (> height count)
      (let* ((fill (or padding
                       (ebox--pixel-blank (ebox--string-pixel-width string) 1)))
             (rest (- height count))
             (shift (or offset 0))
             (top (if (>= shift 0) (min shift rest)
                    (max 0 (+ shift rest)))))
        (setq lines (append (make-list top fill) lines
                            (make-list (- rest top) fill)))))
    (ebox-lines-join (seq-take lines height))))

(defun ebox-box-line-test--previous-prepare (box formatted height region-id filler)
  "Freeze BOX's old join/align/split/blank-normalization front half.
FORMATTED is captured before decoration; HEIGHT and REGION-ID are the actual
render constraints.  This oracle does not call the new line operation."
  (let* ((text-height (ebox-string-height formatted))
         (scroll-p (eq (ebox-get box :overflow) 'scroll))
         (start (if scroll-p
                    (max 0 (min (or (ebox-get box :scroll-offset) 0)
                                (max 0 (- text-height height))))
                  0))
         (lines (ebox-string-lines formatted))
         (visible (if scroll-p
                      (seq-subseq lines start (min (+ start height) text-height))
                    (seq-take lines height)))
         (ebox--propertize-private-content-line-p
          (not (and scroll-p (> text-height height))))
         (decorated
          (ebox-lines-join
           (cl-loop for line in visible for index from 0
                    collect (ebox--propertize-content-line
                             line region-id index filler))))
         (count (ebox-string-height decorated))
         (offset (pcase (ebox-get box :vertical-align)
                   ('bottom (- height count))
                   ('center (/ (- height count) 2))
                   (_ 0)))
         (aligned (ebox-box-line-test--previous-pad decorated height offset)))
    (mapcar
     (lambda (line)
       (if (and (string-empty-p (string-trim line))
                (ebox--line-content-metadata-uniform-p line)
                (not (ebox--line-has-non-content-properties-p line)))
           (let ((id (get-text-property 0 'ebox-content line))
                 (index (get-text-property 0 'ebox-content-idx line)))
             (propertize filler 'ebox-content (or id region-id)
                         'ebox-content-idx (if id index 0)
                         'ebox-content-owner region-id))
         line))
     (ebox-string-lines aligned))))

(defun ebox-box-line-test--reference-render (input &optional actual-p)
  "Render INPUT with the old front half, or current code when ACTUAL-P.
Check opaque identity between the actual formatted source and compositor output;
the surrounding ephemeral TP surface has its own snapshot value ownership."
  (let ((format-function (symbol-function 'ebox--format-content))
        (compositor (symbol-function 'ebox--window-render-flat-wrapper-chunk-lines))
        (formatted (make-hash-table :test 'eq)))
    (cl-letf (((symbol-function 'ebox--format-content)
               (lambda (box)
                 (let ((result (funcall format-function box)))
                   (puthash box
                            (list (copy-sequence result)
                                  (plist-get ebox--scroll-window-render-result
                                             :content-height))
                            formatted)
                   result)))
              ((symbol-function 'ebox--window-render-flat-wrapper-chunk-lines)
               (lambda (&rest args)
                 (when (and (nth 7 args) (not actual-p))
                   (let* ((box (car args))
                          (record (gethash box formatted))
                          (text (car record))
                          (height (or (cadr record)
                                      (ebox--content-height
                                       box (ebox-string-height text)))))
                     (should record)
                     (setf (nth 1 args)
                           (ebox-box-line-test--previous-prepare
                            box text height (nth 3 args) (nth 4 args)))))
                 (let* ((result (apply compositor args))
                        (source (car (gethash (car args) formatted)))
                        (source-pos (and source (string-match "Open" source)))
                        (line (cl-find-if (lambda (value) (string-match "Open" value))
                                          result)))
                   (when (and source-pos line)
                     (let ((pos (string-match "Open" line)))
                       (dolist (property '(keymap help-echo))
                         (should (eq (get-text-property pos property line)
                                     (get-text-property source-pos property source))))))
                   result))))
      (ebox-render input))))

(defun ebox-box-line-test--materializations (input)
  "Record actual intermediate newline joins/splits while rendering INPUT's root."
  (let* ((handle (ebox-node-source-handle (car (ebox-canonical-input-roots input))))
         (render (symbol-function 'ebox--render-box))
         (format-function (symbol-function 'ebox--format-content))
         (join (symbol-function 'mapconcat))
         (slice (symbol-function 'substring))
         (joined (make-hash-table :test 'eq))
         (joins 0) (splits 0) active formatting output)
    (cl-letf (((symbol-function 'ebox--render-box)
               (lambda (box)
                 (let ((previous active))
                   (setq active (eq (ebox-node-source-handle box) handle))
                   (unwind-protect (funcall render box)
                     (setq active previous)))))
              ((symbol-function 'ebox--format-content)
               (lambda (box)
                 (let ((previous formatting))
                   (setq formatting t)
                   (unwind-protect (funcall format-function box)
                     (setq formatting previous)))))
              ((symbol-function 'mapconcat)
               (lambda (function sequence separator)
                 (let ((result (funcall join function sequence separator)))
                   (when (and active (not formatting) (equal separator "\n")
                              (string-match-p "alpha" result))
                     (cl-incf joins)
                     (puthash result t joined))
                   result)))
              ((symbol-function 'substring)
               (lambda (string from &optional to)
                 (when (and active (not formatting) (gethash string joined))
                   (cl-incf splits))
                 (funcall slice string from to))))
      (setq output (ebox-render input)))
    (list :output output :joins joins :splits splits)))

(ert-deftest ebox-box-line-flow-avoids-intermediate-join-and-split ()
  "Ordinary decoration should join only at the existing compositor exit."
  (let* ((input (ebox-build
                 '(box :width (px 120) :height (lh 8) :overflow hidden
                       :padding ((lh 1) (px 3)) :border ((px 1) solid "#112233")
                       :bgcolor "#ddeeff" (text "alpha\nbeta"))))
         (expected (ebox-box-line-test--reference-render input))
         (observed (ebox-box-line-test--materializations input)))
    (should (equal-including-properties (plist-get observed :output) expected))
    (ert-info ((format "Actual content joins=%S, joined-string substrings=%S"
                       (plist-get observed :joins) (plist-get observed :splits)))
      (should (= (plist-get observed :joins) 1))
      (should (= (plist-get observed :splits) 0)))))

(ert-deftest ebox-box-line-flow-preserves-old-front-half-output ()
  "Composition, chrome, visibility and ownership match the frozen string path."
  (let* ((map (make-sparse-keymap))
         (callback (let ((value 'opened)) (lambda () value)))
         (rich (concat (propertize "Open 中" 'keymap map 'help-echo callback)
                       (propertize "\n" 'help-echo "newline only")
                       (propertize " " 'help-echo "rich blank") "\ntail\n")))
    (define-key map [mouse-1] #'ignore)
    (dolist (kind '(box row column flex grid))
      (dolist (height '(0 4 8))
        (dolist (align '(top center bottom))
          (dolist (overflow '(hidden visible scroll))
            (let* ((child (pcase kind
                            ('box `(box (text ,rich)))
                            ('grid `(grid :grid-template-columns ((px 110)) (text ,rich)))
                            (_ `(,kind (text ,rich)))))
                   (input
                    (ebox-build
                     `(box :width (px 140) :height (lh ,height) :overflow ,overflow
                           :padding ((lh 1) (px 3))
                           :border ((px 1) solid "#112233") :margin ((lh 1) (px 2))
                           :color "#123456" :bgcolor "#ddeeff" ,child)))
                   (_alignment
                    (plist-put (car (ebox-canonical-input-roots input))
                               :vertical-align align))
                   (source-before (copy-sequence rich))
                   (actual (ebox-box-line-test--reference-render input t))
                   (expected (ebox-box-line-test--reference-render input)))
              (ert-info ((format "%S height=%S align=%S overflow=%S"
                                 kind height align overflow))
                (should (equal-including-properties actual expected))
                (should (equal-including-properties rich source-before))
                (when-let* ((pos (string-match "Open" actual)))
                  (should (eq (lookup-key (get-text-property pos 'keymap actual)
                                         [mouse-1]) #'ignore))
                  (should (eq (funcall (get-text-property pos 'help-echo actual))
                              'opened))
                  (should (> (length (get-text-property
                                      pos 'ebox-content-owners actual)) 1)))))))))))

(ert-deftest ebox-box-line-flow-keeps-string-padding-contract ()
  "String padding retains nil, empty, first-line width and multiline filler."
  (dolist (input (list nil "" "A" "A\nlonger" "\n" "A\n"))
    (dolist (height '(0 1 2 4))
      (dolist (offset '(nil -2 0 2))
        (dolist (filler (list nil "" (propertize "L\nR" 'help-echo "fill")))
          (should (equal-including-properties
                   (ebox--lines-pad-vertical input height offset filler)
                   (ebox-box-line-test--previous-pad input height offset filler)))))))
  (let* ((input "A\nlonger")
         (output (ebox-string-lines (ebox--lines-pad-vertical input 3)))
         (fill (car (last output))))
    (should (= (ebox--string-pixel-width fill) (ebox--string-pixel-width "A")))))

(ert-deftest ebox-box-line-flow-keeps-simple-scroll-output ()
  "Complete simple scroll keeps its single join for overflow and underfill."
  (dolist (text '("alpha\nbeta" "alpha\n2\n3\n4\n5\n6\n7\n8\n9"))
    (let* ((input (ebox-build
                   `(box :width (px 120) :height (lh 8) :overflow scroll
                         :bgcolor "#ddeeff" (text ,text))))
           (expected (ebox-box-line-test--reference-render input))
           (observed (ebox-box-line-test--materializations input)))
      (should (equal-including-properties (plist-get observed :output) expected))
      (should (= (plist-get observed :joins) 1))
      (should (= (plist-get observed :splits) 0)))))

(ert-deftest ebox-box-line-flow-list-core-borrows-without-mutating ()
  "Line padding preserves the original spine, strings and opaque property values."
  (let* ((map (make-sparse-keymap))
         (callback (let ((value 'opened)) (lambda () value)))
         (rich (propertize "Open 中" 'keymap map 'help-echo callback
                           'ebox-content 17 'ebox-content-idx 2
                           'ebox-content-owner 18 'ebox-content-owners '(18 17)))
         (blank (propertize " " 'display '(space :width (7))
                            'ebox-content-owner 19)))
    ;; Use the explicit one-line string representation for string/list parity.
    ;; A raw empty list entry is covered separately below.
    (dolist (lines (list nil (list (ebox-lines-join '("")))
                        (list rich) (list rich "" blank)))
      (dolist (height '(0 1 3 5))
        (dolist (align '(top center bottom))
          (let* ((spine (cl-loop for tail on lines
                                collect (list tail (car tail) (cdr tail)
                                              (copy-sequence (car tail)))))
                 (count (length lines))
                 (offset (pcase align
                           ('bottom (- height count))
                           ('center (/ (- height count) 2))
                           (_ 0)))
                 (expected (ebox-box-line-test--previous-pad
                            (and lines (ebox-lines-join lines)) height offset))
                 (actual (ebox--pad-lines-vertical lines height offset))
                 (output (ebox-lines-join actual)))
            (should (equal-including-properties output expected))
            (when (= height count) (should (eq actual lines)))
            (when-let* ((pos (string-match "Open" output)))
              (should (eq (get-text-property pos 'keymap output) map))
              (should (eq (get-text-property pos 'help-echo output) callback)))
            ;; Only the string boundary grants independent mutable ownership.
            (when (> (length output) 0)
              (put-text-property 0 1 'help-echo "output-only" output)
              (aset output 0 ?Z))
            (dolist (record spine)
              (should (eq (car (nth 0 record)) (nth 1 record)))
              (should (eq (cdr (nth 0 record)) (nth 2 record)))
              (should (equal-including-properties (nth 1 record) (nth 3 record)))))))))
  (let* ((empty-line "")
         (lines (list empty-line))
         (padded (ebox--pad-lines-vertical lines 3)))
    (should (eq (ebox--pad-lines-vertical lines 1) lines))
    (should (eq (car padded) empty-line))
    (should (equal lines '("")))
    (should (= (ebox-string-height (ebox-lines-join padded)) 3)))
  (should-not (ebox--pad-lines-vertical nil 0))
  (should-not (ebox--pad-lines-vertical (list "A") 0)))

(ert-deftest ebox-box-line-flow-empty-content-retains-only-declared-chrome ()
  "Empty content and zero used height preserve only the declared chrome."
  (dolist (formatted '(nil "" "A\nB"))
    (dolist (height '(0 1 3))
      (let* ((input (ebox-build
                     '(box :width (px 40) :height (lh 3) :overflow hidden :padding ((lh 1) (px 2))
                           :border ((px 1) solid "#112233") (text "unused"))))
             (root (car (ebox-canonical-input-roots input)))
             (handle (ebox-node-source-handle root))
             (format-function (symbol-function 'ebox--format-content))
             (height-function (symbol-function 'ebox--content-height)))
        ;; Isolate the decoration boundary, including zero used content height.
        (cl-letf (((symbol-function 'ebox--format-content)
                   (lambda (box)
                     (if (eq (ebox-node-source-handle box) handle)
                         formatted
                       (funcall format-function box))))
                  ((symbol-function 'ebox--content-height)
                   (lambda (box natural &optional rendered)
                     (if (eq (ebox-node-source-handle box) handle)
                         height
                       (funcall height-function box natural rendered)))))
          (let ((actual (ebox-box-line-test--reference-render input t))
                (expected (ebox-box-line-test--reference-render input)))
            (should (equal-including-properties actual expected))
            (when (= height 0)
              (should (= (ebox-string-height actual) 2)))))))))

(ert-deftest ebox-box-line-flow-zero-width-default-padding-is-a-line ()
  "Zero-width default blanks remain empty string lines at the list boundary."
  (dolist (padding '(((lh 0) (px 0)) ((lh 1) (px 2))))
    (let* ((input (ebox-build
                   `(box :width (px 0) :height (lh 3) :overflow hidden
                         :padding ,padding (text ""))))
           (actual (ebox-box-line-test--reference-render input t))
           (expected (ebox-box-line-test--reference-render input)))
      (should (equal-including-properties actual expected)))))

(ert-deftest ebox-box-line-flow-scroll-to-end-and-back-preserves-source ()
  "Real decorated scroll A→B→A keeps stored lines intact and reaches the end."
  (let* ((buffer (generate-new-buffer " *ebox-box-line-scroll*"))
         (map (make-sparse-keymap))
         (_key (define-key map [mouse-1] #'ignore))
         (text (mapconcat (lambda (index) (format "Open %02d" index))
                          (number-sequence 0 9) "\n"))
         (input (ebox-build
                 `(box :width (px 120) :height (lh 4) :overflow scroll
                       :padding ((lh 0) (px 2)) :border ((px 1) solid "#112233")
                       (text ,(propertize text 'keymap map 'help-echo "action")))))
         (ebox-runtime-idle-prewarm nil)
         (ebox-runtime-idle-reflow-cache-prewarm nil))
    (unwind-protect
        (progn
          (ebox-render-to-buffer buffer input)
          (with-current-buffer buffer
            (let* ((root (plist-get (ebox--buffer-render-state buffer) :root-node))
                   (id (plist-get root :region-id))
                   (state (ebox--scroll-get-state id))
                   (lines (plist-get state :content-lines))
                   (spine (cl-loop for tail on lines
                                  collect (list tail (car tail) (cdr tail)
                                                (copy-sequence (car tail)))))
                   (initial (buffer-string))
                   (end (max 0 (- (length lines) (plist-get state :content-height)))))
              (should state)
              (goto-char (point-min))
              (ebox-scroll-down end)
              (let* ((current (ebox--scroll-get-state id))
                     (render-state (ebox--buffer-render-state buffer))
                     (fresh-input
                      (ebox-canonical-input-create
                       (list (plist-get render-state :root-node))
                       (plist-get render-state :source-index))))
                (should (= end (max 0 (- (length (plist-get current :content-lines))
                                        (plist-get current :content-height)))))
                (should (= (plist-get current :scroll-offset) end))
                (should (> end 0))
                (should (string-match-p "Open 09" (buffer-string)))
                (should (equal-including-properties
                         (buffer-string) (ebox-box-line-test--reference-render fresh-input))))
              (ebox-scroll-up end)
              (should (= (plist-get (ebox--scroll-get-state id) :scroll-offset) 0))
              (should (equal-including-properties (buffer-string) initial))
              (dolist (record spine)
                (should (eq (car (nth 0 record)) (nth 1 record)))
                (should (eq (cdr (nth 0 record)) (nth 2 record)))
                (should (equal-including-properties (nth 1 record) (nth 3 record)))))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(provide 'ebox-box-line-flow-tests)
;;; ebox-box-line-flow-tests.el ends here
