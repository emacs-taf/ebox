;;; ebox-font-tests.el --- Font projection contracts -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'ebox)

(ert-deftest ebox-canonical-property-cutover-shares-one-resolved-font-fact ()
  "Real Surface measurement and paint share one capability-resolved fact."
  (let* ((ebox-font--cache (make-hash-table :test #'equal))
         (resolver-calls 0)
         (ebox-font--resolver
         (lambda (face _window)
           (cl-incf resolver-calls)
           (list :identity (list 'resolved-font (copy-tree face))
                 :metrics (vector 'metrics (copy-tree face))))))
    (let* ((below
            (ebox-font--project
             :size 1.39 :weight 'normal :style 'normal
             :capability-signature 'display-a))
           (above
            (ebox-font--project
             :size 1.4 :weight 'normal :style 'normal
             :capability-signature 'display-a))
           (same
            (ebox-font--project
             :size 1.4 :weight 'normal :style 'normal
             :capability-signature 'display-a))
           (changed-capability
            (ebox-font--project
             :size 1.4 :weight 'normal :style 'normal
             :capability-signature 'display-b)))
      (should (= (ebox-font-fact-requested-decipoints below) 10))
      (should (= (ebox-font-fact-requested-decipoints above) 11))
      (should (eq above same))
      (should-not (eq above changed-capability))
      (let ((identity (ebox-font-fact-resolved-font-identity above))
            (metrics (ebox-font-fact-measurement-metrics above)))
        (setf (plist-get identity :css-weight) 900)
        (aset metrics 0 'damaged)
        (should (= (plist-get
                    (ebox-font-fact-resolved-font-identity above)
                    :css-weight)
                   400))
        (should (eq (aref (ebox-font-fact-measurement-metrics above) 0)
                    'metrics)))
      (should (= resolver-calls 3)))
    (setq resolver-calls 0
          ebox-font--cache (make-hash-table :test #'equal))
    (let ((capability 'display-a)
          (buffer (generate-new-buffer " *ebox-font-contract*")))
      (unwind-protect
          (cl-letf (((symbol-function 'ebox--display-signature-for-window)
                     (lambda (_window) capability)))
            (ebox-render-to-buffer
             buffer
             (ebox-build
              '(box :width (vw 100)
                    (text :font-size 16 :font-style italic "A"))))
            (let* ((state-a (ebox--buffer-render-state buffer))
                   (node-a
                    (car (ebox-tree-node-children
                          (plist-get state-a :root-node))))
                   (fact-a (plist-get node-a :ebox-font-fact))
                   (measurement-fact nil)
                   (paint-fact nil)
                   (measurement-function
                    (symbol-function 'ebox-font-measurement-face))
                   (paint-function (symbol-function 'ebox-font-paint-face))
                   measured face)
              (cl-letf (((symbol-function 'ebox-font-measurement-face)
                         (lambda (projection)
                           (setq measurement-fact projection)
                           (funcall measurement-function projection)))
                        ((symbol-function 'ebox-font-paint-face)
                         (lambda (projection)
                           (setq paint-fact projection)
                           (funcall paint-function projection))))
                (setq measured (ebox--propertize-typography "A" node-a)
                      face (ebox-buffer--font-face node-a)))
              (should (ebox-font-fact-p fact-a))
              (should (= resolver-calls 1))
              (should (= (hash-table-count ebox-font--cache) 1))
              (should (= (ebox-font-fact-requested-decipoints fact-a) 120))
              (should (eq fact-a measurement-fact))
              (should (eq fact-a paint-fact))
              (should (integerp (plist-get face :height)))
              (should (= (plist-get face :height) 120))
              (should (eq (plist-get face :slant) 'italic))
              (should (numberp (ebox-string-pixel-width measured)))
              (setq capability 'display-b)
              (let ((tp--surface-publication-step-function
                     (lambda (step _surface)
                       (when (eq step 'client-state)
                         (error "Reject font capability publication")))))
                (should-error
                 (ebox-surface-update-buffer-viewport
                  buffer (plist-get state-a :viewport-width)
                  (plist-get state-a :viewport-height))))
              (let* ((rolled-back (ebox--buffer-render-state buffer))
                     (rolled-back-node
                      (car (ebox-tree-node-children
                            (plist-get rolled-back :root-node)))))
                (should (eq rolled-back state-a))
                (should (eq (plist-get rolled-back-node :ebox-font-fact)
                            fact-a)))
              (ebox-surface-update-buffer-viewport
               buffer (plist-get state-a :viewport-width)
               (plist-get state-a :viewport-height))
              (let* ((state-b (ebox--buffer-render-state buffer))
                     (node-b
                      (car (ebox-tree-node-children
                            (plist-get state-b :root-node))))
                     (fact-b (plist-get node-b :ebox-font-fact)))
                (should-not (eq fact-a fact-b))
                (should (eq (ebox-font-fact-capability-signature fact-b)
                            'display-b))
                (should (= resolver-calls 2))
                (should (= (hash-table-count ebox-font--cache) 2)))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ebox-relative-font-weight-resolves-before-emacs-paint ()
  "CSS relative weight should not leak into an Emacs face attribute."
  (let ((ebox-font--cache (make-hash-table :test #'equal))
        (ebox-font--resolver
         (lambda (face _window)
           (list :identity (list :face face) :metrics nil)))
        (buffer (generate-new-buffer " *ebox-font-relative*")))
    (unwind-protect
        (cl-letf (((symbol-function 'ebox--display-signature-for-window)
                   (lambda (_window) 'display-a)))
          (ebox-render-to-buffer
           buffer
           (ebox-build
            '(box :font-weight 400
                  (text :font-weight bolder "Bold"))))
          (let* ((root (plist-get (ebox--buffer-render-state buffer)
                                  :root-node))
                 (child (car (ebox-tree-node-children root)))
                 (fact (plist-get child :ebox-font-fact)))
            (should (= (plist-get
                        (ebox-font-fact-resolved-font-identity fact)
                        :css-weight)
                       700))
            (should (eq (plist-get (ebox-font-paint-face fact) :weight)
                        'bold))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-measure-display-replacements-own-one-run ()
  "A display replacement is one unit even across face and metadata changes."
  (dolist (display (list '(space :width (15)) "X"))
    (let ((text (propertize "abc" 'display display)))
      (should (= (ebox-string-pixel-width text) (string-pixel-width text)))
      (put-text-property 1 2 'face 'bold text)
      (put-text-property 2 3 'help-echo "last" text)
      (should (= (ebox-string-pixel-width text) (string-pixel-width text)))
      (should (= (ebox-string-pixel-width (concat text "Z"))
                 (string-pixel-width (concat text "Z")))))))

(ert-deftest ebox-measure-distinguishes-adjacent-display-identities ()
  "Equal but distinct display values are two replacements, including cache hits."
  (let* ((one (propertize "ab" 'display (list 'space :width (list 15))))
         (two (concat (propertize "a" 'display (list 'space :width (list 15)))
                      (propertize "b" 'display (list 'space :width (list 15))))))
    (dotimes (_ 2)
      (should (= (ebox-string-pixel-width one) 15))
      (should (= (ebox-string-pixel-width two) 30)))))

(ert-deftest ebox-measure-quantizes-display-runs-without-splitting-them ()
  "Fractional replacements round once per EQ run and retain source properties."
  (let* ((first (propertize "abc" 'display (list 'space :width (list 3.5))
                           'help-echo "first"))
         (second (propertize "de" 'display (list 'space :width (list 3.5))))
         (source (concat first second))
         (result (ebox--quantize-pixel-spaces source)))
    (should (= (ebox-string-pixel-width source) 7))
    (should (= (ebox-string-pixel-width result) 7))
    (should (eq (get-text-property 0 'display result)
                (get-text-property 2 'display result)))
    (should (eq (get-text-property 3 'display result)
                (get-text-property 4 'display result)))
    (should-not (eq (get-text-property 2 'display result)
                    (get-text-property 3 'display result)))
    (should (equal (get-text-property 2 'help-echo result) "first"))
    (should (= (ebox--fixed-pixel-space-width (get-text-property 0 'display source))
               3.5))))

(provide 'ebox-font-tests)
;;; ebox-font-tests.el ends here
