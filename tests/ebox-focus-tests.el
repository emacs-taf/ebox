;;; ebox-focus-tests.el --- Public focus behavior -*- lexical-binding: t; -*-

;;; Commentary:
;; Exercise focus through canonical input and supported mounted operations.

;;; Code:
(require 'ert)
(require 'ebox)

(defun ebox-focus-test--input (rows &optional unkeyed)
  "Build ROWS of (IDENTITY TEXT INTERACTIONS); UNKEYED omits sibling keys."
  (let* ((builder (ebox-source-builder-create))
         (root (ebox-source-builder-bind builder :identity 'root :key 'root))
         (children
          (mapcar
           (lambda (row)
             (let* ((ref (nth 0 row)) (text (nth 1 row)) (interactions (nth 2 row))
                    (handle (ebox-source-builder-bind
                             builder :identity ref :key (unless unkeyed ref) :id ref
                             :interactions interactions)))
               (ebox-text-create
                :value text :source-handle handle
                :owned-facts (ebox-canonical-facts-from-declarations
                              'text nil interactions)))) rows))
         (node (ebox-box-create
                :source-handle root :layout (ebox-column-layout-create)
                :children children
                :owned-facts (ebox-canonical-facts-from-declarations 'column nil))))
    (ebox-canonical-input-create (list node) (ebox-source-builder-finish builder))))

(ert-deftest ebox-focus-orders-declared-stops-and-controls-cycling ()
  "Navigation shares declared order, skips disabled nodes and fails atomically."
  (with-temp-buffer
    (ebox-render-to-buffer
     (current-buffer)
     (ebox-focus-test--input '((a "A" (:tab-index 2))
                               (b "B" (:tab-index 0))
                               (c "C" (:tab-index 1 :disabled t))
                               (d "D" (:tab-index -1))
                               (e "E" nil))))
    (should (eq (ebox-focus-next) 'b))
    (should (looking-at "B"))
    (should (eq (ebox-focus-next) 'a))
    (let ((before (point)))
      (should-error (ebox-focus-next) :type 'user-error)
      (should (= (point) before))
      (should (eq (ebox-focused-host-ref) 'a)))
    (should (eq (ebox-focus-next 1 t) 'b))
    (should (eq (ebox-focus-previous 1 t) 'a))
    (should (eq (ebox-focus 'd) 'd))
    (should (eq (ebox-focus-next) 'b))
    (should (eq (ebox-focus 'e) 'e))
    (should (eq (ebox-focus-previous) 'a))
    (should (eq (ebox-focus-first) 'b))
    (should (eq (ebox-focus-next) 'a))
    (should-error (ebox-focus 'c) :type 'user-error)
    (should-error (ebox-focus 'absent) :type 'user-error)
    (should (eq (ebox-focused-host-ref) 'a))
    (ebox-region-update (ebox-region-resolve (current-buffer) "a") :tab-index nil)
    (ebox-region-update (ebox-region-resolve (current-buffer) "b") :tab-index nil)
    (let ((before (point)))
      (should-error (ebox-focus-first) :type 'user-error)
      (should (eq (ebox-focused-host-ref) 'a))
      (should (= before (point))))
    (should-not (ebox-focus nil))
    (should-not (ebox-focus-next 0))
    (should-error (ebox-focus-next 1.5) :type 'wrong-type-argument)
    (should-error (ebox-build '(text :tab-index 0.5 "bad")))
    (should-error (ebox-build '(text :disabled yes "bad")))))

(ert-deftest ebox-focus-follows-publication-and-preserves-manual-point ()
  "Layout and keyed reorder retain focus, while manual point movement is respected."
  (with-temp-buffer
    (ebox-render-to-buffer
     (current-buffer)
     (ebox-focus-test--input '((a "A" (:tab-index 0)) (b "B" (:tab-index 0)))))
    (ebox-focus 'b)
    (ebox-commit
     (current-buffer)
     (ebox-focus-test--input '((b "B longer" (:tab-index 0)) (a "A" (:tab-index 0)))))
    (should (eq (ebox-focused-host-ref) 'b))
    (should (looking-at "B longer"))
    (goto-char (point-max))
    (ebox-commit
     (current-buffer)
     (ebox-focus-test--input '((a "A" (:tab-index 0)) (b "B longer" (:tab-index 0)))))
    (should (eq (ebox-focused-host-ref) 'b))
    (should (= (point) (point-max)))
    (ebox-focus 'b)
    (ebox-region-update (ebox-region-resolve (current-buffer) "a") :content "A\nA\nA")
    (should (looking-at "B longer"))
    (should (eq (ebox-focused-host-ref) 'b))))

(ert-deftest ebox-focus-rejection-removal-and-unmount-release-ownership ()
  "Rejected publication retains focus and point; removal or disable clears it."
  (with-temp-buffer
    (ebox-render-to-buffer
     (current-buffer)
     (ebox-focus-test--input '((a "A" (:tab-index 0)) (b "B" (:tab-index 0)))))
    (ebox-focus 'b)
    (let ((before (point)) (text (buffer-string)))
      (should-error
       (ebox-commit
        (current-buffer) (ebox-focus-test--input '((a "changed" (:tab-index 0))))
        (lambda (_report) (error "Reject focus removal"))))
      (should (equal (buffer-string) text))
      (should (= (point) before))
      (should (eq (ebox-focused-host-ref) 'b)))
    (ebox-region-update (ebox-region-resolve (current-buffer) "b") :disabled t)
    (should-not (ebox-focused-host-ref))
    (should (eq (ebox-focus-next) 'a))
    (ebox-commit (current-buffer) (ebox-focus-test--input '((b "B" (:tab-index 0)))))
    (should-not (ebox-focused-host-ref))
    (should (eq (ebox-focus-next) 'b))
    (ebox-unmount-buffer (current-buffer))
    (should-not (ebox-focused-host-ref))
    (should-error (ebox-focus 'b) :type 'user-error)
    (ebox-render-to-buffer (current-buffer) (ebox-focus-test--input '((b "B" (:tab-index 0)))))
    (should-not (ebox-focused-host-ref))))

(ert-deftest ebox-focus-respects-accessibility-and-buffer-isolation ()
  "Narrowing and invisible overlays affect navigation without changing other buffers."
  (let ((first (generate-new-buffer " *focus-first*"))
        (second (generate-new-buffer " *focus-second*"))
        (window (selected-window))
        (input (ebox-focus-test--input '((a "AAA" (:tab-index 0)) (b "BBB" (:tab-index 0))))))
    (unwind-protect
        (progn
          (ebox-render-to-buffer first input)
          (ebox-render-to-buffer second input)
          (ebox-focus 'a first)
          (ebox-focus 'b second)
          (should (eq (ebox-focused-host-ref first) 'a))
          (should (eq (ebox-focused-host-ref second) 'b))
          (with-current-buffer first
            (ebox-focus-next 0)
            (let* ((bounds (ebox-host-ref-bounds first 'b))
                   (overlay (make-overlay (car bounds) (cdr bounds))))
              (overlay-put overlay 'invisible t)
              (should (eq (ebox-focus-next 1 t) 'a))
              (should-error (ebox-focus 'b) :type 'user-error)
              (delete-overlay overlay)
              (should (eq (ebox-focus-next) 'b))
              (save-restriction
                (narrow-to-region (car bounds) (cdr bounds))
                (should-error (ebox-focus 'a) :type 'user-error)
                (should (eq (ebox-focus-next 1 t) 'b)))))
          (should (eq (selected-window) window))
          (kill-buffer first)
          (should-not (ebox-focused-host-ref first))
          (should (eq (ebox-focused-host-ref second) 'b)))
      (when (buffer-live-p first) (kill-buffer first))
      (kill-buffer second))))

(ert-deftest ebox-disabled-node-blocks-native-activation-and-navigation ()
  "Disabled capability blocks own and inherited maps until a committed reenable."
  (with-temp-buffer
    (let ((calls 0))
      (ebox-render-to-buffer
       (current-buffer)
       (ebox-build
        `(column :keymap ,(ebox-keymap-create :activate (lambda () (setq calls (1+ calls))))
                 (text :id "disabled" :disabled t :tab-index 0 "Disabled")
                 (text :id "enabled" :tab-index 0 "Enabled"))))
      (goto-char (point-min))
      (should-not (get-text-property (point) 'keymap))
      (should-error (ebox-activate) :type 'user-error)
      (ebox-focus-next)
      (should (looking-at "Enabled"))
      (ebox-activate)
      (should (= calls 1))
      (ebox-region-update (ebox-region-resolve (current-buffer) "disabled") :disabled nil)
      (ebox-focus-next 1 t)
      (should (looking-at "Disabled"))
      (ebox-activate)
      (should (= calls 2))
      (ebox-region-update "disabled" :disabled t)
      (ebox-region-update
       "disabled" :keymap (ebox-keymap-create :activate (lambda () (setq calls (+ calls 10)))))
      (ebox-region-update "disabled" :disabled nil)
      (ebox-activate (point-min))
      (should (= calls 12)))))

(ert-deftest ebox-focus-retains-keyed-dsl-nodes-and-clears-hidden-focus ()
  "Fresh source handles preserve keyed focus until published visibility hides it."
  (with-temp-buffer
    (ebox-render-to-buffer
     (current-buffer)
     (ebox-build '(column :key root
                         (box :key a :id "a" :tab-index 0 "AAA")
                         (box :key b :id "b" :tab-index 0 "BBB"))))
    (ebox-focus-next)
    (ebox-focus-next)
    (should (looking-at "BBB"))
    (ebox-commit
     (current-buffer)
     (ebox-build '(column :key root
                         (box :key b :id "b" :tab-index 0 "BBB")
                         (box :key a :id "a" :tab-index 0 "AAA"))))
    (should (ebox-focused-host-ref))
    (should (looking-at "BBB"))
    (ebox-focus-next)
    (should (looking-at "AAA"))
    (ebox-region-update (ebox-region-resolve (current-buffer) "a") :visibility 'hidden)
    (should-not (ebox-focused-host-ref))
    (ebox-focus-next)
    (should (looking-at "BBB"))))

(ert-deftest ebox-focus-returns-owned-references-and-restores-rejected-reorder ()
  "Returned reference data cannot corrupt ownership, and reorder rejection restores point."
  (with-temp-buffer
    (let ((builder (ebox-source-builder-create)))
      (ebox-render-to-buffer
       (current-buffer)
       (ebox-canonical-input-create
        (list (ebox-text-create
               :value "Owned" :source-handle
               (ebox-source-builder-bind builder :identity '(owned "reference")
                                         :interactions '(:tab-index 0))
               :owned-facts (ebox-canonical-facts-from-declarations 'text nil)))
        (ebox-source-builder-finish builder))))
    (let ((ref (ebox-focus-next)))
      (aset (cadr ref) 0 ?X)
      (setcar ref 'changed)
      (should (equal (ebox-focused-host-ref) '(owned "reference")))))
  (with-temp-buffer
    (ebox-render-to-buffer
     (current-buffer)
     (ebox-focus-test--input '((a "AAA" (:tab-index 0)) (b "BBB" (:tab-index 0)))))
    (ebox-focus 'b)
    (let ((before (point)))
      (should-error
       (ebox-commit
        (current-buffer)
        (ebox-focus-test--input '((b "B" (:tab-index 0)) (a "A" (:tab-index 0))))
        (lambda (_report) (error "Reject reorder"))))
      (should (eq (ebox-focused-host-ref) 'b))
      (should (= (point) before))
      (should (looking-at "BBB")))))

(ert-deftest ebox-focus-prefers-source-identity-over-reused-layout-nodes ()
  "Source identity follows unkeyed reorder, and a replacement cannot acquire focus."
  (with-temp-buffer
    (ebox-render-to-buffer
     (current-buffer)
     (ebox-focus-test--input '((a "AAA" (:tab-index 0)) (b "BBB" (:tab-index 0))) t))
    (ebox-focus 'a)
    (ebox-commit
     (current-buffer)
     (ebox-focus-test--input '((b "BBB" (:tab-index 0)) (a "AAA" (:tab-index 0))) t))
    (should (eq (ebox-focused-host-ref) 'a))
    (should (looking-at "AAA"))
    (ebox-commit
     (current-buffer)
     (ebox-focus-test--input '((b "BBB" (:tab-index 0)) (c "CCC" (:tab-index 0))) t))
    (should-not (ebox-focused-host-ref))
    (should (eq (ebox-focus-first) 'b))))

(ert-deftest ebox-native-activation-shares-focus-with-position-and-mouse-selection ()
  "Keyboard and logical activation respect focus; explicit positions and mouse use the hit target."
  (with-temp-buffer
    (let (events)
      (ebox-render-to-buffer
       (current-buffer)
       (ebox-build
        `(box :tab-index 0 :keymap ,(ebox-keymap-create :activate (lambda () (push 'parent events) 'parent))
              (text :tab-index 1 :keymap ,(ebox-keymap-create :activate (lambda () (push 'child events) 'child))
                    "Child"))))
      (let ((parent (ebox-focus-first)) (window (selected-window)))
        (dolist (keys '("RET" "<return>" "SPC"))
          (let ((last-input-event (aref (vconcat (kbd keys)) 0)))
            (should (eq (call-interactively (key-binding (kbd keys))) 'parent))))
        (should (eq (ebox-activate) 'parent))
        (should (eq (ebox-activate (point)) 'child))
        (save-window-excursion
          (set-window-buffer window (current-buffer))
          (let* ((last-input-event (list 'mouse-1 (list window (point) '(1 . 1) 0)))
                 (command (lookup-key (get-text-property (point) 'keymap) [mouse-1])))
            (should (eq (call-interactively command) 'child))))
        (should (equal (ebox-focused-host-ref) parent))
        (should (eq (selected-window) window))
        (should (equal events '(child child parent parent parent parent)))
        (ebox-focus-next)
        (should (eq (ebox-activate) 'child))))))

(ert-deftest ebox-native-activation-keeps-focus-barriers-and-custom-bindings ()
  "A callbackless focused parent blocks activation while custom bindings remain native."
  (with-temp-buffer
    (let ((calls 0))
      (ebox-render-to-buffer
       (current-buffer)
       (ebox-build
        `(box :tab-index 0 :keymap nil
              (text :tab-index 1
                    :keymap ,(ebox-keymap-create
                              :activate (lambda () (setq calls (1+ calls)))
                              :bindings (list (cons "x" (lambda () (setq calls (+ calls 10))))))
                    "Child"))))
      (ebox-focus-first)
      (should-error (ebox-activate) :type 'user-error)
      (should-not (ebox-activate nil t))
      (let ((last-input-event ?\r))
        (should-error (call-interactively (key-binding (kbd "RET"))) :type 'user-error))
      (should (= calls 0))
      (let ((last-input-event ?x)) (call-interactively (key-binding (kbd "x"))))
      (should (= calls 10))
      (ebox-activate (point))
      (should (= calls 11)))))

(ert-deftest ebox-buffer-mode-provides-cyclic-focus-and-releases-bindings ()
  "Mounted mode supplies cyclic TAB navigation and default RET, then releases them on unmount."
  (with-temp-buffer
    (ebox-render-to-buffer
     (current-buffer)
     (ebox-focus-test--input '((a "AAA" (:tab-index 0))
                               (b "BBB" (:tab-index 0 :disabled t))
                               (c "CCC" (:tab-index 0)))))
    (let ((forward (key-binding (kbd "TAB")))
          (backward (key-binding (kbd "<backtab>"))))
      (should (eq forward (lookup-key ebox-buffer-mode-map (kbd "TAB"))))
      (should (eq (key-binding (kbd "RET")) #'ebox-activate))
      (call-interactively forward)
      (should (eq (ebox-focused-host-ref) 'a))
      (call-interactively forward)
      (should (eq (ebox-focused-host-ref) 'c))
      (call-interactively forward)
      (should (eq (ebox-focused-host-ref) 'a))
      (call-interactively backward)
      (should (eq (ebox-focused-host-ref) 'c))
      (ebox-unmount-buffer (current-buffer))
      (should-not (eq (key-binding (kbd "TAB")) forward))
      (should-not (eq (key-binding (kbd "RET")) #'ebox-activate)))))

(ert-deftest ebox-native-keyboard-follows-manual-point-and-committed-map-replacement ()
  "Manual point selects another native target, and retained updates replace focused commands."
  (with-temp-buffer
    (let (events)
      (ebox-render-to-buffer
       (current-buffer)
       (ebox-build
        `(column
          (text :key a :id "a" :tab-index 0
                :keymap ,(ebox-keymap-create :activate (lambda () (push 'a events))) "AAA")
          (text :key b :id "b" :tab-index 1
                :keymap ,(ebox-keymap-create :activate (lambda () (push 'b events))) "BBB"))))
      (ebox-focus-first)
      (goto-char (+ (point-min) (string-match "BBB" (buffer-string))))
      (let ((last-input-event ?\r)) (call-interactively (key-binding (kbd "RET"))))
      (should (equal events '(b)))
      (ebox-focus-first)
      (ebox-region-update
       "a" :keymap (ebox-keymap-create :activate (lambda () (push 'replacement events))))
      (let ((last-input-event ?\r)) (call-interactively (key-binding (kbd "RET"))))
      (should (equal events '(replacement b))))))

(provide 'ebox-focus-tests)
;;; ebox-focus-tests.el ends here
