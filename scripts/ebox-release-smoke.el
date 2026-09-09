;;; ebox-release-smoke.el --- Isolated package installation smoke -*- lexical-binding: t; -*-

;;; Commentary:
;; Invoked by scripts/ebox-release.py verify in a disposable user directory.
;; No source checkout or sibling package may enter this process's load-path.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'package)
(require 'bytecomp)

(let* ((archive (getenv "EBOX_RELEASE_ARCHIVE"))
       (profile (getenv "EBOX_RELEASE_PROFILE"))
       (native (getenv "EBOX_RELEASE_NATIVE"))
       (build-native (equal (getenv "EBOX_RELEASE_BUILD_NATIVE") "1"))
       (manifest (with-temp-buffer
                   (insert-file-contents (expand-file-name "manifest.json" archive))
                   (json-parse-buffer :object-type 'alist :array-type 'list)))
       (packages (alist-get 'packages manifest)))
  (unless (and archive profile)
    (error "Run through the release verification entry point"))
  (setq user-emacs-directory (file-name-as-directory profile)
        package-user-dir (expand-file-name "elpa" profile)
        package-archives (list (cons "ebox-release" (file-name-as-directory archive)))
        package-check-signature nil
        package-directory-list nil
        native-comp-jit-compilation nil)
  (package-initialize)
  (package-refresh-contents)
  (let* (compile-issues
         (capture-warning
          (lambda (message &rest _)
            (when (and byte-compile-current-file
                       (string-match-p "\\`ebox.*\\.el\\'"
                                       (file-name-nondirectory byte-compile-current-file))
                       ;; package.el owns generated descriptor/autoload compilation.
                       (not (string-match-p "-\\(?:pkg\\|autoloads\\)\\.el\\'"
                                            byte-compile-current-file)))
              (push (format "%s: %s" (file-name-nondirectory byte-compile-current-file)
                            message) compile-issues)))))
    (unwind-protect
        (progn
          (advice-add 'byte-compile-log-warning :before capture-warning)
          (package-install 'ebox)
          (when (seq-some (lambda (entry) (equal (alist-get 'name entry) "ekp")) packages)
            (package-install 'ekp)))
      (advice-remove 'byte-compile-log-warning capture-warning))
    (when compile-issues
      (error "Installed Ebox compilation diagnostics:\n%s"
             (mapconcat #'identity (nreverse compile-issues) "\n"))))
  (dolist (command '(ebox-build ebox-render ebox-next-interaction ebox-previous-interaction))
    (unless (fboundp command)
      (error "Installed autoload registry omitted %s" command)))
  (require 'ebox)
  (dolist (feature '(tp ecss ebox))
    (let ((library (locate-library (symbol-name feature))))
      (unless (and (featurep feature) library
                   (file-in-directory-p library package-user-dir))
        (error "Package escaped the clean installation: %s" feature))))
  (when (featurep 'etaf)
    (error "Standalone installation unexpectedly loaded ETAF"))
  (when (featurep 'ebox-native-reflow)
    (error "Source installation eagerly loaded native subsystem"))
  (let* ((input (ebox-build '(box :width (ch 10) :height (lh 1) :overflow scroll
                                  "first\nsecond\nthird")))
         (region-counter ebox--region-id-counter)
         (node-counter ebox--runtime-node-id-counter)
         (scroll-count (hash-table-count ebox--scroll-global-state)))
    (dotimes (_ 3) (ebox-render input))
    (unless (and (= region-counter ebox--region-id-counter)
                 (= node-counter ebox--runtime-node-id-counter)
                 (= scroll-count (hash-table-count ebox--scroll-global-state)))
      (error "Installed ephemeral rendering leaked live identity or scroll state")))
  (when build-native
    (let ((process (ebox-native-build))
          (deadline (+ (float-time) 480)))
      (unwind-protect
          (progn
            (while (and (process-live-p process) (< (float-time) deadline))
              (accept-process-output process 0.1))
            (when (process-live-p process)
              (error "Installed native build timed out"))
            (unless (and (zerop (process-exit-status process))
                         (ebox-native-reflow-layout-ready-p))
              (error "Installed native build failed: %s"
                     (with-current-buffer (process-buffer process) (buffer-string))))
            (setq native (plist-get (ebox-native-reflow-runtime-report) :loaded-module-path)))
        (when (process-live-p process) (delete-process process)))))
  (when (and native (not (string-empty-p native)))
    (require 'ebox-native-reflow)
    (setq ebox-native-reflow-module-path native)
    (unless (ebox-native-reflow-layout-ready-p)
      (error "Installed Ebox could not load native module: %S"
             (ebox-native-reflow-runtime-report))))
  (let ((buffer (generate-new-buffer " *ebox-release-smoke*")) stale-handle)
    (unwind-protect
        (progn
          (ebox-render-to-buffer
           buffer (ebox-build '(column
                                (box :id "counter" :class "value" "before")
                                (box "unchanged"))))
          (with-current-buffer buffer
            (setq stale-handle (ebox-region-resolve buffer "counter"))
            (dotimes (index 30)
              (ebox-region-update stale-handle :content (format "after %02d" index)))
            (unless (and (string-match-p "after" (buffer-string))
                         (string-match-p "unchanged" (buffer-string))
                         (not (string-match-p "before" (buffer-string)))
                         (= 1 (length (ebox-selector-query-buffer buffer ".value"))))
              (error "Installed render/update/selector smoke failed"))))
      (kill-buffer buffer))
    (condition-case nil
        (progn (ebox-region-update stale-handle :content "invalid")
               (error "Installed stale handle accepted an update after unmount"))
      (user-error nil)))
  (if (assoc "ekp" (mapcar (lambda (entry) (cons (alist-get 'name entry) entry)) packages))
      (let ((calls 0))
        (require 'ekp)
        (let ((probe (lambda (&rest _) (cl-incf calls))))
          (unwind-protect
              (progn
                (advice-add 'ekp-pixel-justify :before probe)
                (ebox-render (ebox-build '(box :width (ch 12) :wrap-mode kp
                                              "one two three four five six seven")))
                (unless (> calls 0)
                  (error "KP installation did not invoke the real EKP provider")))
            (advice-remove 'ekp-pixel-justify probe))))
    (when (locate-library "ekp")
      (error "Default installation unexpectedly found optional EKP")))
  (when (and native (not (string-empty-p native)))
    (let* ((input (ebox-build '(box :width (ch 8) "native")))
           (node (ebox-canonical-input--single-root input "Release smoke"))
           (result (ebox-native-reflow-execute-sync
                    node '(:key 1 :viewport-width 80 :viewport-height 20
                           :runtime-revision 0 :context-hash 0 :complete t))))
      (unless (and (plist-get result :native-frame)
                   (string-match-p "native" (plist-get result :rendered)))
        (error "Installed native module did not produce a native render frame"))))
  (princ (format "Clean installation OK: Emacs %s; render, update, selector; EKP %s; native %s\n"
                 emacs-version (if (featurep 'ekp) "verified" "absent")
                 (if (and native (not (string-empty-p native))) "verified" "not requested"))))

;;; ebox-release-smoke.el ends here
