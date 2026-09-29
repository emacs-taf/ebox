;;; ebox-host-property-tests.el --- Composable Host updates -*- lexical-binding: t; -*-

;;; Commentary:
;; Framework property updates retain content, children and public addresses.
;; Compare published output with a fresh canonical render, independently of
;; the projection strategy chosen by Ebox.

;;; Code:
(require 'ert)
(require 'ebox)

(defun ebox-host-property-test--input (&rest specs)
  "Build SPECS of (REF TAG STYLE INTERACTIONS CONTENT &optional CLASS RULES).
CONTENT is text or child specs; (:range REF SPEC...) describes a child Range."
  (let ((builder (ebox-source-builder-create)))
    (cl-labels
        ((node (spec)
           (if (eq (car spec) :range)
               (apply #'ebox-child-range (cadr spec) (mapcar #'node (cddr spec)))
             (pcase-let* ((`(,ref ,tag ,style ,interactions ,content . ,rest) spec)
                          (declarations (ebox-style-compile-form tag style))
                          (handle (ebox-source-builder-bind
                                   builder :identity ref :key ref :id ref
                                   :class (car rest) :interactions interactions
                                   :ecss (ebox-style-compile-rules (cadr rest))
                                   :declarations declarations))
                          (facts (ebox-canonical-facts-from-declarations
                                  tag declarations interactions)))
               (if (eq tag 'text)
                   (ebox-text-create :value content :source-handle handle
                                     :owned-facts facts)
                 (apply #'ebox-box-create
                        (append
                         (ebox-canonical-box-configuration tag declarations)
                         (list :source-handle handle :owned-facts facts
                               :source-builder builder
                               :children (mapcar #'node content)))))))))
      (let ((roots (mapcar #'node specs)))
        (ebox-canonical-input-create roots (ebox-source-builder-finish builder))))))

(defun ebox-host-property-test--visible (text)
  "Return observable content, geometry, paint and help from rendered TEXT."
  (list (substring-no-properties text)
        (cl-loop for position below (length text)
                 collect (mapcar (lambda (property)
                                   (get-text-property position property text))
                                 '(face display help-echo pointer mouse-face)))))

(defun ebox-host-property-test--matches (input)
  "Assert the current buffer and its exported snapshot render like INPUT."
  (let ((expected (ebox-host-property-test--visible (ebox-render input))))
    (should (equal expected (ebox-host-property-test--visible (buffer-string))))
    (should
     (equal expected
            (ebox-host-property-test--visible
             (ebox-render (plist-get (ebox-surface-buffer-snapshot
                                      (current-buffer)) :input)))))))

(ert-deftest ebox-host-properties-compose-layout-interaction-and-content ()
  "Layout, native bindings and child content change through one candidate."
  (dolist (tag '(column row flex grid))
    (let* ((clicks 0)
           (keymap (ebox-keymap-create :activate (lambda () (cl-incf clicks))))
           (initial '(panel column (:width (ch 28)) nil
                            ((message text nil nil "Before"))))
           (previous (ebox-host-property-test--input initial)))
      (with-temp-buffer
        (ebox-render-to-buffer (current-buffer) previous)
        (let ((handle (ebox-region-resolve (current-buffer) "message")))
          (dolist (enabled '(nil t))
            (let* ((style (when (not enabled)
                            '(:width (ch 16) :padding ((lh 1) (ch 2))
                                     :color "red")))
                   (interactions (list :keymap keymap :tab-index 0
                                       :disabled (not enabled)
                                       :help-echo (if enabled "Ready" "Busy")))
                   (next (ebox-host-property-test--input
                          `(panel ,tag ,style ,interactions
                                  ((ignored text nil nil "Ignored")))))
                   (candidate (ebox-candidate-begin (current-buffer))))
              (should (eq candidate
                          (ebox-candidate-update-host-properties
                           candidate 'panel previous next)))
              (ebox-candidate-replace-host-ref
               candidate 'message
               (ebox-host-property-test--input '(message text nil nil "After")))
              (ebox-commit (current-buffer) candidate)
              (ebox-host-property-test--matches
               (ebox-host-property-test--input
                `(panel ,tag ,style ,interactions ((message text nil nil "After")))))
              (ebox-region-update handle :content "After")
              (ebox-activate (ebox-host-ref-position (current-buffer) 'message) t)
              (should (= clicks (if enabled 1 0)))
              (setq previous next))))))))

(ert-deftest ebox-host-properties-compose-with-range-reorder ()
  "A parent property update retains a reordered Range and child addresses."
  (dolist (properties-first '(nil t))
    (let* ((before (ebox-host-property-test--input
                    '(panel column (:width (ch 24)) nil
                            ((:range rows (a text nil (:tab-index 0) "A")
                                     (b text nil nil "B"))))))
           (next (ebox-host-property-test--input
                  '(panel column (:width (ch 12) :color "blue") nil nil))))
      (with-temp-buffer
        (ebox-render-to-buffer (current-buffer) before)
        (ebox-focus 'a)
        (let ((handle (ebox-region-resolve (current-buffer) "a"))
              (candidate (ebox-candidate-begin (current-buffer))))
          (when properties-first
            (ebox-candidate-update-host-properties candidate 'panel before next))
          (ebox-candidate-replace-range-ref
           candidate 'rows
           (ebox-host-property-test--input
            '(b text nil nil "B2") '(a text nil (:tab-index 0) "A2")))
          (unless properties-first
            (ebox-candidate-update-host-properties candidate 'panel before next))
          (ebox-commit (current-buffer) candidate)
          (should (eq 'a (ebox-focused-host-ref)))
          (ebox-host-property-test--matches
           (ebox-host-property-test--input
            '(panel column (:width (ch 12) :color "blue") nil
                    ((:range rows (b text nil nil "B2")
                             (a text nil (:tab-index 0) "A2"))))))
          (ebox-region-update handle :content "A2"))))))

(ert-deftest ebox-host-properties-inherit-into-replaced-styled-subtrees ()
  "An inherited property update composes with replaced items that own styled children.

The replaced Range items are Boxes whose children carry their own author
declarations, so the inherited color must reach every new leaf while the
publication stays consistent."
  (dolist (properties-first '(nil t))
    (let* ((before (ebox-host-property-test--input
                    '(panel column (:width (ch 24)) nil
                            ((:range rows
                                     (a row (:padding-left (ch 1)) nil
                                        ((a1 text (:font-weight bold) nil "A1")
                                         (a2 text (:font-weight bold) nil "A2")))
                                     (b row (:padding-left (ch 1)) nil
                                        ((b1 text (:font-weight bold) nil "B1"))))))))
           (next (ebox-host-property-test--input
                  '(panel column (:width (ch 24) :color "blue") nil nil)))
           (items '((b row (:padding-left (ch 2)) nil
                       ((b1 text (:font-weight bold) nil "B1")
                        (b2 text (:font-weight bold) nil "B2")))
                    (a row (:padding-left (ch 2)) nil
                       ((a1 text (:font-weight bold) nil "A1"))))))
      (with-temp-buffer
        (ebox-render-to-buffer (current-buffer) before)
        (let ((candidate (ebox-candidate-begin (current-buffer))))
          (when properties-first
            (ebox-candidate-update-host-properties candidate 'panel before next))
          (ebox-candidate-replace-range-ref
           candidate 'rows (apply #'ebox-host-property-test--input items))
          (unless properties-first
            (ebox-candidate-update-host-properties candidate 'panel before next))
          (ebox-commit (current-buffer) candidate)
          (ebox-host-property-test--matches
           (ebox-host-property-test--input
            (list 'panel 'column '(:width (ch 24) :color "blue") nil
                  (list (append '(:range rows) items))))))))))

(ert-deftest ebox-host-properties-preserve-text-and-structural-ownership ()
  "Property updates refine retained owners and cannot resurrect removed owners."
  (dolist (operation '(content parent remove root))
    (with-temp-buffer
      (let* ((before (ebox-host-property-test--input
                      '(outer column nil nil
                              ((panel column nil nil ((a text nil nil "Before")))))))
             (next (ebox-host-property-test--input
                    '(a text (:color "red") (:help-echo "New") "Ignored"))))
        (ebox-render-to-buffer (current-buffer) before)
        (let ((candidate (ebox-candidate-begin (current-buffer))))
          (ebox-candidate-update-host-properties candidate 'a before next)
          (pcase operation
            ('content
             (ebox-candidate-replace-host-ref
              candidate 'a (ebox-host-property-test--input '(a text nil nil "After"))))
            ((or 'parent 'remove)
             (ebox-candidate-replace-host-ref
              candidate 'panel
              (ebox-host-property-test--input
               `(panel column nil nil ,(when (eq operation 'parent)
                                         '((a text nil nil "After")))))))
            ('root
             (ebox-candidate-replace-root
              candidate (ebox-host-property-test--input
                         '(outer column nil nil
                                 ((panel column nil nil ((a text nil nil "After")))))))))
          (ebox-commit (current-buffer) candidate)
          (ebox-host-property-test--matches
           (ebox-host-property-test--input
            `(outer column nil nil
                    ((panel column nil nil
                            ,(pcase operation
                               ('remove nil)
                               ('root '((a text nil nil "After")))
                               (_ '((a text (:color "red") (:help-echo "New") "After"))))))))))))))

(ert-deftest ebox-host-properties-update-selector-facts-and-rules ()
  "Rule and class changes restyle retained descendants without new child input."
  (cl-labels ((input (class rules &optional empty)
                (ebox-host-property-test--input
                 `(panel column (:width (ch 24)) nil
                         ,(unless empty '((a text nil nil "Retained")))
                         ,class ,rules))))
    (let ((previous (input nil nil)))
      (with-temp-buffer
        (ebox-render-to-buffer (current-buffer) previous)
        (dolist (step '(("accent" (("&.accent text" :color "red")))
                        (nil (("&.accent text" :color "red")))
                        ("accent" (("&.accent text" :color "blue")))
                        ("accent" nil)))
          (let* ((next (input (car step) (cadr step) t))
                 (candidate (ebox-candidate-begin (current-buffer))))
            (ebox-candidate-update-host-properties candidate 'panel previous next)
            (ebox-commit (current-buffer) candidate)
            (ebox-host-property-test--matches (apply #'input step))
            (setq previous next)))))))

(ert-deftest ebox-host-properties-classify-positioned-effects-and-rollback ()
  "Computed positioning changes preserve geometry work, hits and rollback."
  (dolist (change '((:left (ch 1) (ch 5))
                    (:top (lh 1) (lh 4))
                    (:position absolute static)
                    (:z-index 2 -1)
                    (:layer local root)
                    (:anchor nil anchor-a)
                    (:placement bottom-start top-start)))
    (let* ((activated nil)
           (target-map (ebox-keymap-create
                        :activate (lambda () (setq activated 'target))))
           (base-map (ebox-keymap-create
                      :activate (lambda () (setq activated 'base))))
           (key (car change))
           (before-style
            (plist-put
             (list :position 'absolute :left '(ch 1) :top '(lh 1)
                   :width '(ch 4) :height '(lh 1) :z-index 2 :layer 'local
                   :anchor (when (eq key :placement) 'anchor-a)
                   :placement 'bottom-start)
             key (cadr change)))
           (after-style (plist-put (copy-tree before-style) key (caddr change))))
      (cl-labels
          ((target (style)
             `(target box ,style (:keymap ,target-map)
                      ((target-text text nil nil "MOVE"))))
           (scene (style)
             (ebox-host-property-test--input
              `(root box (:position relative :width (ch 16) :height (lh 8)) nil
                     ((heading text nil nil "HEADER")
                      (host box (:position relative :width (ch 16) :height (lh 7)) nil
                            ((under box (:position absolute :width (ch 16)
                                                   :height (lh 7) :z-index 0)
                                    (:keymap ,base-map)
                                    ((under-text text nil nil
                                                 "0123456789ABCDEF\n0123456789ABCDEF\n0123456789ABCDEF\n0123456789ABCDEF\n0123456789ABCDEF\n0123456789ABCDEF\n0123456789ABCDEF")))
                             (anchor-a box (:position absolute :left (ch 2)
                                                      :top (lh 2) :width (ch 4)
                                                      :height (lh 1) :z-index 1)
                                       (:keymap ,base-map)
                                       ((anchor-text text nil nil "BASE")))
                             ,(target style)))))))
           (candidate (previous next)
             (let ((candidate (ebox-candidate-begin (current-buffer))))
               (ebox-candidate-update-host-properties
                candidate 'target previous next)
               candidate)))
        (with-temp-buffer
          (let* ((previous (scene before-style))
                 (next (ebox-host-property-test--input (target after-style))))
            (ebox-render-to-buffer (current-buffer) previous)
            (ebox-buffer-set-observer (current-buffer) (lambda (_buffer _report)))
            (let ((accepted (ebox-host-property-test--visible (buffer-string)))
                  (revision (plist-get (ebox-surface-buffer-snapshot
                                        (current-buffer)) :revision)))
              (should-error
               (ebox-commit (current-buffer) (candidate previous next)
                            (lambda (_report) (error "Reject positioned update"))))
              (should (equal accepted
                             (ebox-host-property-test--visible (buffer-string))))
              (should (= revision (plist-get (ebox-surface-buffer-snapshot
                                              (current-buffer)) :revision)))
              (ebox-activate (ebox-host-ref-position (current-buffer) 'target) t)
              (should (eq activated 'target)))
            (ebox-commit (current-buffer) (candidate previous next))
            (let ((report (ebox-buffer-update-report (current-buffer))))
              (ert-info ((format "Positioned property %S: %S" key report))
                (should (memq 'geometry (plist-get report :dirty-kinds)))
                (should (memq key (plist-get report :dirty-keys)))))
            (ebox-host-property-test--matches (scene after-style))
            (setq activated nil)
            (goto-char (point-min))
            (if (search-forward "MOVE" nil t)
                (progn
                  (ebox-activate (- (point) 4) t)
                  (should (eq activated 'target)))
              (should (eq key :z-index))
              (goto-char (point-min))
              (should (search-forward "0123" nil t))
              (ebox-activate (- (point) 4) t)
              (should (eq activated 'base)))
            ;; Repeating the exact author value creates no geometry effect.
            (ebox-commit (current-buffer) (candidate next next))
            (should-not (memq 'geometry
                              (plist-get (ebox-buffer-update-report (current-buffer))
                                         :dirty-kinds)))
            (ebox-host-property-test--matches (scene after-style))))))))

(ert-deftest ebox-host-properties-classify-computed-container-effects ()
  "Selector-driven frame and LayoutConfig changes publish their computed effects."
  (dolist (case '((box :left (ch 0) (ch 4)
                      (:position relative :width (ch 24) :height (lh 3)))
                  (flex :justify-content flex-start flex-end
                        (:width (ch 24) :height (lh 3)))
                  (grid :grid-template-columns ((ch 4) (ch 4)) ((ch 8) (ch 4))
                        (:width (ch 24) :height (lh 3)))))
    (pcase-let ((`(,tag ,key ,old-value ,new-value ,style) case))
      (cl-labels
          ((input (class &optional omit-children)
             (ebox-host-property-test--input
              `(root box (:width (ch 32) :height (lh 5)) nil
                     ((panel ,tag ,style nil
                             ,(unless omit-children
                                '((first box (:width (ch 4)) nil
                                         ((first-text text nil nil "AAAA")))
                                  (second box (:width (ch 4)) nil
                                          ((second-text text nil nil "BBBB")))))
                             ,class (("&" ,key ,old-value)
                                     ("&.shift" ,key ,new-value))))))))
        (with-temp-buffer
          (let* ((previous (input nil))
                 (next (input "shift" t))
                 (candidate nil)
                 (before nil))
            (ebox-render-to-buffer (current-buffer) previous)
            (setq before (ebox-host-property-test--visible (buffer-string)))
            (ebox-buffer-set-observer (current-buffer) (lambda (_buffer _report)))
            (setq candidate (ebox-candidate-begin (current-buffer)))
            (ebox-candidate-update-host-properties candidate 'panel previous next)
            (ebox-commit (current-buffer) candidate)
            (let ((report (ebox-buffer-update-report (current-buffer))))
              (ert-info ((format "Computed property %S: %S" key report))
                (should (memq 'geometry (plist-get report :dirty-kinds)))
                (should (memq key (plist-get report :dirty-keys)))))
            (should-not (equal before
                               (ebox-host-property-test--visible (buffer-string))))
            (ebox-host-property-test--matches (input "shift"))))))))

(ert-deftest ebox-host-properties-replace-positioned-subtrees-through-occlusion ()
  "Local and root-layer replacements preserve occlusion, identity and rollback."
  (dolist (portal '(nil t))
    (dolist (relative '(nil t))
      (let ((activated nil)
            (background "BACKGROUND\nBACKGROUND\nBACKGROUND\nBACKGROUND\nBACKGROUND\nBACKGROUND\nBACKGROUND\nBACKGROUND\nBACKGROUND\nBACKGROUND\nBACKGROUND\nBACKGROUND")
            (maps (make-vector 5 nil)))
	(dotimes (index 5)
          (let ((value index))
            (aset maps index (ebox-keymap-create
                              :activate (lambda () (setq activated value))))))
	(cl-labels
            ((panel (count height)
               `(panel column (:position absolute :layer ,(if portal 'root 'local)
					 :left (ch 2) :top (lh 1) :width (ch 12)
					 :height (lh ,height) :z-index 10
					 :background-color "blue" :overflow scroll)
                       nil
                       ,(cl-loop for index below count
				 collect `(,(intern (format "item-%d" index)) text nil
                                           (:keymap ,(aref maps index))
                                           ,(format "ITEM%d" index)))))
             (scene (count height)
               (ebox-host-property-test--input
		`(root box (:width (ch 30) :height (lh 12) :overflow hidden) nil
                       (,(if relative
                             `(base box (:position relative :left (ch 1)
                                                   :width (ch 29) :height (lh 12)) nil
						   ((base-text text nil nil ,background)))
                           `(base text nil nil ,background))
			,(if portal
                             `(host box (:height (lh 0) :overflow visible) nil
                                    (,(panel count height)))
                           (panel count height))
			(overlay box (:position absolute :left (ch 8) :top (lh 2)
						:width (ch 5) :height (lh 2) :z-index 20)
				 nil ((overlay-text text nil nil "OVER!\nOVER!")))))))
             (candidate (count height)
               (let ((value (ebox-candidate-begin (current-buffer))))
		 (ebox-candidate-replace-host-ref
                  value 'panel (ebox-host-property-test--input (panel count height)))
		 value)))
          (with-temp-buffer
            (ebox-render-to-buffer (current-buffer) (scene 2 3))
            (dolist (step '((5 6) (5 3) (1 2) (4 5)))
              (let ((accepted (ebox-host-property-test--visible (buffer-string)))
                    (revision (plist-get (ebox-surface-buffer-snapshot
                                          (current-buffer)) :revision))
                    (position (ebox-host-ref-position (current-buffer) 'item-0)))
		(should-error
		 (ebox-commit (current-buffer) (apply #'candidate step)
                              (lambda (_report) (error "Reject panel replacement"))))
		(should (equal accepted
                               (ebox-host-property-test--visible (buffer-string))))
		(should (= revision (plist-get (ebox-surface-buffer-snapshot
						(current-buffer)) :revision)))
		(should (= position (ebox-host-ref-position (current-buffer) 'item-0)))
		(setq activated nil)
		(ebox-activate position t)
		(should (eql activated 0)))
              (ebox-commit (current-buffer) (apply #'candidate step))
              (ebox-host-property-test--matches (apply #'scene step))
              (goto-char (point-min))
              (should (search-forward "OVER!" nil t))
              (setq activated nil)
              (ebox-activate (ebox-host-ref-position (current-buffer) 'item-0) t)
              (should (eql activated 0))
              (when (= (car step) 1)
		(should-not (ebox-host-ref-position (current-buffer) 'item-4))))))))))

(ert-deftest ebox-host-properties-replace-styled-panel-after-native-press ()
  "Metadata, rejected structural updates and later signals keep exact pixels."
  (let ((ebox-viewport-width 24) (ebox-viewport-height 10)
        (buffer (generate-new-buffer " *ebox-panel-metadata*"))
        (activated 0))
    (unwind-protect
        (save-window-excursion
          (set-window-buffer (selected-window) buffer)
          (with-current-buffer buffer
            (let ((keymap (ebox-keymap-create :activate (lambda () (cl-incf activated)))))
              (cl-labels
                  ((panel (count)
                     `(panel column (:position absolute :left (ch 0) :top (lh 0)
                                               :width (ch 10) :height (lh 5)
                                               :background-color "blue" :z-index 2)
                             nil ,(cl-loop for index below count
                                           collect `(,(intern (format "row-%d" index)) text nil
                                                     (:keymap ,keymap :tab-index 0)
                                                     ,(format "ROW%d" index)))))
                   (scene (count)
                     (ebox-host-property-test--input
                      `(root box (:width (vw 100) :height (lh 8) :overflow hidden) nil
                             (,(panel count)
                              (peer box (:position absolute :left (calc (- (% 100) (ch 10)))
                                         :top (lh 0) :width (ch 10) :height (lh 5)
                                         :overflow scroll :z-index 1) nil
                                    ((peer-text text nil nil "PEER0\nPEER1\nPEER2\nPEER3\nPEER4\nPEER5\nPEER6"))))
                             nil (("#panel text + text" :color "red")))))
                   (candidate ()
                     (let ((value (ebox-candidate-begin buffer)))
                       (ebox-candidate-replace-host-ref
                        value 'panel (ebox-host-property-test--input (panel 4)))
                       value)))
                (ebox-render-to-buffer buffer (scene 2))
                (should (ebox-geometry-prepare buffer 'panel [:left]))
                (let* ((position (ebox-host-ref-position buffer 'row-0))
                       (press (list 'down-mouse-1 (list (selected-window) position '(1 . 0) 0)))
                       (release (list 'mouse-1 (list (selected-window) position '(1 . 0) 1)))
                       (command (key-binding (vector press) nil nil position)))
                  (cl-letf (((symbol-function 'read-event)
                             (lambda (&rest _)
                               (should (ebox-selector-query-buffer buffer ":active"))
                               release)))
                    (funcall command press)))
                (should (= activated 1))
                (should-not (ebox-selector-query-buffer buffer ":active"))
                (let ((before (ebox-host-property-test--visible (buffer-string)))
                      (revision (ebox-surface-buffer-revision buffer)))
                  (should-error (ebox-commit buffer (candidate)
                                             (lambda (_report) (error "Reject styled panel"))))
                  (should (= revision (ebox-surface-buffer-revision buffer)))
                  (should (equal before
                                 (ebox-host-property-test--visible (buffer-string)))))
                (ebox-commit buffer (candidate))
                (ebox-host-property-test--matches (scene 4))
                (goto-char (point-min))
                (should (search-forward "PEER0" nil t))
                (backward-char 5)
                (ebox-scroll-down 1)
                (should (string-match-p "PEER1" (buffer-substring-no-properties
                                                (point-min) (point-max))))
                (ebox-host-property-test--matches
                 (plist-get (ebox-surface-buffer-snapshot buffer) :input))
                (ebox-rerender-buffer-with-context buffer 30 10)
                (setq ebox-viewport-width 30)
                (ebox-host-property-test--matches
                 (plist-get (ebox-surface-buffer-snapshot buffer) :input))))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-host-properties-change-root-layer-membership-with-peer-paint ()
  "Root layer insertion/removal and multiple panel paints share one exact commit."
  (cl-labels
      ((scene (open color)
         (ebox-host-property-test--input
          `(root box (:width (ch 24) :height (lh 8) :overflow hidden) nil
                 ((left box (:position absolute :left (ch 0) :top (lh 1)
                                       :width (ch 10) :height (lh 3) :z-index 1
                                       :background-color ,color)
                        nil ((left-text text nil nil "LEFT")))
                  (right box (:position absolute :left (ch 12) :top (lh 1)
                                        :width (ch 10) :height (lh 3) :z-index 2
                                        :background-color ,color)
                         nil ((right-text text nil nil "RIGHT")))
                  ,@(when open
                      '((dialog box (:position absolute :layer root :left (ch 6)
                                               :top (lh 2) :width (ch 12) :height (lh 4)
                                               :z-index 3 :background-color "white")
                                nil ((dialog-text text nil nil "DIALOG"))))))
                 nil (("box + box" :color "blue"))))))
    (with-temp-buffer
      (ebox-render-to-buffer (current-buffer) (scene nil "gray"))
      (dolist (step '((t "red") (nil "green") (t "yellow")))
        (let ((candidate (ebox-candidate-begin (current-buffer)))
              (next (apply #'scene step)))
          (ebox-candidate-replace-host-ref candidate 'root next)
          (ebox-commit (current-buffer) candidate)
          (ebox-host-property-test--matches next)
          (should (eq (and (ebox-host-ref-position (current-buffer) 'dialog) t)
                      (car step))))))))

(provide 'ebox-host-property-tests)
;;; ebox-host-property-tests.el ends here
