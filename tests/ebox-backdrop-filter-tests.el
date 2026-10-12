;;; ebox-backdrop-filter-tests.el --- Ebox backdrop filter tests -*- lexical-binding: t; -*-

;; Public behaviour of the `:backdrop-filter' style property: an overlay that
;; declares it keeps the covered cells and dims their colors.

(require 'ebox-test-support)

(ert-deftest ebox-backdrop-filter-keeps-text-and-dims-colors ()
  "A filtered overlay keeps covered text visible with dimmed colors."
  (let* ((ebox-viewport-width 12)
         (ebox-viewport-height 1)
         (rendered
          (ebox-render
           '(column :width (% 100) :height (% 100)
                    (box :width (% 100) :height (lh 1)
                         :color "#FFFFFF" :background-color "#101820"
                         "Hello")
                    (box :position absolute :layer root
                         :left (px 0) :top (lh 0)
                         :width (% 100) :height (% 100)
                         :backdrop-filter (brightness 0.5))))))
    (should (equal (substring-no-properties rendered 0 5) "Hello"))
    (should (equal (get-text-property 0 'face rendered)
                   '(:foreground "#800080008000" :background "#08080C0C1010")))))

(ert-deftest ebox-backdrop-filter-keeps-image-content-visible ()
  "A filtered overlay does not blank the image cells behind it."
  (let* ((ebox-viewport-width 6)
         (ebox-viewport-height 1)
         (image (ebox-node-create
                 'image (list :image (ebox-image-prepare
                                      '(image :type xpm :data "bad")
                                      2 1 :adapter 'placeholder))))
         (rendered
          (ebox-render
           (list 'column :width '(% 100) :height '(% 100)
                 image
                 '(box :position absolute :layer root
                       :left (px 0) :top (lh 0)
                       :width (% 100) :height (% 100)
                       :backdrop-filter (brightness 0.5))))))
    (should (equal (substring-no-properties rendered 0 2) ".."))))

(ert-deftest ebox-backdrop-filter-keeps-overlay-content-crisp ()
  "Only the pixels behind an overlay dim; its own content stays unchanged."
  (let* ((ebox-viewport-width 8)
         (ebox-viewport-height 1)
         (rendered
          (ebox-render
           '(column :width (% 100) :height (% 100)
                    (box :width (% 100) :height (lh 1)
                         :color "#FFFFFF" :background-color "#101820"
                         "Hello")
                    (box :position absolute :layer root
                         :left (px 0) :top (lh 0)
                         :width (ch 4) :height (lh 1)
                         :color "#00FF00"
                         :backdrop-filter (brightness 0.5)
                         "TOP")))))
    (should (equal (substring-no-properties rendered 0 5) "TOPlo"))
    (should (equal (get-text-property 0 'face rendered)
                   '(:foreground "#00FF00")))
    (should (equal (get-text-property 3 'face rendered)
                   '(:foreground "#800080008000" :background "#08080C0C1010")))
    (should (equal (get-text-property 4 'face rendered)
                   '((:foreground "#FFFFFF") (:background "#101820"))))))

(ert-deftest ebox-backdrop-filter-keeps-covered-cells-out-of-flow-hit ()
  "A filtered overlay still owns the cells it covers."
  (ebox-test-with-mounted
      (buffer root
              '(column :width (ch 8) :height (lh 2)
                       (box :id "under" :width (ch 8) :height (lh 1)
                            "Hello")
                       (box :id "veil" :position absolute :layer root
                            :left (px 0) :top (lh 0)
                            :width (% 100) :height (% 100)
                            :backdrop-filter (brightness 0.5))))
    (should (ebox-test-buffer-matches-render-p root buffer))
    (should (null (ebox-node-bounds (ebox-node-child root 0))))
    (should (ebox-node-bounds (ebox-node-child root 1)))))

(ert-deftest ebox-backdrop-filter-brightness-range-and-invalid-values ()
  "Brightness 1 keeps colors, higher values clamp, and other filters\nare dropped instead of dimming."
  (let* ((ebox-viewport-width 6)
         (ebox-viewport-height 1)
         (identity
          (ebox-render
           '(column :width (% 100) :height (% 100)
                    (box :width (% 100) :height (lh 1)
                         :color "#FFFFFF" :background-color "#101820"
                         "Hi")
                    (box :position absolute :layer root
                         :left (px 0) :top (lh 0)
                         :width (% 100) :height (% 100)
                         :backdrop-filter (brightness 1)))))
         (raised
          (ebox-render
           '(column :width (% 100) :height (% 100)
                    (box :width (% 100) :height (lh 1)
                         :color "#808080" "Hi")
                    (box :position absolute :layer root
                         :left (px 0) :top (lh 0)
                         :width (% 100) :height (% 100)
                         :backdrop-filter (brightness 2)))))
         (unsupported
          (ebox-render
           '(column :width (% 100) :height (% 100)
                    (box :width (% 100) :height (lh 1) "Hi")
                    (box :position absolute :layer root
                         :left (px 0) :top (lh 0)
                         :width (% 100) :height (% 100)
                         :backdrop-filter (blur 2))))))
    (should (equal (get-text-property 0 'face identity)
                   '((:foreground "#FFFFFF") (:background "#101820"))))
    (should (equal (get-text-property 0 'face raised)
                   '(:foreground "#FFFFFFFFFFFF")))
    (should (equal (substring-no-properties unsupported) " "))))

(provide 'ebox-backdrop-filter-tests)
;;; ebox-backdrop-filter-tests.el ends here
