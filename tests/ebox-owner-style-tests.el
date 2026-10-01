;;; ebox-owner-style-tests.el --- Retained owner style publication -*- lexical-binding: t; -*-

;;; Commentary:
;; Owner paint and inherited fonts publish locally only in retained slots.

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'ebox)

(defun ebox-owner-style-test--canonical (spec)
  "Build canonical SPEC with stable source identities and public Host refs."
  (let ((builder (ebox-source-builder-create)))
    (cl-labels
        ((node (entry)
           (pcase-let* ((`(,ref ,tag ,style ,surface . ,children) entry)
                        (declarations (ebox-style-compile-form tag style))
                        (handle (ebox-source-builder-bind
                                 builder :identity ref :key ref :id ref
                                 :declarations declarations))
                        (facts (ebox-canonical-facts-from-declarations
                                tag declarations surface)))
             (if (eq tag 'text)
                 (ebox-text-create :value (car children) :source-handle handle
                                   :owned-facts facts)
               (apply #'ebox-box-create
                      (append (ebox-canonical-box-configuration tag declarations)
                              (list :source-handle handle :owned-facts facts
                                    :source-builder builder
                                    :children (mapcar #'node children))))))))
      (let ((root (node spec)))
        (ebox-canonical-input-create
         (list root) (ebox-source-builder-finish builder))))))

(defun ebox-owner-style-test--row (index selected &optional changes)
  "Describe row INDEX with SELECTED paint and optional CHANGES."
  (let* ((active (= index selected))
         (ref (intern (format "row-%d" index)))
         (cells
          `((,(intern (format "index-%d" index)) box
             (:width stretch :height (lh 1) :overflow hidden :font-weight normal
              :color ,(if active "#ff0000" "#777777")) nil
             (,(intern (format "number-%d" index)) text nil nil
              ,(number-to-string index)))
            (,(intern (format "title-%d" index)) box
             (:width stretch :height (lh 1) :overflow hidden) nil
             (,(intern (format "label-%d" index)) text nil nil
              ,(or (plist-get changes :label)
                   (if (= index 0) "Alpha" "Bravo")))))))
    `(,ref grid
       (:width ,(or (plist-get changes :width) 'stretch)
        :height ,(or (plist-get changes :height) '(lh 1))
        :padding-inline ,(or (plist-get changes :padding) '(ch 1))
        :grid-template-columns ((ch 4) (fr 1))
        :overflow hidden :wrap-mode none
        :font-weight ,(if active 'bold 'normal)
        :background-color ,(if active "#223344" "#ffffff"))
       (:help-echo ,(if active "Selected row" "Choose row"))
       ,@(if (plist-get changes :reorder) (reverse cells) cells))))

(defun ebox-owner-style-test--rows (selected &optional changes)
  "Describe the retained owner with SELECTED style and CHANGES."
  `(rows column (:max-width none :max-height none :width ,(or (plist-get changes :width) '(ch 40))
                 :height ,(or (plist-get changes :height) '(lh 3))
                 :font-weight ,(if (= selected 1) 'bold 'normal)
                 :background-color ,(if (= selected 1) "#445566" "#eeeeee")) nil
     ,(ebox-owner-style-test--row 0 selected changes)
     ,(ebox-owner-style-test--row 1 selected changes)))

(defun ebox-owner-style-test--input (selected &optional changes)
  "Build two fixed Grid rows with SELECTED paint and optional CHANGES."
  (ebox-owner-style-test--canonical
   `(root column (:width (ch 40) :height (lh 6) :color "#112233"
                  :background-color "#dddddd") nil
      (heading text nil nil "Heading")
      ,(ebox-owner-style-test--rows selected changes)
      (footer text nil nil "Footer"))))

(defun ebox-owner-style-test--candidate (selected &optional changes)
  "Replace one retained owner with SELECTED style and CHANGES."
  (let ((candidate (ebox-candidate-begin (current-buffer))))
    (ebox-candidate-replace-host-ref
     candidate 'rows
     (ebox-owner-style-test--canonical (ebox-owner-style-test--rows selected changes)))
    candidate))

(defun ebox-owner-style-test--visible (text)
  "Return TEXT's visible characters, paint, display and interaction properties."
  (list (substring-no-properties text)
        (cl-loop for position below (length text)
                 collect (mapcar (lambda (property)
                                   (get-text-property position property text))
                                 '(face display help-echo pointer)))))

(defun ebox-owner-style-test--check (input)
  "Compare the current publication with a fresh rendering of INPUT."
  (should (equal (ebox-owner-style-test--visible (buffer-string))
                 (ebox-owner-style-test--visible (ebox-render input)))))

(defun ebox-owner-style-test--local-report ()
  "Require the current committed report to describe local owner projection."
  (let ((report (ebox-buffer-update-report (current-buffer))))
    (ert-info ((format "%S" report))
      (should (memq (plist-get report :projection-kind) '(span-patch owner-scoped)))
      (should (memq (plist-get report :strategy) '(span-patch owner-rerender)))
      (should-not (plist-get report :native-fallback-reason))
      (should-not (plist-get report :publication-full-root)))))

(ert-deftest ebox-owner-style-grid-row-keeps-one-line-slot ()
  "A Grid owner's paint, font, child content and native properties stay local."
  (let ((ebox-native-reflow-module-path nil))
    (cl-labels ((input (selected label)
                 (ebox-owner-style-test--canonical
                  `(root column (:width (ch 40) :height (lh 4)
                                 :background-color "#cccccc") nil
                     ,(ebox-owner-style-test--row 0 selected (list :label label))
                     (footer text nil nil "Unchanged footer")))))
      (with-temp-buffer
        (unwind-protect
            (progn
              (ebox-render-to-buffer (current-buffer) (input 1 "Alpha"))
              (dolist (case '((0 "Longer title") (1 "X") (0 "Alpha")))
                (pcase-let ((`(,selected ,label) case)
                            (candidate (ebox-candidate-begin (current-buffer))))
                  (ebox-candidate-replace-host-ref
                   candidate 'row-0
                   (ebox-owner-style-test--canonical
                    (ebox-owner-style-test--row 0 selected (list :label label))))
                  (ebox-commit (current-buffer) candidate)
                  (ebox-owner-style-test--local-report)
                  (should (= 1 (plist-get (ebox-buffer-update-report (current-buffer))
                                         :patch-count)))
                  (ebox-owner-style-test--check (input selected label)))))
          (ebox-unmount-buffer (current-buffer)))))))

(ert-deftest ebox-owner-style-publishes-paint-and-inherited-fonts-locally ()
  "An owner's own paint and font changes retain the group of row slots."
  (let ((ebox-native-reflow-module-path nil))
    (with-temp-buffer
      (unwind-protect
          (progn
            (ebox-render-to-buffer (current-buffer) (ebox-owner-style-test--input 0))
            (dolist (selected '(1 0 1))
              (let ((next (ebox-owner-style-test--input selected)))
                (should-not (ebox-canonical-input-equal-p
                             next (ebox-owner-style-test--input (- 1 selected))))
                (ebox-commit (current-buffer) (ebox-owner-style-test--candidate selected))
                (ebox-owner-style-test--local-report)
                (ebox-owner-style-test--check next))))
        (ebox-unmount-buffer (current-buffer))))))

(ert-deftest ebox-owner-style-rejection-preserves-published-generation ()
  "Rejected local style publication preserves pixels and permits a local retry."
  (let ((ebox-native-reflow-module-path nil))
    (with-temp-buffer
      (unwind-protect
          (progn
            (ebox-render-to-buffer (current-buffer) (ebox-owner-style-test--input 0))
            (let ((before (buffer-string))
                  (report (ebox-buffer-update-report (current-buffer)))
                  (next (ebox-owner-style-test--input 1)))
              (should-error
               (ebox-commit (current-buffer) (ebox-owner-style-test--candidate 1)
                            (lambda (_report) (error "Reject owner style"))))
              (should (equal-including-properties before (buffer-string)))
              (should (equal report (ebox-buffer-update-report (current-buffer))))
              (ebox-commit (current-buffer) (ebox-owner-style-test--candidate 1))
              (ebox-owner-style-test--local-report)
              (ebox-owner-style-test--check next)))
        (ebox-unmount-buffer (current-buffer))))))

(ert-deftest ebox-owner-style-declines-changed-layout-inputs ()
  "Owner padding changes cannot reuse a paint/typography slot proof."
  (let ((ebox-native-reflow-module-path nil))
    (with-temp-buffer
      (unwind-protect
          (progn
            (ebox-render-to-buffer (current-buffer) (ebox-owner-style-test--input 0))
            (let ((next (ebox-owner-style-test--input 1 '(:padding (ch 2)))))
              (ebox-commit (current-buffer)
                           (ebox-owner-style-test--candidate 1 '(:padding (ch 2))))
              (should-not (memq (plist-get (ebox-buffer-update-report (current-buffer))
                                           :projection-kind)
                                '(span-patch owner-scoped)))
              (ebox-owner-style-test--check next)))
        (ebox-unmount-buffer (current-buffer))))))

(ert-deftest ebox-owner-style-declines-reordered-children ()
  "Moving keyed cells cannot be certified as an unchanged owner role topology."
  (let ((ebox-native-reflow-module-path nil))
    (with-temp-buffer
      (unwind-protect
          (progn
            (ebox-render-to-buffer (current-buffer) (ebox-owner-style-test--input 0))
            (let ((next (ebox-owner-style-test--input 1 '(:reorder t))))
              (ebox-commit (current-buffer)
                           (ebox-owner-style-test--candidate 1 '(:reorder t)))
              (should-not (memq (plist-get (ebox-buffer-update-report (current-buffer))
                                           :projection-kind)
                                '(span-patch owner-scoped)))
              (ebox-owner-style-test--check next)))
        (ebox-unmount-buffer (current-buffer))))))

(ert-deftest ebox-owner-style-declines-changed-owner-slots ()
  "Changed owner widths and heights require a new allocation."
  (let ((ebox-native-reflow-module-path nil))
    (dolist (changes '((:width (ch 30)) (:height (lh 2))))
      (with-temp-buffer
        (unwind-protect
            (progn
              (ebox-render-to-buffer (current-buffer) (ebox-owner-style-test--input 0))
              (let ((next (ebox-owner-style-test--input 1 changes)))
                (ebox-commit (current-buffer)
                             (ebox-owner-style-test--candidate 1 changes))
                (should-not (memq (plist-get (ebox-buffer-update-report (current-buffer))
                                             :projection-kind)
                                  '(span-patch owner-scoped)))
                (ebox-owner-style-test--check next)))
          (ebox-unmount-buffer (current-buffer)))))))

(defun ebox-owner-style-test--album (selected &optional height ref)
  "Describe scroll owner REF for SELECTED with optional HEIGHT."
  (let ((ref (or ref 'album)))
    `(,ref box (:width stretch :height (lh ,(or height 1)) :overflow hidden
                :background-color ,(if (= selected 0) "#eeeeee" "#dddddd")) nil
       (,(intern (format "%s-label" ref)) text nil nil
        ,(format "%s %s" (if (eq ref 'album) "Album" (symbol-name ref))
                 (if (= selected 0) "A" "Bravo"))))))

(defun ebox-owner-style-test--scroll-input
    (selected &optional scroll-id album-height)
  "Build row owners beside scroll content for SELECTED and SCROLL-ID.
ALBUM-HEIGHT changes the album slot."
  (ebox-owner-style-test--canonical
   `(root column (:width (ch 40) :height (lh 8)) nil
      ,(ebox-owner-style-test--row 0 selected)
      ,(ebox-owner-style-test--row 1 selected)
      (,(or scroll-id 'scroll) column
       (:width (ch 40) :height (lh 3) :overflow scroll) nil
       ,(ebox-owner-style-test--album selected album-height)
       ,(ebox-owner-style-test--album selected nil 'album-extra)
       ,@(cl-loop for i below 8
                  collect `(,(intern (format "scroll-row-%d" i)) box
                            (:width stretch :height (lh 1) :overflow hidden) nil
                            (,(intern (format "scroll-label-%d" i)) text nil nil
                             ,(format "Scroll row %d" i)))))
      (other-scroll column (:width (ch 40) :height (lh 2) :overflow scroll) nil
       ,(ebox-owner-style-test--album selected nil 'other-album)
       (other-first text nil nil "Other first")
       (other-last text nil nil "Other last")))))

(defun ebox-owner-style-test--scroll-candidate (selected &optional album-height)
  "Change the row and cached album owners to SELECTED in one candidate."
  (let ((candidate (ebox-candidate-begin (current-buffer))))
    (dotimes (index 2)
      (ebox-candidate-replace-host-ref
       candidate (intern (format "row-%d" index))
       (ebox-owner-style-test--canonical (ebox-owner-style-test--row index selected))))
    (ebox-candidate-replace-host-ref
     candidate 'album
     (ebox-owner-style-test--canonical (ebox-owner-style-test--album selected album-height)))
    (dolist (ref '(album-extra other-album))
      (ebox-candidate-replace-host-ref
       candidate ref
       (ebox-owner-style-test--canonical (ebox-owner-style-test--album selected nil ref))))
    candidate))

(ert-deftest ebox-owner-style-composes-rows-with-retained-scroll-content ()
  "Row styles and an album label publish locally with a retained scroll cache."
  (let ((ebox-native-reflow-module-path nil))
    (with-temp-buffer
      (unwind-protect
          (progn
            (ebox-render-to-buffer (current-buffer) (ebox-owner-style-test--scroll-input 0))
            (dolist (selected '(1 0 1))
              (ebox-commit (current-buffer) (ebox-owner-style-test--scroll-candidate selected))
              (ebox-owner-style-test--local-report)
              (ebox-owner-style-test--check (ebox-owner-style-test--scroll-input selected)))
            ;; Revealing the original window again must use the updated cache.
            (goto-char (point-min))
            (search-forward "Album Bravo")
            (backward-char 1)
            (ebox-scroll-down 1)
            (ebox-scroll-up 1)
            (ebox-owner-style-test--check (ebox-owner-style-test--scroll-input 1)))
        (ebox-unmount-buffer (current-buffer))))))

(ert-deftest ebox-owner-style-hidden-scroll-content-rolls-back-with-rows ()
  "Hidden cache changes and visible row changes commit and roll back together."
  (let ((ebox-native-reflow-module-path nil)
        (case-fold-search nil))
    (with-temp-buffer
      (unwind-protect
          (progn
            (ebox-render-to-buffer (current-buffer) (ebox-owner-style-test--scroll-input 0))
            (goto-char (point-min))
            (search-forward "Album A")
            (backward-char 1)
            (ebox-scroll-down 1)
            (let ((before (buffer-string))
                  (report (ebox-buffer-update-report (current-buffer))))
              (should-error
               (ebox-commit (current-buffer) (ebox-owner-style-test--scroll-candidate 1)
                            (lambda (_report) (error "Reject cached content"))))
              (should (equal-including-properties before (buffer-string)))
              (should (equal report (ebox-buffer-update-report (current-buffer)))))
            (ebox-scroll-up 1)
            (ebox-owner-style-test--check (ebox-owner-style-test--scroll-input 0))
            (ebox-scroll-down 1)
            (ebox-commit (current-buffer) (ebox-owner-style-test--scroll-candidate 1))
            (ebox-owner-style-test--local-report)
            (should-not (string-match-p "Album Bravo" (buffer-string)))
            (ebox-scroll-up 1)
            (ebox-owner-style-test--check (ebox-owner-style-test--scroll-input 1)))
        (ebox-unmount-buffer (current-buffer))))))

(ert-deftest ebox-owner-style-declines-replaced-scroll-identity ()
  "Replacing the scroll box cannot reuse its old cached coordinate proof."
  (let ((ebox-native-reflow-module-path nil))
    (with-temp-buffer
      (unwind-protect
          (progn
            (ebox-render-to-buffer (current-buffer) (ebox-owner-style-test--scroll-input 0))
            (let ((next (ebox-owner-style-test--scroll-input 1 'replacement-scroll)))
              (ebox-commit (current-buffer) next)
              (should-not (plist-get (ebox-buffer-update-report (current-buffer))
                                     :projection-kind))
              (ebox-owner-style-test--check next)))
        (ebox-unmount-buffer (current-buffer))))))

(ert-deftest ebox-owner-style-declines-unproven-scroll-windows ()
  "A partially mounted owner cannot prove its complete replacement window."
  (let ((ebox-native-reflow-module-path nil))
    (with-temp-buffer
      (unwind-protect
          (progn
            (ebox-render-to-buffer
             (current-buffer) (ebox-owner-style-test--scroll-input 0 nil 4))
            (ebox-commit (current-buffer)
                         (ebox-owner-style-test--scroll-candidate 1 4))
            (should-not (plist-get (ebox-buffer-update-report (current-buffer))
                                   :projection-kind))
            (ebox-owner-style-test--check (ebox-owner-style-test--scroll-input 1 nil 4)))
        (ebox-unmount-buffer (current-buffer))))))

(ert-deftest ebox-owner-style-declines-content-beyond-cached-prefix ()
  "An owner beyond the retained lazy prefix cannot authorize a cache patch."
  (let ((ebox-native-reflow-module-path nil)
        (ebox-viewport-width 40) (ebox-viewport-height 8)
        (ebox-scroll-lazy-idle-prefetch-lines 0))
    (cl-labels
        ((input (selected)
           (ebox-owner-style-test--canonical
            `(root column (:width (ch 40) :height (lh 8)) nil
               ,(ebox-owner-style-test--row 0 selected)
               (scroll column (:width (ch 40) :height (vh 50) :overflow scroll) nil
                ,@(cl-loop for index below 200
                           collect `(,(intern (format "earlier-%d" index)) text nil nil "Earlier"))
                ,(ebox-owner-style-test--album selected))))))
      (with-temp-buffer
        (unwind-protect
            (progn
              (ebox-render-to-buffer (current-buffer) (input 0))
              (let ((candidate (ebox-candidate-begin (current-buffer))))
                (ebox-candidate-replace-host-ref
                 candidate 'row-0
                 (ebox-owner-style-test--canonical (ebox-owner-style-test--row 0 1)))
                (ebox-candidate-replace-host-ref
                 candidate 'album
                 (ebox-owner-style-test--canonical (ebox-owner-style-test--album 1)))
                (ebox-commit (current-buffer) candidate))
              (should-not (plist-get (ebox-buffer-update-report (current-buffer))
                                     :projection-kind))
              (ebox-owner-style-test--check (input 1)))
          (ebox-unmount-buffer (current-buffer)))))))

(ert-deftest ebox-owner-style-scroll-content-recomposes-paint ()
  "Content-only cached text changes rebuild paint in a retained owner slot."
  (let ((ebox-native-reflow-module-path nil)
        (ebox-viewport-width 40) (ebox-viewport-height 8))
    (cl-labels
        ((album (label)
           `(album box (:width stretch :height (lh 1) :overflow hidden
                         :background-color "#cccccc") nil
              (album-label text nil nil ,label)))
         (input (selected label)
           (ebox-owner-style-test--canonical
            `(root column (:width (ch 40) :height (lh 8) :color "#123456"
                           :background-color "#eeeeee") nil
               ,(ebox-owner-style-test--row 0 selected)
               (scroll column (:width (ch 40) :height (lh 3) :overflow scroll) nil
                ,(album label)
                ,@(cl-loop for index below 6
                           collect `(,(intern (format "tail-%d" index)) text nil nil "Tail")))))))
      (with-temp-buffer
        (unwind-protect
            (progn
              (ebox-render-to-buffer (current-buffer) (input 0 "Album"))
              (dolist (case '((1 "Longer album name") (0 "X") (1 "Album")))
                (pcase-let ((`(,selected ,label) case)
                            (candidate (ebox-candidate-begin (current-buffer))))
                  (ebox-candidate-replace-host-ref
                   candidate 'row-0
                   (ebox-owner-style-test--canonical (ebox-owner-style-test--row 0 selected)))
                  (ebox-candidate-replace-host-ref
                   candidate 'album (ebox-owner-style-test--canonical (album label)))
                  (ebox-commit (current-buffer) candidate)
                  (ebox-owner-style-test--local-report)
                  (ebox-owner-style-test--check (input selected label)))))
          (ebox-unmount-buffer (current-buffer)))))))

(ert-deftest ebox-native-plan-declines-intrinsic-and-stretch-heights ()
  "Unchanged descendant heights are checked before native frame execution."
  (skip-unless (ebox-native-reflow-layout-ready-p))
  (let ((ebox-viewport-width 40) (ebox-viewport-height 8))
    (dolist (property '(:height :min-height :max-height))
      (dolist (height '(stretch min-content max-content fit-content))
        (cl-labels
            ((pane (size)
               `(pane column (,property ,size) nil
                  (child text nil nil "Retained")))
             (input (label size)
               (ebox-owner-style-test--canonical
                `(root column (:width stretch :height (lh 6)) nil
                   (label-a text nil nil ,label)
                   (label-b text nil nil ,label)
                   (label-c text nil nil ,label) ,(pane size))))
             (change (label &optional size)
               (let ((candidate (ebox-candidate-begin (current-buffer))))
                 (dolist (ref '(label-a label-b label-c))
                   (ebox-candidate-replace-host-ref
                    candidate ref
                    (ebox-owner-style-test--canonical `(,ref text nil nil ,label))))
                 (when size
                   (ebox-candidate-replace-host-ref
                    candidate 'pane (ebox-owner-style-test--canonical (pane size))))
                 (ebox-commit (current-buffer) candidate))))
          (with-temp-buffer
            (unwind-protect
                (progn
                  (ebox-render-to-buffer (current-buffer) (input "Before" height))
                  (ebox-rerender-buffer-with-context (current-buffer) 40 8)
                  (change "After")
                  (let ((report (ebox-buffer-update-report (current-buffer))))
                    (should-not (eq (plist-get report :projection-kind) 'native-frame))
                    (should-not (plist-get report :native-attempt))
                    (should-not (plist-get report :native-fallback-reason)))
                  (ebox-owner-style-test--check (input "After" height))
                  ;; Horizontal stretch stays native-capable once the vertical
                  ;; dimension returns to the compiler's supported subset.
                  (let ((size (pcase property
                                (:height '(lh 2)) (:max-height 'none) (_ 'auto))))
                    (change "Native" size)
                    (let ((report (ebox-buffer-update-report (current-buffer))))
                      (ert-info ((format "%S %S: %S" property height report))
                        (should (eq (plist-get report :projection-kind) 'native-frame))))
                    (ebox-owner-style-test--check (input "Native" size))))
              (ebox-unmount-buffer (current-buffer)))))))))

(defun ebox-owner-style-test--replacement (variant &optional height)
  "Describe a list with new child identities for VARIANT and optional HEIGHT."
  `(records column (:width (ch 40) :background-color "#ddeeff") nil
     (,(intern (format "first-%s" variant)) box
      (:width stretch :height ,(or height '(lh 1))
       :color ,(if (eq variant 'a) "#112233" "#992244"))
      (:help-echo ,(symbol-name variant))
      (,(intern (format "first-text-%s" variant)) text nil nil
       ,(if (eq variant 'a) "Alpha" "中文 replacement")))
     (,(intern (format "second-%s" variant)) box
      (:width stretch :height (lh 1)) nil
      (,(intern (format "second-text-%s" variant)) text nil nil
       ,(if (eq variant 'a) "Bravo" "Delta")))))

(defun ebox-owner-style-test--replacement-input (variant &optional height)
  "Build a list VARIANT of HEIGHT between two unchanged owners."
  (ebox-owner-style-test--canonical
   `(root column (:width (ch 40) :color "#334455"
                  :background-color "#eeeeee") nil
      (heading text nil nil "Heading")
      ,(ebox-owner-style-test--replacement variant height)
      (footer box (:width stretch :height (lh 1))
       (:help-echo "Retained footer")
       (footer-text text nil nil "Footer")))))

(defun ebox-owner-style-test--replace-children (variant &optional height)
  "Prepare a new child list VARIANT of HEIGHT for the mounted records owner."
  (let ((candidate (ebox-candidate-begin (current-buffer))))
    (ebox-candidate-replace-host-ref
     candidate 'records
     (ebox-owner-style-test--canonical
      (ebox-owner-style-test--replacement variant height)))
    candidate))

(ert-deftest ebox-same-size-child-replacement-publishes-scoped ()
  "New child identities replace one owner's lines, with atomic rollback."
  (let ((ebox-native-reflow-module-path nil))
    (with-temp-buffer
      (unwind-protect
          (progn
            (ebox-render-to-buffer
             (current-buffer) (ebox-owner-style-test--replacement-input 'a))
            (let* ((footer (ebox-region-resolve (current-buffer) "footer"))
                   (footer-geometry (ebox-region-geometry footer)))
              (dolist (variant '(b a b))
                (let ((before (buffer-string))
                      (revision (ebox-surface-buffer-revision (current-buffer)))
                      reached-publication)
                  (should-error
                   (ebox-commit
                    (current-buffer)
                    (ebox-owner-style-test--replace-children variant)
                    (lambda (_report)
                      (setq reached-publication t)
                      (error "Reject replacement"))))
                  (should reached-publication)
                  (should (= revision (ebox-surface-buffer-revision (current-buffer))))
                  (should (equal-including-properties before (buffer-string))))
                (ebox-commit (current-buffer)
                             (ebox-owner-style-test--replace-children variant))
                (ebox-owner-style-test--local-report)
                (let ((report (ebox-buffer-update-report (current-buffer))))
                  (should (eq (plist-get report :strategy) 'span-patch))
                  (should (= (plist-get report :dirty-count) 1))
                  (should (= (plist-get report :patch-count) 1)))
                (should (equal footer-geometry (ebox-region-geometry footer)))
                (should (ebox-selector-query-buffer
                         (current-buffer) (format "#first-%s" variant)))
                (should (ebox-region-geometry
                         (ebox-region-resolve
                          (current-buffer) (format "first-%s" variant))))
                (should-not (ebox-selector-query-buffer
                             (current-buffer)
                             (format "#first-%s" (if (eq variant 'a) 'b 'a))))
                (ebox-owner-style-test--check
                 (ebox-owner-style-test--replacement-input variant)))))
        (ebox-unmount-buffer (current-buffer))))))

(ert-deftest ebox-child-replacement-validates-exterior-size ()
  "Equal child counts cannot authorize a replacement that grows the owner."
  (let ((ebox-native-reflow-module-path nil))
    (with-temp-buffer
      (unwind-protect
          (progn
            (ebox-render-to-buffer
             (current-buffer) (ebox-owner-style-test--replacement-input 'a))
            (ebox-commit (current-buffer)
                         (ebox-owner-style-test--replace-children 'b '(lh 2)))
            (should-not (plist-get (ebox-buffer-update-report (current-buffer))
                                   :projection-kind))
            (ebox-owner-style-test--check
             (ebox-owner-style-test--replacement-input 'b '(lh 2))))
        (ebox-unmount-buffer (current-buffer))))))

(defun ebox-owner-style-test--nav (index selected &optional sizing width)
  "Describe entry INDEX for SELECTED with optional SIZING and WIDTH."
  `(,(intern (format "nav-%d" index)) flex
    (:width ,(or width 'stretch) :height (lh 2)
     :box-sizing ,(or sizing 'border-box)
     :align-items center :padding-inline (ch 1)
     :font-weight ,(if (= index selected) 'bold 'normal)
     :color ,(if (= index selected) "#ff1122" "#445566")
     :background-color ,(if (= index selected) "#eedddd" "#dddddd")
     ,@(when (= index selected) '(:border-left ((px 1) solid "#ff1122"))))
    (:help-echo ,(if (= index selected) "Selected entry" "Choose entry"))
    (,(intern (format "glyph-%d" index)) box (:width (ch 3) :height (lh 1)) nil
     (,(intern (format "glyph-text-%d" index)) text nil nil "♫"))
    (,(intern (format "nav-label-%d" index)) box
     (:flex-grow 1 :flex-basis (px 0) :min-width (ch 0)
      :height (lh 1) :overflow hidden) nil
     (,(intern (format "nav-text-%d" index)) text nil nil
      ,(if (= index 0) "Daily" "收藏")))))

(defun ebox-owner-style-test--caption (selected)
  "Describe a small allocated caption for SELECTED."
  `(caption column (:flex-grow 1 :flex-basis (px 0) :min-width (ch 0)) nil
     (caption-title text (:font-weight bold) nil
      ,(if (= selected 0) "Daily" "收藏音乐"))
     (caption-subtitle box (:height (lh 1) :overflow hidden) nil
      (caption-detail text nil nil
       ,(if (= selected 0) "Your daily recommendations" "Saved tracks")))))

(defun ebox-owner-style-test--section-input (selected)
  "Build sidebar restyles and a sibling caption for SELECTED."
  (ebox-owner-style-test--canonical
   `(root flex (:width (ch 80) :height (lh 10) :overflow hidden
                :background-color "#eeeeee") nil
      (sidebar column (:width (ch 24) :height (lh 10)) nil
       ,(ebox-owner-style-test--nav 0 selected)
       ,(ebox-owner-style-test--nav 1 selected))
      (main column (:flex-grow 1 :flex-basis (px 0) :min-width (ch 0)
                    :height (lh 10)) nil
       (header flex (:width stretch :height (lh 2)) nil
        ,(ebox-owner-style-test--caption selected)
        (action box (:width (ch 8) :height (lh 1)) nil
         (action-text text nil nil "Refresh")))
       (records box (:width stretch :height (lh 4)) (:help-echo "Stable list")
        (records-text text nil nil "Unchanged records"))))))

(defun ebox-owner-style-test--section-candidate (selected)
  "Replace the two navigation entries and caption with SELECTED."
  (let ((candidate (ebox-candidate-begin (current-buffer))))
    (dotimes (index 2)
      (ebox-candidate-replace-host-ref
       candidate (intern (format "nav-%d" index))
       (ebox-owner-style-test--canonical (ebox-owner-style-test--nav index selected))))
    (ebox-candidate-replace-host-ref
     candidate 'caption
     (ebox-owner-style-test--canonical (ebox-owner-style-test--caption selected)))
    candidate))

(ert-deftest ebox-owner-border-restyle-keeps-column-slot ()
  "An owner's border, paint and inherited font can change its internal roles."
  (let ((ebox-native-reflow-module-path nil))
    (cl-labels ((input (selected)
                 (ebox-owner-style-test--canonical
                  `(root column (:width (ch 24)) nil
                     ,(ebox-owner-style-test--nav 0 selected)
                     (peer text nil nil "Unchanged peer")))))
      (with-temp-buffer
        (unwind-protect
            (progn
              (ebox-render-to-buffer (current-buffer) (input 1))
              (dolist (selected '(0 1 0))
                (let ((candidate (ebox-candidate-begin (current-buffer))))
                  (ebox-candidate-replace-host-ref
                   candidate 'nav-0
                   (ebox-owner-style-test--canonical
                    (ebox-owner-style-test--nav 0 selected)))
                  (ebox-commit (current-buffer) candidate))
                (ebox-owner-style-test--local-report)
                (should (= 1 (plist-get (ebox-buffer-update-report (current-buffer))
                                       :patch-count)))
                (ebox-owner-style-test--check (input selected))))
          (ebox-unmount-buffer (current-buffer)))))))

(ert-deftest ebox-section-restyles-and-header-publish-disjoint-scopes ()
  "Sidebar border restyles and variable caption text stay local and atomic."
  (let ((ebox-native-reflow-module-path nil))
    (with-temp-buffer
      (unwind-protect
          (progn
            (ebox-render-to-buffer (current-buffer)
                                   (ebox-owner-style-test--section-input 0))
            (let* ((peer (ebox-region-resolve (current-buffer) "records"))
                   (geometry (ebox-region-geometry peer)))
              (dolist (selected '(1 0 1))
                (let ((before (buffer-string))
                      (revision (ebox-surface-buffer-revision (current-buffer)))
                      (report (ebox-buffer-update-report (current-buffer)))
                      accepted)
                  (should-error
                   (ebox-commit
                    (current-buffer) (ebox-owner-style-test--section-candidate selected)
                    (lambda (_report) (setq accepted t) (error "Reject section"))))
                  (should accepted)
                  (should (= revision (ebox-surface-buffer-revision (current-buffer))))
                  (should (equal report (ebox-buffer-update-report (current-buffer))))
                  (should (equal-including-properties before (buffer-string))))
                (ebox-commit (current-buffer)
                             (ebox-owner-style-test--section-candidate selected))
                (ebox-owner-style-test--local-report)
                (should (= 3 (plist-get (ebox-buffer-update-report (current-buffer))
                                       :patch-count)))
                (should (equal geometry (ebox-region-geometry peer)))
                (ebox-owner-style-test--check
                 (ebox-owner-style-test--section-input selected)))))
        (ebox-unmount-buffer (current-buffer))))))

(ert-deftest ebox-owner-border-restyle-declines-changing-exterior ()
  "An intrinsic or content-box border cannot freeze a neighbouring Row slot."
  (let ((ebox-native-reflow-module-path nil))
    (dolist (sizing-width '((content-box (ch 12)) (border-box max-content)))
      (pcase-let ((`(,sizing ,width) sizing-width))
        (cl-labels ((input (selected)
                     (ebox-owner-style-test--canonical
                      `(root row (:width (ch 40)) nil
                         ,(ebox-owner-style-test--nav 0 selected sizing width)
                         (peer box (:width (ch 8)) nil
                          (peer-text text nil nil "Peer"))))))
          (with-temp-buffer
            (unwind-protect
                (progn
                  (ebox-render-to-buffer (current-buffer) (input 1))
                  (let* ((before (buffer-string))
                         (peer-start (ebox-string-pixel-width
                                      (substring before 0 (string-match "Peer" before))))
                         (candidate (ebox-candidate-begin (current-buffer))))
                    (ebox-candidate-replace-host-ref
                     candidate 'nav-0
                     (ebox-owner-style-test--canonical
                      (ebox-owner-style-test--nav 0 0 sizing width)))
                    (ebox-commit (current-buffer) candidate)
                    ;; The border really changes the Row allocation: keeping
                    ;; the old slot would leave the peer at the wrong pixel.
                    (let ((after (buffer-string)))
                      (should (> (ebox-string-pixel-width
                                  (substring after 0 (string-match "Peer" after)))
                                 peer-start))))
                  (should-not (plist-get (ebox-buffer-update-report (current-buffer))
                                         :projection-kind))
                  (ebox-owner-style-test--check (input 0)))
              (ebox-unmount-buffer (current-buffer)))))))))

(provide 'ebox-owner-style-tests)
;;; ebox-owner-style-tests.el ends here
