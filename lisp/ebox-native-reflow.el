;;; ebox-native-reflow.el --- Optional Rust root reflow backend -*- lexical-binding: t; -*-

;;; Commentary:
;; Private loader and bounded-session wrapper for the optional Ebox Rust
;; dynamic module.  Background preparation remains root-only; eligible
;; side-effect-free owner candidates may also use the synchronous proof entry
;; without taking publication ownership.  Callers must keep ordinary Elisp
;; rendering as the exact correctness fallback.

;;; Code:

(require 'cl-lib)
(require 'compile)
(require 'json)
(require 'subr-x)
(require 'ebox-text)
(require 'ebox-paint)
(require 'ebox-measure)
(require 'ebox-render-context)
(require 'ebox-runtime-index)
(require 'ebox-size)

(defvar ebox-incremental--render-portals-p)

(declare-function ebox-string-height "ebox" (string))
(declare-function ebox-surface--retained-property-value-equal-p
                  "ebox-surface" (left right))
(declare-function ebox-native--module-version "ebox_native_reflow" ())
(declare-function ebox-native--module-layout-ready-p "ebox_native_reflow" ())
(declare-function ebox-native--module-create-session "ebox_native_reflow"
                  (workers max-jobs max-results max-result-bytes))
(declare-function ebox-native--module-fork-confirmed "ebox_native_reflow"
                  (session))
(declare-function ebox-native--module-submit "ebox_native_reflow"
                  (session generation payload))
(declare-function ebox-native--module-ready-p "ebox_native_reflow"
                  (session generation key))
(declare-function ebox-native--module-take "ebox_native_reflow"
                  (session generation key))
(declare-function ebox-native--module-render-proof "ebox_native_reflow"
                  (payload))
(declare-function ebox-native--module-render-frame "ebox_native_reflow"
                  (payload))
(declare-function ebox-native--module-render-session-frame "ebox_native_reflow"
                  (session generation payload))
(declare-function ebox-native--module-flex-size-lines "ebox_native_reflow"
                  (payload main-limit main-gap))
(declare-function ebox-native--module-confirm-frame "ebox_native_reflow"
                  (session generation key confirmed-revision))
(declare-function ebox-native--module-attach-readiness-channel
                  "ebox_native_reflow" (session process))
(declare-function ebox-native--module-detach-readiness-channel
                  "ebox_native_reflow" (session))
(declare-function ebox-native--module-cancel "ebox_native_reflow"
                  (session generation))
(declare-function ebox-native--module-stats "ebox_native_reflow" (session))
(declare-function ebox-native--module-release "ebox_native_reflow" (session))
(declare-function ebox--grapheme-clusters "ebox-layout" (string))
(declare-function ebox--grapheme-cluster-end "ebox-layout" (string start))
(declare-function ebox--format-content-string "ebox-layout" (box content))
(declare-function ebox-style-no-soft-wrap-p "ebox-style" (value))
(declare-function ebox-style-soft-wrap-p "ebox-style" (value))
(declare-function ebox-style--text-paint-owner-p "ebox-style" (node))
(declare-function ebox-layout-config-kind "ebox-layout-config" (config))
(declare-function ebox-layout-config-props "ebox-layout-config" (config))
(declare-function ebox-tree-node-children "ebox-tree" (node))
(declare-function ebox-buffer--font-face "ebox-buffer-backend" (style))
(declare-function ebox-buffer--text-decoration-face
                  "ebox-buffer-backend" (style))
(declare-function ebox--propertize-typography
                  "ebox-buffer-backend" (string style))
(declare-function ebox--ensure-node-id "ebox" (node))
(declare-function ebox--buffer-render-state "ebox-incremental" (buffer))
(declare-function ebox--ensure-region-id "ebox" (box))
(declare-function ebox--literal-root-pixel-width "ebox" (box))
(declare-function ebox--root-region-box "ebox" (root region-id))
(declare-function ebox--flex-axis "ebox-flex" (props))
(declare-function ebox--flex-container-content-props
                  "ebox-flex" (props raw-props wrapper-box))
(declare-function ebox--flex-item-props "ebox-flex" (item))
(declare-function ebox--flex-line-value "ebox-flex" (value &optional default))
(declare-function ebox--content-min-pixel "ebox-layout" (box))
(declare-function ebox--size-pixels
                  "ebox-layout" (value &optional box axis percent-base))
(declare-function ebox--size-line-height "ebox-layout" (&optional box))
(declare-function ebox--layout-children "ebox-tree" (node))
(declare-function ebox-tree-layout-children "ebox-tree" (node))
(declare-function ebox-tree-node-local-source-signature "ebox-tree" (node))
(declare-function ebox-source--index-record "ebox-source" (index handle))
(declare-function ebox-buffer-side-border-face
                  "ebox-buffer-backend" (color))
(declare-function ebox--space-pixel-width "ebox-measure" ())
(declare-function ebox-get "ebox" (box key))
(declare-function ebox-lines-join "ebox" (lines))
(declare-function ebox-pixel-space "ebox-measure" (pixel-width))
(declare-function ebox-string-lines "ebox" (string))
(declare-function ebox-string-pixel-width "ebox-measure" (string))
(declare-function ebox--current-display-signature "ebox-measure" ())
(declare-function ebox--display-signature-for-window
                  "ebox-measure" (window))
(declare-function ebox-surface--buffer-display-window
                  "ebox-surface" (buffer))
(declare-function ebox-text-property-value-copy "ebox-text" (value))
(declare-function ebox-paint-slot-p "ebox-paint" (value))
(declare-function ebox-paint-slot-face "ebox-paint" (slot))

(defvar ebox--flex-content-min-width-table)

(defvar ebox-native-reflow--compile-size-node nil
  "Owning node whose font measurements resolve fixed native size inputs.")

(defconst ebox-native-reflow-abi-version "23:10:14"
  "Version tuple shared by the native module, layout IR, and render tape.")

(defconst ebox-native-reflow--minimum-rust-version "1.82.0"
  "Minimum Cargo and rustc release supported by the native source.")

(defun ebox-native-reflow--abi-directory-name ()
  "Return the filesystem directory name for the current native ABI."
  (replace-regexp-in-string ":" "-" ebox-native-reflow-abi-version))

(defun ebox-native-reflow--system-directory-name ()
  "Return a filesystem-safe name for the current build target."
  (replace-regexp-in-string
   "[^[:alnum:]._-]" "_" (or system-configuration "unknown-system")))

(defun ebox-native-reflow--rust-architecture ()
  "Return the Rust architecture matching the current Emacs binary."
  (pcase (car (split-string (or system-configuration "") "-" t))
    ((or "aarch64" "arm64") "aarch64")
    ((or "x86_64" "amd64") "x86_64")
    ((or "i686" "i386") "i686")
    (architecture architecture)))

(defun ebox-native-reflow--rust-target ()
  "Return the Rust target triple matching the current Emacs binary."
  (when-let* ((architecture (ebox-native-reflow--rust-architecture)))
    (pcase system-type
      ('darwin (format "%s-apple-darwin" architecture))
      ('gnu/linux (format "%s-unknown-linux-gnu" architecture))
      ('windows-nt (format "%s-pc-windows-msvc" architecture))
      (_ (or system-configuration architecture)))))

(defun ebox-native-reflow--default-module-directory ()
  "Return the default user-owned directory for the native module."
  (file-name-as-directory
   (expand-file-name
    (format "ebox/native/%s/%s"
            (ebox-native-reflow--system-directory-name)
            (ebox-native-reflow--abi-directory-name))
    user-emacs-directory)))

(defgroup ebox-native-reflow nil
  "Optional Rust preparation for expensive Ebox root reflows."
  :group 'ebox
  :prefix "ebox-native-reflow-")

(defcustom ebox-native-reflow-module-path
  (ebox-native-reflow--default-module-directory)
  "File or directory where Ebox loads its optional native module.
The default is an ABI- and platform-specific directory below
`user-emacs-directory'.  A directory value contains the platform module
filename; a file value names the module directly.  Ebox never builds the
module while loading the package."
  :type '(choice (file :tag "Module file")
                 (directory :tag "Module directory"))
  :group 'ebox-native-reflow)

(defcustom ebox-native-reflow-max-jobs 512
  "Maximum queued jobs retained by one native reflow session."
  :type 'positive-integer
  :group 'ebox-native-reflow)

(defcustom ebox-native-reflow-max-results 512
  "Maximum ready results retained by one native reflow session."
  :type 'positive-integer
  :group 'ebox-native-reflow)

(defcustom ebox-native-reflow-max-result-bytes (* 64 1024 1024)
  "Maximum bytes retained by ready results in one native session."
  :type 'positive-integer
  :group 'ebox-native-reflow)

(defvar ebox-native-reflow--load-attempted-p nil
  "Non-nil after this Emacs tried to load the optional native module.")

(defvar ebox-native-reflow--available-p nil
  "Non-nil when the optional native module is loaded and ABI-compatible.")

(defvar ebox-native-reflow--load-error nil
  "Last native module load error, or nil.")

(defvar ebox-native-reflow--loaded-module-path nil
  "Absolute path of the native module loaded in this Emacs process.")

(defvar ebox-native-reflow--loaded-module-hash nil
  "SHA-256 hash of the native module loaded in this Emacs process.")

(defconst ebox-native-reflow--library-directory
  (file-name-directory
   (or load-file-name
       (locate-library "ebox-native-reflow")
       buffer-file-name
       default-directory))
  "Directory containing the loaded Ebox native reflow library.")

(defconst ebox-native-reflow--source-files
  '("Cargo.toml"
    "Cargo.lock"
    "build.rs"
    "src/lib.rs"
    "src/layout.rs"
    "c/ebox_module.c"
    "vendor/emacs-30/emacs-module.h")
  "Files required to compile the bundled native module source.")

(defvar ebox-native-reflow--last-build-report nil
  "Result plist from the most recent `ebox-native-build' invocation.")

(defvar ebox-native-reflow--flex-geometry-call-count 0
  "Number of pure native Flex geometry batches executed in this Emacs.")

(defvar ebox-native-reflow--build-process nil
  "Live asynchronous process started by `ebox-native-build', or nil.")

(defconst ebox-native-reflow--build-buffer-name "*Ebox Native Build*"
  "Compilation buffer used by `ebox-native-build'.")

(defvar-local ebox-native-status--diagnosis nil
  "Diagnosis displayed in the current native status buffer.")

(cl-defstruct (ebox-native-reflow-session
               (:constructor ebox-native-reflow--make-session))
  handle
  generation
  styles
  layout-package
  layout-fragment-cache
  layout-fragment-index
  layout-fragment-revision
  layout-style-index
  layout-property-template-index
  layout-edge-index
  readiness-process
  readiness-preparation
  released-p)

(cl-defstruct (ebox-native-reflow-preparation
               (:constructor ebox-native-reflow--make-preparation))
  native-session
  native-session-id
  generation
  buffer
  kind
  region-id
  source-root
  source-revision
  expected-revision
  display-signature
  context-hash
  layout-package
  key-table
  frame-cache
  materialization-queue
  specs
  ready-function
  error-function
  ready-timer
  idle-watch-p
  last-spec
  light-p
  window-start-line
  release-native-session-p
  final-stats
  stopped-p
  error)

(cl-defstruct (ebox-native-reflow-layout-scene
               (:constructor ebox-native-reflow--make-layout-scene))
  "Render-owned flat source snapshot for one immutable native layout."
  buffer
  render-state
  root
  node-postorder
  flex-content-min-widths
  display-signature
  runtime-revision)

(cl-defstruct (ebox-native-reflow-layout-builder
               (:constructor ebox-native-reflow--make-layout-builder))
  "Interruptible flat Layout IR builder over a captured render scene."
  scene
  fragments
  styles
  index
  package
  flat-node-visits
  tree-node-visits
  string-pixel-width-cache
  string-max-pixel-width-cache
  property-templates
  property-template-ids)

(defvar ebox-native-reflow--compile-styles nil
  "Dynamically bound ordered style registry for one Layout IR compile.")

(defvar ebox-native-reflow--compile-style-base-count 0
  "Number of retained styles preceding the current append batch.")

(defvar ebox-native-reflow--compile-style-index nil
  "Persistent retained style-to-id index for incremental compilation.")

(defvar ebox-native-reflow--compile-property-templates nil
  "Dynamically bound ordered opaque text-property registry.")

(defvar ebox-native-reflow--compile-property-template-base-count 0
  "Number of retained property templates preceding current additions.")

(defvar ebox-native-reflow--compile-property-template-index nil
  "Persistent retained property-template-to-id index.")

(defvar ebox-native-reflow--compile-retained-registry-p nil
  "Non-nil while style and property registries append incrementally.")

(defconst ebox-native-reflow--persistent-index-depth 16
  "Fixed number of four-bit branches in a retained native index path.")

(defun ebox-native-reflow--property-value-hash (value &optional depth)
  "Hash property VALUE consistently with identity-sensitive equality.
Bounded DEPTH keeps cyclic data safe; callback environments are never walked."
  (let ((depth (or depth 8)))
    (cond
     ((or (functionp value) (keymapp value)) (sxhash-eq value))
     ((ebox--paint-origin-p value)
      (ebox-native-reflow--property-value-hash
       (ebox--paint-origin-baseline value) depth))
     ((zerop depth) 0)
     ((consp value)
      (logxor (ebox-native-reflow--property-value-hash (car value) (1- depth))
              (ash (ebox-native-reflow--property-value-hash
                    (cdr value) (1- depth)) -1)))
     ((or (stringp value) (numberp value)) (sxhash-equal value))
     (t (sxhash-eq value)))))

(defun ebox-native-reflow--property-template-equal-p (left right)
  "Compare template envelopes LEFT and RIGHT and their opaque property values."
  (and (eq (plist-get left :kind) (plist-get right :kind))
       (let ((old (plist-get left :properties))
             (new (plist-get right :properties)))
         (and (= (length old) (length new))
              (cl-loop for (property value) on old by #'cddr
                       for entry = (plist-member new property)
                       always (and entry
                                   (ebox-surface--retained-property-value-equal-p
                                    value (cadr entry))))))))

(defun ebox-native-reflow--property-template-hash (template)
  "Hash TEMPLATE's envelope separately from its native property values."
  (let ((hash (sxhash-eq (plist-get template :kind))))
    (cl-loop for (property value) on (plist-get template :properties) by #'cddr
             do (setq hash (logxor hash (sxhash-eq property)
                                  (ebox-native-reflow--property-value-hash value))))
    hash))

(define-hash-table-test 'ebox-native-property-template
  #'ebox-native-reflow--property-template-equal-p
  #'ebox-native-reflow--property-template-hash)

(defun ebox-native-reflow--persistent-index-code (key &optional template-p)
  "Return a stable nonnegative retained-index code for KEY.
TEMPLATE-P selects native property equality with opaque callback identities."
  (if (and (integerp key) (>= key 0))
      key
    (logand (if template-p (ebox-native-reflow--property-template-hash key)
              (sxhash-equal key)) #xffffffffffffffff)))

(defun ebox-native-reflow--persistent-index-get (root key &optional missing template-p)
  "Return KEY's value from persistent ROOT, or MISSING.
TEMPLATE-P selects the native property-template comparison and hash."
  (let ((node root)
        (code (ebox-native-reflow--persistent-index-code key template-p))
        (depth 0))
    (while (and node (< depth ebox-native-reflow--persistent-index-depth))
      (setq node (and (vectorp node)
                      (aref node (logand (ash code (* -4 depth)) 15)))
            depth (1+ depth)))
    (if (= depth ebox-native-reflow--persistent-index-depth)
        (let ((pair (cl-assoc key node :test
                              (if template-p
                                  #'ebox-native-reflow--property-template-equal-p
                                #'equal))))
          (if pair (cdr pair) missing))
      missing)))

(defun ebox-native-reflow--persistent-index-put
    (root key value &optional depth template-p)
  "Return persistent ROOT updated to map KEY to VALUE.
Only the fixed-depth path for KEY is copied.  DEPTH is for recursion.
TEMPLATE-P selects the native property-template comparison and hash."
  (let ((depth (or depth 0)))
    (if (= depth ebox-native-reflow--persistent-index-depth)
        (cons (cons key value)
              (cl-remove key root :key #'car :test
                         (if template-p
                             #'ebox-native-reflow--property-template-equal-p
                           #'equal)))
      (let* ((code (ebox-native-reflow--persistent-index-code key template-p))
             (branch (logand (ash code (* -4 depth)) 15))
             (copy (if (vectorp root)
                       (copy-sequence root)
                     (make-vector 16 nil))))
        (aset copy branch
              (ebox-native-reflow--persistent-index-put
               (aref copy branch) key value (1+ depth) template-p))
        copy))))

(defun ebox-native-reflow--persistent-index-from-sequence (sequence &optional template-p)
  "Return an immutable persistent index for ordered SEQUENCE values.
TEMPLATE-P selects the native property-template comparison and hash."
  (let (root)
    (cl-loop for value across (vconcat sequence)
             for id from 0
             do (setq root
                      (ebox-native-reflow--persistent-index-put
                       root value id nil template-p)))
    root))

(defvar ebox-native-reflow--compile-property-template-ids nil
  "Dynamically bound opaque property-template lookup table.")

(defvar ebox-native-reflow--source-cluster-cache
  (make-hash-table :test #'equal)
  "Bounded cache of display-specific measured source clusters.")

(defconst ebox-native-reflow--source-cluster-cache-limit 4096
  "Maximum measured source runs retained by the native compiler.")

(defvar ebox-native-reflow--compile-display-signature nil)

(defconst ebox-native-reflow--unsafe-opaque-properties
  '(category
    composition
    display
    insert-behind-hooks
    insert-in-front-hooks
    invisible
    line-prefix
    modification-hooks
    wrap-prefix)
  "Text properties that cannot cross the native opaque-template boundary.
These properties can change layout indirectly or execute code during string
materialization.  Editing metadata such as `keymap', `mouse-face',
`help-echo', `read-only', sticky boundaries, closures, and application-owned
properties remains opaque to Rust and is restored by Emacs after proof
validation.")

(defvar ebox-native-reflow--compile-root-node nil
  "Root node whose native layout document is currently being compiled.")

(defconst ebox-native-reflow--tape-magic
  (unibyte-string ?E ?B ?X ?T))
(defconst ebox-native-reflow--tape-version 14)
(defconst ebox-native-reflow--tape-header-length 112)
(defconst ebox-native-reflow--tape-flag-ok 1)
(defconst ebox-native-reflow--tape-flag-complete 2)
(defconst ebox-native-reflow--tape-flag-patch 4)
(defconst ebox-native-reflow--tape-body-preamble-length 40)
(defconst ebox-native-reflow--tape-patch-body-preamble-length 56)
(defconst ebox-native-reflow--tape-patch-descriptor-length 32)
(defconst ebox-native-reflow--tape-metadata-role-symbols
  '(content content-owner pt pb pl pr mt mb ml mr bt bb bl br)
  "Root role symbols accepted in Rust tape-v9 metadata.")

(defun ebox-native-reflow--module-filename ()
  "Return the platform module filename produced by Cargo."
  (concat (unless (eq system-type 'windows-nt) "lib")
          "ebox_native_reflow"
          (or module-file-suffix
              (pcase system-type
                ('darwin ".dylib")
                ('windows-nt ".dll")
                (_ ".so")))))

(defun ebox-native-reflow--expand-candidate (candidate)
  "Return module path represented by CANDIDATE."
  (when (and candidate (not (string-empty-p candidate)))
    (let ((expanded (expand-file-name candidate)))
      (if (or (file-directory-p expanded)
              (directory-name-p candidate))
          (expand-file-name (ebox-native-reflow--module-filename) expanded)
        expanded))))

(defun ebox-native-reflow--candidate-paths ()
  "Return the sole configured native module candidate path."
  (when-let* ((candidate
              (ebox-native-reflow--expand-candidate
               ebox-native-reflow-module-path)))
    (list candidate)))

(defun ebox-native-reflow--pending-path (module-path)
  "Return MODULE-PATH's pending replacement path."
  (concat module-path ".pending"))

(defun ebox-native-reflow--previous-path (module-path)
  "Return MODULE-PATH's previous known-good path."
  (concat module-path ".previous"))

(defun ebox-native-reflow--promote-pending (module-path)
  "Promote MODULE-PATH's pending replacement before the first module load.
Return non-nil when a pending module was promoted.  If filesystem promotion
fails after moving the current module aside, restore that previous module."
  (let ((pending (ebox-native-reflow--pending-path module-path))
        (previous (ebox-native-reflow--previous-path module-path)))
    (when (file-exists-p pending)
      (let ((had-current (file-exists-p module-path)))
        (condition-case err
            (progn
              (make-directory (file-name-directory module-path) t)
              (when had-current
                (rename-file module-path previous t))
              (rename-file pending module-path t)
              t)
          (error
           (when (and had-current
                      (not (file-exists-p module-path))
                      (file-exists-p previous))
             (rename-file previous module-path t))
           (signal (car err) (cdr err))))))))

(defun ebox-native-reflow--file-sha256 (file)
  "Return FILE's SHA-256 digest, or nil when FILE is unreadable."
  (when (file-readable-p file)
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally file)
      (secure-hash 'sha256 (current-buffer)))))

(defun ebox-native-reflow--source-directory ()
  "Return the bundled native module source directory."
  (expand-file-name "../native" ebox-native-reflow--library-directory))

(defun ebox-native-reflow--build-directory ()
  "Return the private Cargo build directory for the current Emacs target."
  (file-name-as-directory
   (expand-file-name
    (format "ebox/native-build/%s/%s"
            (ebox-native-reflow--system-directory-name)
            (ebox-native-reflow--abi-directory-name))
    user-emacs-directory)))

(defun ebox-native-reflow--command-result (program &rest arguments)
  "Run PROGRAM with ARGUMENTS and return its exit status and output."
  (when program
    (with-temp-buffer
      (let ((status
             (condition-case err
                 (apply #'process-file program nil '(t t) nil arguments)
               (file-error
                (insert (error-message-string err))
                127))))
        (list :status status :output (string-trim (buffer-string)))))))

(defun ebox-native-reflow--command-output (program &rest arguments)
  "Return successful PROGRAM output for ARGUMENTS, or nil."
  (let ((result (apply #'ebox-native-reflow--command-result
                       program arguments)))
    (when (and result (eq 0 (plist-get result :status)))
      (plist-get result :output))))

(defun ebox-native-reflow--tool-host (output)
  "Return the Rust host triple parsed from verbose tool OUTPUT."
  (when (and output
             (string-match "^host: \\([^[:space:]\n]+\\)" output))
    (match-string 1 output)))

(defun ebox-native-reflow--tool-version (output)
  "Return the Cargo or rustc version line from verbose tool OUTPUT."
  (cl-find-if
   (lambda (line)
     (string-match-p "\\`\\(?:cargo\\|rustc\\) " line))
   (split-string (or output "") "\n" t)))

(defun ebox-native-reflow--tool-release (output)
  "Return the numeric Cargo or rustc release parsed from OUTPUT."
  (when-let* ((line (ebox-native-reflow--tool-version output)))
    (when (string-match
           "\\`\\(?:cargo\\|rustc\\) \\([0-9]+\\(?:\\.[0-9]+\\)+\\)"
           line)
      (match-string 1 line))))

(defun ebox-native-reflow--supported-toolchain-p
    (cargo-output rustc-output)
  "Return non-nil when CARGO-OUTPUT and RUSTC-OUTPUT meet Ebox's MSRV."
  (let ((cargo-release (ebox-native-reflow--tool-release cargo-output))
        (rustc-release (ebox-native-reflow--tool-release rustc-output)))
    (and cargo-release
         rustc-release
         (not (version< cargo-release
                        ebox-native-reflow--minimum-rust-version))
         (not (version< rustc-release
                        ebox-native-reflow--minimum-rust-version)))))

(defun ebox-native-reflow--rustup-toolchains (rustup)
  "Return installed toolchain names reported by RUSTUP."
  (when-let* ((output
              (ebox-native-reflow--command-output rustup "toolchain" "list")))
    (mapcar (lambda (line) (car (split-string line " " t)))
            (split-string output "\n" t))))

(defun ebox-native-reflow--matching-rustup-toolchain
    (rustup target &optional supported-only)
  "Return an installed RUSTUP toolchain whose native host is TARGET.
When SUPPORTED-ONLY is non-nil, require Cargo and rustc to meet Ebox's MSRV."
  (let* ((names (ebox-native-reflow--rustup-toolchains rustup))
         (stable (format "stable-%s" target))
         (ordered (if (member stable names)
                      (cons stable (delete stable (copy-sequence names)))
                    names)))
    (cl-find-if
     (lambda (name)
       (when (string-suffix-p target name)
         (let ((cargo-output
                (ebox-native-reflow--command-output
                 rustup "run" name "cargo" "-vV"))
               (rustc-output
                (ebox-native-reflow--command-output
                 rustup "run" name "rustc" "-vV")))
           (and (equal (ebox-native-reflow--tool-host cargo-output) target)
                (equal (ebox-native-reflow--tool-host rustc-output) target)
                (or (not supported-only)
                    (ebox-native-reflow--supported-toolchain-p
                     cargo-output rustc-output))))))
     ordered)))

(defun ebox-native-reflow--rustup-toolchain-info (rustup name target)
  "Return build metadata for RUSTUP toolchain NAME targeting TARGET."
  (let ((cargo-output
         (ebox-native-reflow--command-output
          rustup "run" name "cargo" "-vV"))
        (rustc-output
         (ebox-native-reflow--command-output
          rustup "run" name "rustc" "-vV")))
    (list :name name
          :target target
          :host target
          :cargo-command (list rustup "run" name "cargo")
          :rustc-command (list rustup "run" name "rustc")
          :cargo-version (ebox-native-reflow--tool-version cargo-output)
          :rustc-version (ebox-native-reflow--tool-version rustc-output))))

(defun ebox-native-reflow--select-rust-toolchain ()
  "Return a Rust/Cargo toolchain native to the running Emacs target.
The result is a plist containing command prefixes, paths, versions, and host.
An installed matching rustup toolchain is selected automatically when the
default tools run under a different architecture or are too old."
  (let* ((target (ebox-native-reflow--rust-target))
         (cargo (executable-find "cargo"))
         (rustc (executable-find "rustc"))
         (cargo-output (ebox-native-reflow--command-output cargo "-vV"))
         (rustc-output (ebox-native-reflow--command-output rustc "-vV"))
         (cargo-host (ebox-native-reflow--tool-host cargo-output))
         (rustc-host (ebox-native-reflow--tool-host rustc-output))
         (default-toolchain
          (and cargo rustc
               (equal cargo-host target)
               (equal rustc-host target)
               (list :name "default"
                     :target target
                     :host target
                     :cargo-command (list cargo)
                     :rustc-command (list rustc)
                     :cargo-version
                     (ebox-native-reflow--tool-version cargo-output)
                     :rustc-version
                     (ebox-native-reflow--tool-version rustc-output)))))
    (cond
     ((and default-toolchain
           (ebox-native-reflow--supported-toolchain-p
            cargo-output rustc-output))
      default-toolchain)
     ((when-let* ((rustup (executable-find "rustup"))
                  (name (ebox-native-reflow--matching-rustup-toolchain
                         rustup target t)))
        (ebox-native-reflow--rustup-toolchain-info rustup name target)))
     (default-toolchain default-toolchain)
     ((when-let* ((rustup (executable-find "rustup"))
                  (name (ebox-native-reflow--matching-rustup-toolchain
                         rustup target)))
        (ebox-native-reflow--rustup-toolchain-info rustup name target)))
     (t nil))))

(defun ebox-native-reflow--c-compiler ()
  "Return the configured or first available C compiler executable."
  (let* ((configured (getenv "CC"))
         (configured-command
          (car (ignore-errors (split-string-and-unquote configured)))))
    (or (and configured-command
             (or (and (file-name-absolute-p configured-command)
                      (file-executable-p configured-command)
                      configured-command)
                 (executable-find configured-command)))
        (cl-loop for name in (if (eq system-type 'windows-nt)
                                 '("cl" "clang" "gcc")
                               '("cc" "clang" "gcc"))
                 thereis (executable-find name)))))

(defun ebox-native-reflow--writable-parent-p (path)
  "Return non-nil when PATH or its nearest existing parent is writable."
  (let ((parent (file-name-directory (expand-file-name path))))
    (while (and parent (not (file-exists-p parent)))
      (let ((next (file-name-directory (directory-file-name parent))))
        (setq parent (unless (equal next parent) next))))
    (and parent (file-directory-p parent) (file-writable-p parent))))

(defun ebox-native-reflow--file-status (path)
  "Return a diagnostic plist describing PATH."
  (let ((attributes (and path (file-attributes path))))
    (list :path path
          :exists (and attributes t)
          :readable (and path (file-readable-p path))
          :size (and attributes (file-attribute-size attributes))
          :modified (and attributes
                         (file-attribute-modification-time attributes))
          :hash (and path (file-regular-p path)
                     (ebox-native-reflow--file-sha256 path)))))

(defun ebox-native-reflow--issue (code message)
  "Return a diagnostic issue with CODE and MESSAGE."
  (list :code code :message message))

(defun ebox-native--diagnose ()
  "Return one complete native build, installation, and runtime diagnosis.
This function owns environment checks shared by `ebox-native-status' and
`ebox-native-build'.  It never changes files, installs tools, or loads the
module."
  (let* ((target (ebox-native-reflow--rust-target))
         (source-directory (ebox-native-reflow--source-directory))
         (missing-sources
          (cl-remove-if
           #'file-readable-p
           (mapcar (lambda (file) (expand-file-name file source-directory))
                   ebox-native-reflow--source-files)))
         (module-path (car (ebox-native-reflow--candidate-paths)))
         (pending-path (and module-path
                            (ebox-native-reflow--pending-path module-path)))
         (previous-path (and module-path
                             (ebox-native-reflow--previous-path module-path)))
         (build-directory (ebox-native-reflow--build-directory))
         (toolchain (ebox-native-reflow--select-rust-toolchain))
         (compiler (ebox-native-reflow--c-compiler))
         errors
         warnings)
    (unless (and (fboundp 'module-load) module-file-suffix)
      (push (ebox-native-reflow--issue
             'dynamic-modules-unsupported
             "This Emacs was built without dynamic module support.")
            errors))
    (unless target
      (push (ebox-native-reflow--issue
             'unknown-rust-target
             (format "Cannot map Emacs system configuration %S to Rust."
                     system-configuration))
            errors))
    (when missing-sources
      (push (ebox-native-reflow--issue
             'native-source-incomplete
             (format "Bundled native source is incomplete; missing: %s"
                     (mapconcat #'identity missing-sources ", ")))
            errors))
    (unless module-path
      (push (ebox-native-reflow--issue
             'module-path-invalid
             "`ebox-native-reflow-module-path' does not resolve to a file.")
            errors))
    (when (and module-path
               (not (ebox-native-reflow--writable-parent-p module-path)))
      (push (ebox-native-reflow--issue
             'module-directory-not-writable
             (format "Module directory is not writable: %s"
                     (file-name-directory module-path)))
            errors))
    (unless (ebox-native-reflow--writable-parent-p build-directory)
      (push (ebox-native-reflow--issue
             'build-directory-not-writable
             (format "Build directory is not writable: %s" build-directory))
            errors))
    (unless toolchain
      (push (ebox-native-reflow--issue
             'native-rust-toolchain-missing
             (format
              (concat "No Rust/Cargo toolchain native to Emacs target %s was "
                      "found. Install it with: rustup toolchain install stable-%s")
              target target))
            errors))
    (when (and toolchain
               (not (ebox-native-reflow--supported-toolchain-p
                     (plist-get toolchain :cargo-version)
                     (plist-get toolchain :rustc-version))))
      (push (ebox-native-reflow--issue
             'native-rust-toolchain-too-old
             (format
              (concat "Rust/Cargo %s or newer is required for target %s "
                      "(found %s; %s). Install or update it with: "
                      "rustup toolchain install stable-%s")
              ebox-native-reflow--minimum-rust-version
              target
              (or (plist-get toolchain :cargo-version) "unknown Cargo")
              (or (plist-get toolchain :rustc-version) "unknown rustc")
              target))
            errors))
    (unless compiler
      (push (ebox-native-reflow--issue
             'c-compiler-missing
             "No C compiler was found (checked CC, cc, clang, and gcc).")
            errors))
    (unless (and module-path (file-readable-p module-path))
      (push (ebox-native-reflow--issue
             'module-not-installed
             "The compiled native module is not installed yet.")
            warnings))
    (when (and pending-path (file-exists-p pending-path))
      (push (ebox-native-reflow--issue
             'restart-required
             "A newly compiled module is pending; restart Emacs to load it.")
            warnings))
    (let ((errors (nreverse errors))
          (warnings (nreverse warnings)))
      (list
       :ok (null errors)
       :errors errors
       :warnings warnings
       :platform (list :system-type system-type
                       :system-configuration system-configuration
                       :rust-target target
                       :module-suffix module-file-suffix
                       :dynamic-modules-p
                       (and (fboundp 'module-load) module-file-suffix t))
       :source (list :directory source-directory
                     :complete-p (null missing-sources)
                     :missing missing-sources)
       :toolchain toolchain
       :compiler compiler
       :paths (list :configured ebox-native-reflow-module-path
                    :default-p
                    (and (stringp ebox-native-reflow-module-path)
                         (equal
                          (expand-file-name ebox-native-reflow-module-path)
                          (expand-file-name
                           (ebox-native-reflow--default-module-directory))))
                    :module (ebox-native-reflow--file-status module-path)
                    :pending (ebox-native-reflow--file-status pending-path)
                    :previous (ebox-native-reflow--file-status previous-path)
                    :build-directory build-directory)
       :runtime (list :load-attempted-p
                      ebox-native-reflow--load-attempted-p
                      :available-p ebox-native-reflow--available-p
                      :loaded-path ebox-native-reflow--loaded-module-path
                      :loaded-hash ebox-native-reflow--loaded-module-hash
                      :load-error ebox-native-reflow--load-error)
       :last-build ebox-native-reflow--last-build-report))))

(defun ebox-native-reflow--build-command (diagnosis)
  "Return the native Cargo command described by DIAGNOSIS."
  (let* ((toolchain (plist-get diagnosis :toolchain))
         (target (plist-get (plist-get diagnosis :platform) :rust-target))
         (source (plist-get diagnosis :source))
         (paths (plist-get diagnosis :paths)))
    (append
     (plist-get toolchain :cargo-command)
     (list "build"
           "--locked"
           "--manifest-path" (expand-file-name "Cargo.toml"
                                                (plist-get source :directory))
           "--release"
           "--target" target
           "--target-dir" (plist-get paths :build-directory)))))

(defun ebox-native-reflow--build-artifact (diagnosis)
  "Return the Cargo output module path described by DIAGNOSIS."
  (let ((target (plist-get (plist-get diagnosis :platform) :rust-target))
        (build-directory
         (plist-get (plist-get diagnosis :paths) :build-directory)))
    (expand-file-name
     (format "%s/release/%s" target (ebox-native-reflow--module-filename))
     build-directory)))

(defun ebox-native-reflow--format-command (command)
  "Return shell-readable COMMAND text for logs only."
  (mapconcat #'shell-quote-argument command " "))

(defun ebox-native-reflow--prepare-build-buffer (diagnosis command clean)
  "Prepare and return the compilation buffer for DIAGNOSIS and COMMAND.
CLEAN records whether this invocation discarded the private Cargo cache."
  (let ((buffer (get-buffer-create ebox-native-reflow--build-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (compilation-mode)
        (insert (format "Ebox native module build\n\nTarget: %s\nToolchain: %s\nClean build: %s\nCommand: %s\n\n"
                        (plist-get (plist-get diagnosis :platform)
                                   :rust-target)
                        (plist-get (plist-get diagnosis :toolchain) :name)
                        (if clean "yes" "no")
                        (ebox-native-reflow--format-command command)))))
    buffer))

(defun ebox-native-reflow--safe-build-directory-p (directory)
  "Return non-nil when DIRECTORY is inside Ebox's private build root."
  (file-in-directory-p
   (expand-file-name directory)
   (file-name-as-directory
    (expand-file-name "ebox/native-build" user-emacs-directory))))

(defun ebox-native-reflow--clean-build-directory (directory)
  "Delete Ebox's private Cargo build DIRECTORY after validating its scope."
  (unless (ebox-native-reflow--safe-build-directory-p directory)
    (error "Refusing to clean unexpected build directory: %s" directory))
  (when (file-directory-p directory)
    (delete-directory directory t)))

(defun ebox-native-reflow--copy-atomically (source destination)
  "Copy SOURCE to DESTINATION by renaming a same-directory temporary file."
  (make-directory (file-name-directory destination) t)
  (let ((temporary (make-temp-file (concat destination ".new-"))))
    (unwind-protect
        (progn
          (copy-file source temporary t t nil t)
          (rename-file temporary destination t)
          (setq temporary nil)
          destination)
      (when (and temporary (file-exists-p temporary))
        (delete-file temporary)))))

(defun ebox-native-reflow--install-canonical (artifact module-path)
  "Atomically install ARTIFACT at MODULE-PATH and retain the old module."
  (let ((previous (ebox-native-reflow--previous-path module-path))
        (had-current (file-exists-p module-path)))
    (make-directory (file-name-directory module-path) t)
    (condition-case err
        (progn
          (when had-current
            (rename-file module-path previous t))
          (ebox-native-reflow--copy-atomically artifact module-path))
      (error
       (when (and had-current
                  (not (file-exists-p module-path))
                  (file-exists-p previous))
         (rename-file previous module-path t))
       (signal (car err) (cdr err))))))

(defun ebox-native-reflow--rollback-canonical (module-path had-current)
  "Roll back MODULE-PATH after a failed load when HAD-CURRENT was non-nil."
  (let ((previous (ebox-native-reflow--previous-path module-path)))
    (when (file-exists-p module-path)
      (delete-file module-path))
    (when (and had-current (file-exists-p previous))
      (rename-file previous module-path t))))

(defun ebox-native-reflow--install-artifact (artifact module-path)
  "Install ARTIFACT for MODULE-PATH and return an installation report.
If this Emacs already loaded a different module image, place the replacement
at the pending path so the current canonical file remains untouched until the
next Emacs start."
  (let* ((artifact-hash (ebox-native-reflow--file-sha256 artifact))
         (loaded-hash
          (or ebox-native-reflow--loaded-module-hash
              (and ebox-native-reflow--loaded-module-path
                   (ebox-native-reflow--file-sha256
                    ebox-native-reflow--loaded-module-path))))
         (loaded-p ebox-native-reflow--available-p)
         (had-current (file-exists-p module-path)))
    (cond
     ((and loaded-p (equal artifact-hash loaded-hash))
      (if (and had-current
               (equal artifact-hash
                      (ebox-native-reflow--file-sha256 module-path)))
          (list :status 'succeeded :installation 'unchanged
                :module module-path :restart-required-p nil)
        (let ((pending (ebox-native-reflow--pending-path module-path)))
          (ebox-native-reflow--copy-atomically artifact pending)
          (list :status 'succeeded :installation 'pending
                :module module-path :pending pending
                :restart-required-p t))))
     (loaded-p
      (let ((pending (ebox-native-reflow--pending-path module-path)))
        (ebox-native-reflow--copy-atomically artifact pending)
        (list :status 'succeeded :installation 'pending
              :module module-path :pending pending :restart-required-p t)))
     (t
      (ebox-native-reflow--install-canonical artifact module-path)
      (setq ebox-native-reflow--load-attempted-p nil
            ebox-native-reflow--available-p nil
            ebox-native-reflow--load-error nil
            ebox-native-reflow--loaded-module-path nil
            ebox-native-reflow--loaded-module-hash nil)
      (if (ebox-native-reflow-load)
          (list :status 'succeeded :installation 'loaded
                :module module-path :restart-required-p nil)
        (let ((load-error ebox-native-reflow--load-error))
          (ebox-native-reflow--rollback-canonical module-path had-current)
          (list :status 'failed :phase 'load :installation 'rolled-back
                :module module-path :error load-error)))))))

(defun ebox-native-reflow--append-build-log (format-string &rest arguments)
  "Append FORMAT-STRING and ARGUMENTS to the native build buffer."
  (when-let* ((buffer (get-buffer ebox-native-reflow--build-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert (apply #'format format-string arguments))))))

(defun ebox-native-reflow--refresh-status-buffer ()
  "Refresh an existing native status buffer without selecting it."
  (when-let* ((buffer (get-buffer "*Ebox Native Status*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (diagnosis (ebox-native--diagnose)))
        (erase-buffer)
        (setq ebox-native-status--diagnosis diagnosis)
        (ebox-native-reflow--insert-status diagnosis)
        (goto-char (point-min))))))

(defun ebox-native-reflow--finish-build (process)
  "Finalize native build PROCESS, install its artifact, and record status."
  (let* ((exit-status (process-exit-status process))
         (artifact (process-get process :ebox-artifact))
         (module-path (process-get process :ebox-module-path))
         (started (process-get process :ebox-started))
         (command (process-command process))
         report)
    (cond
     ((not (zerop exit-status))
      (setq report
            (list :status 'failed :phase 'compile :exit-status exit-status
                  :command command :started started :finished (current-time)
                  :error (format "Cargo exited with status %s" exit-status))))
     ((not (file-readable-p artifact))
      (setq report
            (list :status 'failed :phase 'artifact :exit-status exit-status
                  :command command :started started :finished (current-time)
                  :artifact artifact
                  :error (format "Cargo succeeded but did not produce %s"
                                 artifact))))
     (t
      (setq report
            (condition-case err
                (append
                 (ebox-native-reflow--install-artifact artifact module-path)
                 (list :phase 'install :exit-status exit-status
                       :command command :started started
                       :finished (current-time) :artifact artifact))
              (error
               (list :status 'failed :phase 'install
                     :exit-status exit-status :command command
                     :started started :finished (current-time)
                     :artifact artifact :error (error-message-string err)))))))
    (setq ebox-native-reflow--last-build-report report
          ebox-native-reflow--build-process nil)
    (ebox-native-reflow--append-build-log
     "\nEbox native build %s: %s\n"
     (plist-get report :status)
     (or (plist-get report :error)
         (pcase (plist-get report :installation)
           ('loaded "installed and loaded in this Emacs")
           ('pending "installed as pending; restart Emacs to activate")
           ('unchanged "module already matches the loaded image")
           (_ "completed"))))
    (ebox-native-reflow--refresh-status-buffer)
    (if (eq (plist-get report :status) 'succeeded)
        (message "Ebox native build succeeded%s"
                 (if (plist-get report :restart-required-p)
                     "; restart Emacs to activate it"
                   ""))
      (message "Ebox native build failed: %s"
               (plist-get report :error)))))

(defun ebox-native-reflow--build-sentinel (process _event)
  "Handle completion of native build PROCESS."
  (when (memq (process-status process) '(exit signal))
    (ebox-native-reflow--finish-build process)))

(defun ebox-native-reflow--show-preflight-errors (diagnosis clean)
  "Display DIAGNOSIS errors for a blocked build requested with CLEAN."
  (let ((buffer (get-buffer-create ebox-native-reflow--build-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (compilation-mode)
        (insert "Ebox native module build blocked by environment checks.\n\n")
        (when clean
          (insert "The clean build was not started.\n\n"))
        (dolist (issue (plist-get diagnosis :errors))
          (insert (format "[%s] %s\n"
                          (plist-get issue :code)
                          (plist-get issue :message))))))
    (display-buffer buffer)))

(defun ebox-native-reflow--build (&optional clean)
  "Compile and install the bundled native module asynchronously.
The command always runs the shared environment checks first and requires a
Rust/Cargo toolchain native to the current Emacs architecture.  With prefix
argument CLEAN, remove only Ebox's private Cargo build cache before compiling.
Build output and exact errors appear in `*Ebox Native Build*'."
  (interactive "P")
  (when (process-live-p ebox-native-reflow--build-process)
    (user-error "An Ebox native build is already running"))
  (let* ((diagnosis (ebox-native--diagnose))
         (clean (and clean t)))
    (unless (plist-get diagnosis :ok)
      (setq ebox-native-reflow--last-build-report
            (list :status 'failed :phase 'preflight
                  :started (current-time) :finished (current-time)
                  :errors (plist-get diagnosis :errors)))
      (ebox-native-reflow--show-preflight-errors diagnosis clean)
      (user-error "Ebox native build is blocked; see %s"
                  ebox-native-reflow--build-buffer-name))
    (let* ((paths (plist-get diagnosis :paths))
           (build-directory (plist-get paths :build-directory))
           (module-path (plist-get (plist-get paths :module) :path))
           (command (ebox-native-reflow--build-command diagnosis))
           (artifact (ebox-native-reflow--build-artifact diagnosis))
           (buffer (ebox-native-reflow--prepare-build-buffer
                    diagnosis command clean)))
      (condition-case err
          (progn
            (when clean
              (ebox-native-reflow--clean-build-directory build-directory))
            (make-directory build-directory t)
            (let ((default-directory
                   (plist-get (plist-get diagnosis :source) :directory)))
              (setq ebox-native-reflow--last-build-report
                    (list :status 'running :phase 'compile :command command
                          :started (current-time) :artifact artifact)
                    ebox-native-reflow--build-process
                    (make-process
                     :name "ebox-native-build"
                     :buffer buffer
                     :command command
                     :connection-type 'pipe
                     :noquery t)))
            (process-put ebox-native-reflow--build-process
                         :ebox-artifact artifact)
            (process-put ebox-native-reflow--build-process
                         :ebox-module-path module-path)
            (process-put ebox-native-reflow--build-process
                         :ebox-started (current-time))
            (set-process-sentinel ebox-native-reflow--build-process
                                  #'ebox-native-reflow--build-sentinel)
            (display-buffer buffer)
            (message "Ebox native build started with %s"
                     (plist-get (plist-get diagnosis :toolchain) :name))
            ebox-native-reflow--build-process)
        (error
         (setq ebox-native-reflow--build-process nil
               ebox-native-reflow--last-build-report
               (list :status 'failed :phase 'start :command command
                     :started (current-time) :finished (current-time)
                     :error (error-message-string err)))
         (ebox-native-reflow--append-build-log
          "\nEbox native build failed to start: %s\n"
          (error-message-string err))
         (display-buffer buffer)
         (user-error "Ebox native build failed to start: %s"
                     (error-message-string err)))))))

(defun ebox-native-reflow--clean-build ()
  "Run a native build after clearing Ebox's private Cargo cache."
  (interactive)
  (ebox-native-reflow--build t))

(defvar ebox-native-status-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "g") #'ebox-native-reflow--status)
    (define-key map (kbd "b") #'ebox-native-reflow--build)
    (define-key map (kbd "B") #'ebox-native-reflow--clean-build)
    map)
  "Keymap for `ebox-native-status-mode'.")

(define-derived-mode ebox-native-status-mode special-mode "Ebox-Native"
  "Major mode for the Ebox native module status report.")

(defun ebox-native-reflow--status-value (value)
  "Return a compact printable representation of VALUE."
  (cond
   ((eq value t) "yes")
   ((null value) "no")
   ((stringp value) value)
   (t (format "%S" value))))

(defun ebox-native-reflow--insert-status-row (label value)
  "Insert one status row with LABEL and VALUE."
  (insert (format "  %-22s %s\n" label
                  (ebox-native-reflow--status-value value))))

(defun ebox-native-reflow--insert-issues (title issues)
  "Insert diagnostic ISSUES below TITLE."
  (when issues
    (insert (propertize (concat title "\n") 'face 'bold))
    (dolist (issue issues)
      (insert (format "  - [%s] %s\n"
                      (plist-get issue :code)
                      (plist-get issue :message))))
    (insert "\n")))

(defun ebox-native-reflow--overall-status (diagnosis)
  "Return the user-facing overall state for DIAGNOSIS."
  (let* ((runtime (plist-get diagnosis :runtime))
         (paths (plist-get diagnosis :paths))
         (last-build (plist-get diagnosis :last-build)))
    (cond
     ((not (plist-get diagnosis :ok)) "blocked")
     ((eq (plist-get last-build :status) 'running) "building")
     ((plist-get (plist-get paths :pending) :exists) "restart required")
     ((plist-get runtime :available-p) "loaded")
     ((plist-get (plist-get paths :module) :exists) "installed, not loaded")
     (t "ready to build"))))

(defun ebox-native-reflow--insert-status (diagnosis)
  "Insert a human-readable native status report for DIAGNOSIS."
  (let* ((platform (plist-get diagnosis :platform))
         (source (plist-get diagnosis :source))
         (toolchain (plist-get diagnosis :toolchain))
         (paths (plist-get diagnosis :paths))
         (module (plist-get paths :module))
         (pending (plist-get paths :pending))
         (previous (plist-get paths :previous))
         (runtime (plist-get diagnosis :runtime))
         (last-build (plist-get diagnosis :last-build)))
    (insert (propertize "Ebox Native Module Status\n" 'face 'bold))
    (insert (format "Overall: %s\n\n"
                    (ebox-native-reflow--overall-status diagnosis)))
    (insert (propertize "Environment\n" 'face 'bold))
    (ebox-native-reflow--insert-status-row
     "Emacs target" (plist-get platform :system-configuration))
    (ebox-native-reflow--insert-status-row
     "Rust target" (plist-get platform :rust-target))
    (ebox-native-reflow--insert-status-row
     "Dynamic modules" (plist-get platform :dynamic-modules-p))
    (ebox-native-reflow--insert-status-row
     "Native sources" (plist-get source :complete-p))
    (ebox-native-reflow--insert-status-row
     "C compiler" (plist-get diagnosis :compiler))
    (ebox-native-reflow--insert-status-row
     "Rust toolchain" (and toolchain (plist-get toolchain :name)))
    (ebox-native-reflow--insert-status-row
     "Minimum Rust/Cargo" ebox-native-reflow--minimum-rust-version)
    (ebox-native-reflow--insert-status-row
     "Cargo" (and toolchain (plist-get toolchain :cargo-version)))
    (ebox-native-reflow--insert-status-row
     "rustc" (and toolchain (plist-get toolchain :rustc-version)))
    (insert "\n" (propertize "Paths\n" 'face 'bold))
    (ebox-native-reflow--insert-status-row
     "Configuration" (if (plist-get paths :default-p) "automatic" "custom"))
    (ebox-native-reflow--insert-status-row "Source" (plist-get source :directory))
    (ebox-native-reflow--insert-status-row "Build" (plist-get paths :build-directory))
    (ebox-native-reflow--insert-status-row "Module" (plist-get module :path))
    (ebox-native-reflow--insert-status-row "Installed" (plist-get module :exists))
    (ebox-native-reflow--insert-status-row "Pending" (plist-get pending :exists))
    (ebox-native-reflow--insert-status-row "Previous" (plist-get previous :exists))
    (insert "\n" (propertize "Current Emacs\n" 'face 'bold))
    (ebox-native-reflow--insert-status-row
     "Load attempted" (plist-get runtime :load-attempted-p))
    (ebox-native-reflow--insert-status-row
     "Module loaded" (plist-get runtime :available-p))
    (ebox-native-reflow--insert-status-row
     "Loaded path" (plist-get runtime :loaded-path))
    (ebox-native-reflow--insert-status-row
     "Load error" (plist-get runtime :load-error))
    (insert "\n")
    (when last-build
      (insert (propertize "Last Build\n" 'face 'bold))
      (ebox-native-reflow--insert-status-row
       "Status" (plist-get last-build :status))
      (ebox-native-reflow--insert-status-row
       "Phase" (plist-get last-build :phase))
      (ebox-native-reflow--insert-status-row
       "Installation" (plist-get last-build :installation))
      (ebox-native-reflow--insert-status-row
       "Restart required" (plist-get last-build :restart-required-p))
      (ebox-native-reflow--insert-status-row
       "Error" (plist-get last-build :error))
      (insert "\n"))
    (ebox-native-reflow--insert-issues
     "Errors" (plist-get diagnosis :errors))
    (ebox-native-reflow--insert-issues
     "Notices" (plist-get diagnosis :warnings))
    (insert (concat "Keys: g refresh status, b build/rebuild, "
                    "B clean rebuild, q quit.\n"))))

(defun ebox-native-reflow--status ()
  "Display native toolchain, installation, and runtime loading status."
  (interactive)
  (unless ebox-native-reflow--load-attempted-p
    (ebox-native-reflow-load))
  (let ((diagnosis (ebox-native--diagnose))
        (buffer (get-buffer-create "*Ebox Native Status*")))
    (with-current-buffer buffer
      (ebox-native-status-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (setq ebox-native-status--diagnosis diagnosis)
        (ebox-native-reflow--insert-status diagnosis)
        (goto-char (point-min))))
    (pop-to-buffer buffer)
    buffer))

(defun ebox-native-reflow-load ()
  "Load the optional native module and return non-nil on ABI success."
  (unless ebox-native-reflow--load-attempted-p
    (setq ebox-native-reflow--load-attempted-p t
          ebox-native-reflow--available-p nil
          ebox-native-reflow--load-error nil
          ebox-native-reflow--loaded-module-path nil
          ebox-native-reflow--loaded-module-hash nil)
    (let ((candidate (car (ebox-native-reflow--candidate-paths))))
      (condition-case err
          (progn
            (when candidate
              (ebox-native-reflow--promote-pending candidate))
            (if (not (and candidate (file-readable-p candidate)))
                (setq ebox-native-reflow--load-error 'module-not-found)
              (module-load candidate)
              (unless (and (fboundp 'ebox-native--module-version)
                           (equal (ebox-native--module-version)
                                  ebox-native-reflow-abi-version))
                (error "Ebox native module ABI mismatch"))
              (setq ebox-native-reflow--available-p t
                    ebox-native-reflow--loaded-module-path
                    (expand-file-name candidate)
                    ebox-native-reflow--loaded-module-hash
                    (ebox-native-reflow--file-sha256 candidate))))
        (error
         (setq ebox-native-reflow--load-error
               (error-message-string err))))))
  ebox-native-reflow--available-p)

(defun ebox-native-reflow-module-version ()
  "Return native module, IR, and tape versions as a plist."
  (when (ebox-native-reflow-load)
    (pcase (mapcar #'string-to-number
                   (split-string (ebox-native--module-version) ":" t))
      (`(,module ,ir ,tape)
       (list :module module :ir ir :tape tape)))))

(defun ebox-native-reflow-layout-ready-p ()
  "Return non-nil when the loaded module implements native layout."
  (and (ebox-native-reflow-load)
       (ebox-native--module-layout-ready-p)))

(defun ebox-native-reflow-runtime-report ()
  "Return exact evidence for the native module active in this Emacs."
  (let* ((ready (ebox-native-reflow-layout-ready-p))
         (module-abi
          (and ebox-native-reflow--available-p
               (ebox-native--module-version))))
    (list :available-p ebox-native-reflow--available-p
          :layout-ready-p (and ready t)
          :abi ebox-native-reflow-abi-version
          :module-abi module-abi
          :module-version (and module-abi
                               (ebox-native-reflow-module-version))
          :configured-module-path ebox-native-reflow-module-path
          :loaded-module-path ebox-native-reflow--loaded-module-path
          :loaded-module-hash ebox-native-reflow--loaded-module-hash
          :load-error ebox-native-reflow--load-error)))

(defun ebox-native-reflow--flex-size-payload (lines)
  "Encode normalized flex LINES for the pure native geometry kernel."
  (let ((payload (list (length lines))))
    (dolist (line lines)
      (setq payload (nconc payload (list (length line))))
      (dolist (item line)
        (let* ((props (plist-get item :props))
               (base (plist-get item :base))
               (hypothetical (plist-get item :hypothetical))
               (min-main (plist-get item :min-main))
               (max-main (plist-get item :max-main)))
          (setq payload
                (nconc
                 payload
                 (list (truncate base)
                       (truncate hypothetical)
                       (truncate (or min-main 0))
                       (and (numberp max-main) (truncate max-main))
                       (float (or (plist-get props :flex-grow) 0))
                       (float (or (plist-get props :flex-shrink) 0))))))))
    (vconcat payload)))

(defun ebox-native-reflow--read-flex-i64 (bytes position)
  "Read one nonnegative little-endian integer from BYTES at POSITION."
  (let ((value 0))
    (cl-loop for byte-offset from 0 below 8
             do
      (setq value
            (logior value
                    (ash (aref bytes (+ position byte-offset))
                         (* 8 byte-offset))))
             finally return value)))

(defun ebox-native-reflow-flex-size-lines (lines main-limit main-gap)
  "Return LINES with native target sizes, or nil when unsupported.
The native side receives only measured numeric geometry.  It never receives
Ebox nodes, identities, text, properties, or publication state."
  (when (and (fboundp 'ebox-native--module-flex-size-lines)
             (integerp main-limit)
             (integerp main-gap)
             (cl-every
              (lambda (line)
                (cl-every
                 (lambda (item)
                   (and (numberp (plist-get item :base))
                        (numberp (plist-get item :hypothetical))
                        (numberp (plist-get item :min-main))
                        (let ((max-main (plist-get item :max-main)))
                          (or (null max-main) (numberp max-main)))))
                 line))
              lines))
    (cl-incf ebox-native-reflow--flex-geometry-call-count)
    (let* ((payload (ebox-native-reflow--flex-size-payload lines))
           (bytes
            (ebox-native--module-flex-size-lines
             payload main-limit main-gap))
           (expected-bytes
            (* 8 (apply #'+ (mapcar #'length lines)))))
      (when (and (stringp bytes) (= (length bytes) expected-bytes))
        (let ((position 0)
              result)
          (dolist (line lines (nreverse result))
            (let (sized)
              (dolist (item line)
                (let ((copy (copy-sequence item)))
                  (plist-put
                   copy :target
                   (ebox-native-reflow--read-flex-i64 bytes position))
                  (setq position (+ position 8))
                  (push copy sized)))
              (push (nreverse sized) result))))))))

(cl-defun ebox-native-reflow-create-session
    (&key workers
          (max-jobs ebox-native-reflow-max-jobs)
          (max-results ebox-native-reflow-max-results)
          (max-result-bytes ebox-native-reflow-max-result-bytes))
  "Create one bounded private native session."
  (unless (ebox-native-reflow-load)
    (error "Ebox native reflow is unavailable: %S"
           ebox-native-reflow--load-error))
  (let* ((available (max 1 (num-processors)))
         (workers (or workers (max 1 (- available 2)))))
    (dolist (value (list workers max-jobs max-results max-result-bytes))
      (unless (and (integerp value) (> value 0))
        (error "Native reflow capacities must be positive integers: %S"
               value)))
    (ebox-native-reflow--make-session
     :handle (ebox-native--module-create-session
              workers max-jobs max-results max-result-bytes)
     :generation 0
     :layout-fragment-cache (make-hash-table :test 'equal)
     :layout-fragment-revision 0)))

(defun ebox-native-reflow-fork-session (session)
  "Return an unpublished native child of committed SESSION.
The Rust child owns fresh queues, workers, generation and pending state, and
shares only SESSION's immutable confirmed baseline.  Elisp compiler facts are
copied separately; no pending frame or registered Rust document is inherited."
  (let* ((source-handle (ebox-native-reflow--live-handle session))
         (fork
          (ebox-native-reflow--make-session
           :handle (ebox-native--module-fork-confirmed source-handle)
           :generation 0
           :layout-fragment-cache (make-hash-table :test 'equal)
           :layout-fragment-revision 0)))
    (condition-case err
        (progn
          (setf (ebox-native-reflow-session-styles fork)
                (ebox-native-reflow-session-styles session)
                (ebox-native-reflow-session-layout-package fork)
                (ebox-native-reflow-session-layout-package session)
                (ebox-native-reflow-session-layout-fragment-cache fork)
                (ebox-native-reflow-session-layout-fragment-cache session)
                (ebox-native-reflow-session-layout-fragment-index fork)
                (ebox-native-reflow-session-layout-fragment-index session)
                (ebox-native-reflow-session-layout-fragment-revision fork)
                (ebox-native-reflow-session-layout-fragment-revision session)
                (ebox-native-reflow-session-layout-style-index fork)
                (ebox-native-reflow-session-layout-style-index session)
                (ebox-native-reflow-session-layout-property-template-index fork)
                (ebox-native-reflow-session-layout-property-template-index
                 session)
                (ebox-native-reflow-session-layout-edge-index fork)
                (ebox-native-reflow-session-layout-edge-index session))
          fork)
      (error
       (ebox-native-reflow-release-session fork)
       (signal (car err) (cdr err))))))

(defun ebox-native-reflow--live-handle (session)
  "Return SESSION's live module handle or signal an error."
  (unless (and (ebox-native-reflow-session-p session)
               (not (ebox-native-reflow-session-released-p session))
               (ebox-native-reflow-session-handle session))
    (error "Native reflow session has been released"))
  (ebox-native-reflow-session-handle session))

(defun ebox-native-reflow--control-json (frames)
  "Return versioned control JSON for FRAMES plists."
  (unless (and (listp frames) frames)
    (error "Native reflow requires at least one frame"))
  (json-serialize
   (list :version 1
         :frames
         (vconcat
          (mapcar
           (lambda (frame)
             (let ((key (plist-get frame :key))
                   (payload (plist-get frame :payload))
                   (delay (or (plist-get frame :delay-ms) 0)))
               (unless (integerp key)
                 (error "Native reflow frame key must be an integer: %S" key))
               (unless (stringp payload)
                 (error "Native reflow frame payload must be a string"))
               (list :key key :payload payload :delay-ms delay)))
           frames)))))

(defun ebox-native-reflow--validate-property-template (properties label)
  "Validate opaque text PROPERTIES for LABEL."
  (unless (and (proper-list-p properties)
               (zerop (% (length properties) 2)))
    (error "Native reflow %s properties must be an even plist" label))
  (let ((tail properties))
    (while tail
      (let ((property (pop tail)))
        (unless (symbolp property)
          (error "Native reflow %s property name must be a symbol: %S"
                 label property))
        (when (or (eq property 'ebox-native-property-template-ids)
                  (memq property
                        ebox-native-reflow--unsafe-opaque-properties))
          (error "Native reflow %s cannot carry unsafe property %S"
                 label property))
        (pop tail)))))

(defun ebox-native-reflow--register-property-template (properties label)
  "Register opaque text PROPERTIES for LABEL and return its native id."
  (when properties
    (ebox-native-reflow--validate-property-template properties label)
    (when (and (hash-table-p ebox-native-reflow--compile-property-template-ids)
               (not (eq (hash-table-test
                         ebox-native-reflow--compile-property-template-ids)
                        'ebox-native-property-template)))
      (let ((index (make-hash-table :test 'ebox-native-property-template)))
        (maphash (lambda (entry id) (puthash entry id index))
                 ebox-native-reflow--compile-property-template-ids)
        (setq ebox-native-reflow--compile-property-template-ids index)))
    (let* ((owned-properties
            (cl-loop for (property value) on properties by #'cddr
                     append (list property
                                  ;; Native maps already belong to the source
                                  ;; or node snapshot.  Preserve their identity
                                  ;; so repeated registration can reuse an id.
                                  (if (keymapp value) value
                                    (ebox-text-property-value-copy value)))))
           (entry (list :kind (intern label)
                        :properties owned-properties))
           (missing (make-symbol "missing-property-template"))
           (existing
            (if ebox-native-reflow--compile-retained-registry-p
                (ebox-native-reflow--persistent-index-get
                 ebox-native-reflow--compile-property-template-index
                 entry missing t)
              (if (hash-table-p
                 ebox-native-reflow--compile-property-template-ids)
                (gethash
                 entry ebox-native-reflow--compile-property-template-ids
                 missing)
              (or (cl-position
                   entry ebox-native-reflow--compile-property-templates
                   :test #'ebox-native-reflow--property-template-equal-p)
                  missing)))))
      (if (not (eq existing missing))
          existing
        (let ((id (+ ebox-native-reflow--compile-property-template-base-count
                     (length ebox-native-reflow--compile-property-templates))))
          (setq ebox-native-reflow--compile-property-templates
                (append ebox-native-reflow--compile-property-templates
                        (list entry)))
          (when ebox-native-reflow--compile-retained-registry-p
            (setq ebox-native-reflow--compile-property-template-index
                  (ebox-native-reflow--persistent-index-put
                   ebox-native-reflow--compile-property-template-index
                   entry id nil t)))
          (when (hash-table-p
                 ebox-native-reflow--compile-property-template-ids)
            (puthash
             entry id ebox-native-reflow--compile-property-template-ids))
          id)))))

(defun ebox-native-reflow--compile-cluster (cluster &optional source-template-id)
  "Compile measured grapheme CLUSTER to strict JSON-ready IR."
  (append
   (list :text (plist-get cluster :text)
         :width (plist-get cluster :width)
         :cjk (if (plist-get cluster :cjk) t :false)
         :space (if (plist-get cluster :space) t :false)
         :pixel-space :false)
   (when source-template-id
     (list :source-template-id source-template-id))))

(defun ebox-native-reflow--display-space-width (properties)
  "Return the exact pixel-space width encoded by PROPERTIES, or nil."
  (when (and (equal (length properties) 2)
             (eq (car properties) 'display))
    (let ((display (cadr properties)))
      (when (and (consp display) (eq (car display) 'space))
        (let* ((width (plist-get (cdr display) :width))
               ;; Emacs display-space syntax is independent of author CSS:
               ;; a bare number counts character cells, a singleton pixels.
               (pixels (cond
                        ((numberp width) (* width (ebox--space-pixel-width)))
                        ((and (proper-list-p width) (= (length width) 1)
                              (numberp (car width)))
                         (car width)))))
          (and pixels
               (ebox-native-reflow--exact-size-integer pixels width)))))))

(defun ebox-native-reflow--compile-formatted-clusters (line)
  "Compile LINE while preserving exact pixel display spaces."
  (let ((position 0)
        (length (length line))
        clusters)
    (while (< position length)
      (let* ((properties (text-properties-at position line))
             (next (or (next-property-change position line) length)))
        (if properties
            (let ((width (ebox-native-reflow--display-space-width properties)))
              (unless (and width (>= width 0)
                           (string-blank-p
                            (substring-no-properties line position next)))
                (error "Native reflow unsupported formatted text properties"))
              (push (list :text " " :width width :cjk :false :space t
                          :pixel-space t)
                    clusters))
          (dolist (cluster
                   (append
                    (ebox--grapheme-clusters
                     (substring-no-properties line position next))
                    nil))
            (push (ebox-native-reflow--compile-cluster cluster) clusters)))
        (setq position next)))
    (vconcat (nreverse clusters))))

(defun ebox-native-reflow--compile-source-clusters (line)
  "Compile LINE while preserving arbitrary source text properties opaquely."
  (let ((position 0)
        (length (length line))
        clusters)
    (while (< position length)
      (let* ((properties (text-properties-at position line))
             (next (or (next-property-change position line) length))
             (template-id
              (ebox-native-reflow--register-property-template
               properties "source"))
             (plain (substring-no-properties line position next))
             (cache-key
              (list ebox-native-reflow--compile-display-signature
                    properties plain))
             (missing (make-symbol "native-source-clusters-missing"))
             (measured
              (gethash cache-key ebox-native-reflow--source-cluster-cache
                       missing)))
        (when (eq measured missing)
          (setq measured
                (vconcat
                 (mapcar
                  (lambda (cluster)
                    (setq cluster (copy-sequence cluster))
                    (plist-put cluster :text
                               (substring-no-properties
                                (plist-get cluster :text)))
                    (ebox-native-reflow--compile-cluster cluster))
                  (append
                   (ebox--grapheme-clusters
                    (substring line position next))
                   nil))))
          (when (>= (hash-table-count
                     ebox-native-reflow--source-cluster-cache)
                    ebox-native-reflow--source-cluster-cache-limit)
            (clrhash ebox-native-reflow--source-cluster-cache))
          (puthash cache-key measured
                   ebox-native-reflow--source-cluster-cache))
        ;; One native atom carries one opaque property template.  Splitting a
        ;; cluster at a property-run boundary would turn combining marks or
        ;; ZWJ tails into independent atoms that clipping/wrapping could lose.
        ;; Check the last measured cluster against the complete source, also
        ;; on cache hits; unsupported mixed-property clusters use Elisp layout.
        (when (and (< next length) (> (length measured) 0)
                   (> (ebox--grapheme-cluster-end
                       line (- next (length (plist-get
                                             (aref measured (1- (length measured)))
                                             :text))))
                      next))
          (error "Native reflow cannot split a grapheme across text property runs"))
        (dolist (cluster (append measured nil))
          (push (append (copy-sequence cluster)
                        (when template-id
                          (list :source-template-id template-id)))
                clusters))
        (setq position next)))
    (vconcat (nreverse clusters))))

(defun ebox-native-reflow--compile-text (text &optional formatted-p)
  "Compile TEXT to premeasured line and grapheme IR.
When FORMATTED-P is non-nil, preserve exact display spaces produced by KP."
  (list
   :lines
   (vconcat
    (mapcar
     (lambda (line)
       (list :clusters
             (if formatted-p
                 (ebox-native-reflow--compile-formatted-clusters line)
               (ebox-native-reflow--compile-source-clusters line))))
     (ebox-string-lines text)))))

(defun ebox-native-reflow--static-size-p (value)
  "Return non-nil when VALUE has no context dependency absent from native IR.
Font measurements are bound to the compiled display/style generation.
Containing-block and viewport measurements change between retained frames."
  (or (not (ebox-size-value-p value t))
      (not (cl-intersection
            '(percent viewport-width viewport-height)
            (ebox-size-dependencies value)))))

(defun ebox-native-reflow--require-static-size (value)
  "Return VALUE or decline native compilation of a contextual size."
  (unless (ebox-native-reflow--static-size-p value)
    (error "Native reflow uses Elisp for viewport or percentage size: %S" value))
  value)

(defun ebox-native-reflow--exact-size-integer (value source)
  "Return integral VALUE, or decline native compilation of SOURCE."
  (unless (and (numberp value) (= value (floor value)))
    (error "Native reflow uses Elisp for fractional geometry: %S" source))
  (floor value))

(defun ebox-native-reflow--compile-fixed-size (value axis &optional box)
  "Resolve fixed canonical VALUE for AXIS in BOX's measured font context.
The native ABI uses integral pixels horizontally and integral text lines
vertically.  Preserve exact values only; other geometry uses the Elisp path."
  (ebox-native-reflow--require-static-size value)
  (let* ((box (or box ebox-native-reflow--compile-size-node))
         (pixels (ebox--size-pixels
                  value box (if (eq axis 'vertical) 'height 'width))))
    (unless (numberp pixels)
      (error "Native reflow has no measured context for size: %S" value))
    (ebox-native-reflow--exact-size-integer
     (if (eq axis 'vertical)
         (/ (max 0 pixels) (float (ebox--size-line-height box)))
       (max 0 pixels))
     value)))

(defun ebox-native-reflow--compile-gap (value axis)
  "Compile gap VALUE to the native scalar for AXIS."
  (if (ebox-size-value-p value)
      (ebox-native-reflow--compile-fixed-size value axis)
    (or value 0)))

(defun ebox-native-reflow--compile-edge (box property)
  "Compile BOX's used PROPERTY edge without freezing relative geometry."
  (let ((source (plist-get box property)))
    (ebox-native-reflow--require-static-size source)
    (let ((value (or (ebox-get box property) 0)))
      (if (ebox-size-value-p source t)
          (ebox-native-reflow--exact-size-integer value source)
        (floor value)))))

(defun ebox-native-reflow--compile-height-expression (value &optional box)
  "Compile VALUE as signed line arithmetic in BOX's font context.
Viewport height retains the original frame reference in native evaluation."
  (let ((box (or box ebox-native-reflow--compile-size-node)))
    (cond
     ((eq (car-safe value) 'calc)
      (ebox-native-reflow--compile-height-expression (cadr value) box))
     ((memq (car-safe value) '(+ -))
      (list :kind (if (eq (car value) '+) "add" "subtract")
            :values (vconcat
                     (mapcar (lambda (operand)
                               (ebox-native-reflow--compile-height-expression
                                operand box))
                             (cdr value)))))
     (t
      (let* ((viewport-p (eq (car-safe value) 'vh))
             (amount
              (if viewport-p
                  (* (cadr value) (/ (float (frame-char-height))
                                    (ebox--size-line-height box)))
                (ebox-native-reflow--require-static-size value)
                (ebox-native-reflow--exact-size-integer
                 (/ (ebox--size-pixels value box 'height)
                    (float (ebox--size-line-height box)))
                 value)))
             (leaf (list :kind (if viewport-p "css-viewport-height" "lines")
                         :value (abs amount))))
        (if (< amount 0)
            (list :kind "subtract" :values (vector leaf))
          leaf))))))

(defun ebox-native-reflow--compile-size (value axis nil-kind &optional box)
  "Compile size VALUE for AXIS in BOX, using NIL-KIND when absent."
  (cond
   ((and (eq axis 'horizontal) (ebox-size-value-p value)
         (eq (car value) 'vw))
    (list :kind "css-viewport-width" :value (cadr value)))
   ((and (eq axis 'vertical) (ebox-size-value-p value)
         (memq 'viewport-height (ebox-size-dependencies value)))
    (ebox-native-reflow--compile-height-expression value box))
   ((ebox-size-value-p value)
    (list :kind (if (eq axis 'horizontal) "pixels" "lines")
          :value (ebox-native-reflow--compile-fixed-size value axis box)))
   ((and (eq axis 'vertical)
         (memq value '(min-content max-content fit-content stretch)))
    (error "Native reflow uses Elisp for intrinsic or stretch height: %S" value))
   ((null value)
    (if (member nil-kind '("pixels" "lines"))
        (list :kind nil-kind :value 0)
      (list :kind nil-kind)))
   ((numberp value)
    (list :kind (if (eq axis 'horizontal) "pixels" "lines")
          :value (floor value)))
   ((and (consp value) (null (cdr value)) (numberp (car value)))
    (list :kind (if (eq axis 'horizontal) "pixels" "lines")
          :value (floor (car value))))
   ((memq value '(auto none content min-content max-content fit-content
                       stretch contain viewport viewport-height))
    (list :kind (symbol-name value)))
   ((and (consp value)
         (memq (car value) '(viewport viewport-height))
         (null (cdr value)))
    (list :kind (symbol-name (car value))))
   ((and (eq axis 'horizontal)
         (consp value)
         (eq (car value) 'fit-content)
         (or (null (cdr value))
             (null (cddr value))))
    (append
     (list :kind "fit-content")
     (when (cadr value)
       (list :limit
             (ebox-native-reflow--compile-size
              (cadr value) axis "none")))))
   ((and (eq axis 'vertical)
         (consp value)
         (memq (car value) '(+ -))
         (cdr value))
    (list :kind (if (eq (car value) '+) "add" "subtract")
          :values
          (vconcat
           (mapcar
            (lambda (operand)
              (ebox-native-reflow--compile-size operand axis "none"))
            (cdr value)))))
   (t
    (error "Native reflow unsupported %s size: %S" axis value))))

(defun ebox-native-reflow--symbol-name (value fallback allowed label)
  "Return VALUE as an allowed string, or FALLBACK for nil."
  (let ((value (or value fallback)))
    (unless (memq value allowed)
      (error "Native reflow unsupported %s: %S" label value))
    (symbol-name value)))

(defun ebox-native-reflow--register-style (mode face)
  "Return the stable numeric id for a MODE and FACE operation."
  (let* ((entry (list :mode mode :face face))
         (missing (make-symbol "missing-native-style"))
         (existing
          (if ebox-native-reflow--compile-retained-registry-p
              (ebox-native-reflow--persistent-index-get
               ebox-native-reflow--compile-style-index entry missing)
            (or (cl-position entry ebox-native-reflow--compile-styles
                             :test #'equal)
                missing))))
    (if (not (eq existing missing))
        existing
      (prog1 (+ ebox-native-reflow--compile-style-base-count
                (length ebox-native-reflow--compile-styles))
          (setq ebox-native-reflow--compile-styles
                (append ebox-native-reflow--compile-styles
                        (list entry)))
          (when ebox-native-reflow--compile-retained-registry-p
            (setq ebox-native-reflow--compile-style-index
                  (ebox-native-reflow--persistent-index-put
                   ebox-native-reflow--compile-style-index entry
                   (+ ebox-native-reflow--compile-style-base-count
                      (1- (length ebox-native-reflow--compile-styles))))))))))

(defun ebox-native-reflow--compile-add-face-style (face)
  "Register additive FACE and return its id, or nil."
  (and face (ebox-native-reflow--register-style 'add face)))

(defun ebox-native-reflow--compile-foreground-face (color)
  "Return the serializable native face for Ebox foreground COLOR."
  (when color
    (cond
     ((ebox-paint-slot-p color) (ebox-paint-slot-face color))
     ((eq color 'ebox/default-foreground) '(:inherit default))
     (t (list :foreground color)))))

(defun ebox-native-reflow--compile-border-face-style (width color)
  "Register the set-face operation for a border of WIDTH and COLOR."
  (and (> width 0)
       (ebox-native-reflow--register-style
        'set (ebox-buffer-side-border-face color))))

(defun ebox-native-reflow--fixed-horizontal-pixels (value)
  "Return VALUE's fixed horizontal pixel count, or nil when responsive."
  (cond
   ((and (ebox-size-value-p value)
         (ebox-native-reflow--static-size-p value))
    (ebox-native-reflow--compile-fixed-size value 'horizontal))
   ((numberp value) (floor value))
   ((and (consp value) (null (cdr value)) (numberp (car value)))
    (floor (car value)))))

(defun ebox-native-reflow--compile-kp-content (box)
  "Freeze fixed-width KP BOX content through the exact Elisp formatter.
Knuth-Plass output can contain redistributed display spaces that Rust does not
recompute.  A fixed box remains invariant across viewport reflow, so compiling
that already formatted, unwrapped content is exact."
  (unless (ebox-native-reflow--fixed-horizontal-pixels
           (ebox-get box :width))
    (error "Native reflow requires a fixed width for kp wrapping"))
  (ebox--format-content-string box (or (ebox-get box :content) "")))

(defun ebox-native-reflow--transparent-stack-content-exact-p
    (box source-child)
  "Return non-nil when BOX may reuse exact preformatted SOURCE-CHILD lines.
This mirrors the static half of `ebox--render-transparent-preformatted-box'.
Rust still verifies the dynamic equal-width and nonempty-line proof per frame."
  (and (eq box ebox-native-reflow--compile-root-node)
       (eq (plist-get source-child :ebox-type) 'stack)
       (ebox-style-no-soft-wrap-p (ebox-get box :wrap-mode))
       (eq (ebox-get box :text-align) 'left)
       (eq (ebox-get box :vertical-align) 'top)
       (null (ebox-get box :height))
       (equal (or (ebox-get box :min-height) 0) 0)
       (null (ebox-get box :max-height))
       (eq (ebox-get box :overflow) 'scroll)
       (cl-every
        (lambda (key) (equal (or (ebox-get box key) 0) 0))
        '(:padding-left-pixel :padding-right-pixel
          :padding-top-height :padding-bottom-height
          :margin-left-pixel :margin-right-pixel
          :margin-top-height :margin-bottom-height
          :border-left-pixel :border-right-pixel))
       (= (ebox-get box :border-top-pixel) 0)
       (= (ebox-get box :border-bottom-pixel) 0)
       (null (ebox-get box :color))
       (null (ebox-get box :bgcolor))))

(defun ebox-native-reflow--simple-axis-align (value)
  "Return Flex IR alignment equivalent to simple-axis VALUE."
  (pcase value
    ('start "flex-start")
    ('end "flex-end")
    ((or 'center 'stretch) (symbol-name value))
    (_ (error "Native reflow unsupported Row/Column alignment: %S" value))))

(defun ebox-native-reflow--simple-axis-item-align (kind child cross-align)
  "Return CHILD alignment for simple-axis KIND and CROSS-ALIGN."
  (cond
   ((eq (plist-get child :ebox-kind) 'text) "flex-start")
   ((not (eq cross-align 'stretch))
    (ebox-native-reflow--simple-axis-align cross-align))
   (t
    (let ((cross-size (ebox-get child (if (eq kind 'row) :height :width))))
      (if (memq cross-size '(nil auto stretch))
          "stretch"
        "flex-start")))))

(defun ebox-native-reflow--compile-typed-axis-children
    (kind config children &optional fragments)
  "Compile canonical Row/Column CHILDREN for KIND and CONFIG.
The native IR represents this simple-axis layout as fixed Flex items so
cross-axis stretch and item gap remain explicit without legacy runtime nodes."
  (let* ((props (ebox-layout-config-props config))
         (gap (ebox-native-reflow--compile-gap
               (plist-get props :item-gap)
               (if (eq kind 'row) 'horizontal 'vertical)))
         (cross-align (plist-get props :cross-align))
         (row-p (eq kind 'row))
         (compiled-children
          (mapcar
           (lambda (child)
             (if fragments
                 (ebox-native-reflow--compiled-scene-child fragments child)
               (ebox-native-reflow--compile-node child)))
           children)))
    (if (and (memq kind '(row column))
             (equal gap 0) (eq cross-align 'stretch))
        ;; Default Row/Column are exactly Rust's simple axis algorithms:
        ;; children are top-aligned/padded on Row and share the known content
        ;; viewport on Column.  Sending this subset through Flex repeats
        ;; intrinsic measurement and distribution at every nesting level.
        (list :type (symbol-name kind)
              :children (vconcat compiled-children))
      (list
       :type "flex"
       :direction (symbol-name kind)
       :wrap "nowrap"
       :justify "flex-start"
       :align-items
       (ebox-native-reflow--simple-axis-align
        (plist-get props :cross-align))
       :align-content "stretch"
       ;; Row/Column are the complete child layout of their owning Box.  Their
       ;; inline axis therefore uses that Box's content viewport; `auto' would
       ;; collapse a Column to max-content and lose cross-axis stretch.
       :width (list :kind "stretch")
       :height (list :kind "auto")
       :row-gap (if row-p 0 gap)
       :column-gap (if row-p gap 0)
       :items
       (vconcat
        (cl-mapcar
         (lambda (child compiled)
           (list :node compiled
                 :order 0 :grow 0 :shrink 0
                 :basis (list :kind "auto")
                 :align-self
                 (ebox-native-reflow--simple-axis-item-align
                  kind child cross-align)))
         children compiled-children))))))

(defun ebox-native-reflow--grid-row-p (box)
  "Return non-nil when BOX has a native fixed/fractional row allocation."
  (let* ((config (plist-get box :ebox-layout-config))
         (props (and config (ebox-layout-config-props config)))
         (columns (plist-get props :grid-template-columns))
         (children (ebox-tree-node-children box)))
    (and (eq (and config (ebox-layout-config-kind config)) 'grid)
         columns (= (length columns) (length children))
         (null (plist-get props :grid-template-rows))
         (eq (plist-get props :grid-auto-flow) 'row)
         (memq (plist-get (plist-get props :grid-auto-rows) :kind) '(nil auto))
         (eq (plist-get props :justify-items) 'stretch)
         (eq (plist-get props :align-items) 'stretch)
         (eq (plist-get props :align-content) 'stretch)
         (memq (plist-get props :justify-content) '(normal start flex-start stretch))
         (memq (ebox-get box :height) '(nil auto))
         (memq (ebox-get box :min-height) '(nil auto))
         (memq (ebox-get box :max-height) '(nil none))
         (cl-every (lambda (track)
                     (or (eq (plist-get track :kind) 'fr)
                         (and (eq (plist-get track :kind) 'fixed)
                              (ebox-native-reflow--static-size-p (plist-get track :size)))))
                   columns)
         (cl-every
          (lambda (child)
            (and (or (eq (plist-get child :ebox-kind) 'text)
                     (and (eq (plist-get child :ebox-kind) 'box)
                          (memq (ebox-get child :position) '(nil static))
                          (eq (ebox-get child :width) 'stretch)
                          (eq (ebox-get child :overflow) 'hidden)
                          (memq (ebox-get child :min-width) '(nil auto))
                          (memq (ebox-get child :max-width) '(nil none))
                          (memq (ebox-get child :height) '(nil auto))
                          (memq (ebox-get child :min-height) '(nil auto))
                          (memq (ebox-get child :max-height) '(nil none))))
                 (null (plist-get child :grid-row))
                 (null (plist-get child :grid-column))
                 (memq (plist-get child :justify-self) '(nil auto stretch))
                 (memq (plist-get child :align-self) '(nil auto))
                 (zerop (or (plist-get child :order) 0))))
          children))))

(defun ebox-native-reflow--compile-grid-row (box &optional fragments)
  "Compile BOX's fixed/fractional Grid row with unchanged source ownership."
  (unless (ebox-native-reflow--grid-row-p box)
    (error "Native reflow requires a fixed/fractional single-row Grid with Text or stretched clipped Box cells"))
  (let* ((ebox-native-reflow--compile-size-node box)
         (props (ebox-layout-config-props (plist-get box :ebox-layout-config)))
         (children
          (mapcar
           (lambda (child)
             (let ((compiled (if fragments
                                 (ebox-native-reflow--compiled-scene-child fragments child)
                               (ebox-native-reflow--compile-node child))))
               (unless (or (equal (plist-get compiled :type) "text")
                           (cl-every (lambda (key) (zerop (plist-get compiled key)))
                                     '(:margin-left :margin-right :margin-top :margin-bottom)))
                 (error "Native Grid row requires cells without margins"))
               compiled))
           (ebox-tree-node-children box))))
    (list :type "grid-row"
          :columns
          (vconcat
           (mapcar
            (lambda (track)
              (if (eq (plist-get track :kind) 'fr)
                  (list :kind "fraction" :value (plist-get track :factor))
                (list :kind "fixed"
                      :value (ebox-native-reflow--compile-fixed-size
                              (plist-get track :size) 'horizontal box))))
            (plist-get props :grid-template-columns)))
          :column-gap (ebox-native-reflow--compile-gap
                       (plist-get props :column-gap) 'horizontal)
          :children (vconcat children))))

(defun ebox-native-reflow--compile-typed-box-child (box)
  "Compile canonical BOX's typed child layout, or return nil."
  (let* ((ebox-native-reflow--compile-size-node box)
         (config (plist-get box :ebox-layout-config))
         (kind (and config (ebox-layout-config-kind config)))
         (children (ebox-tree-node-children box)))
    (unless config
      (error "Native reflow canonical Box has no LayoutConfig"))
    (pcase kind
      ('normal
       (pcase children
         ('() nil)
         (`(,child) (ebox-native-reflow--compile-node child))
         (_ (error "Native reflow does not yet compile multi-child Normal Box"))))
      ((or 'row 'column)
       (ebox-native-reflow--compile-typed-axis-children
        kind config children))
      ('flex
       (ebox-native-reflow--compile-flex-inner
        (copy-sequence (ebox-layout-config-props config)) children))
      ('grid (ebox-native-reflow--compile-grid-row box))
      (_ (error "Native reflow unsupported LayoutConfig: %S" kind)))))

(defun ebox-native-reflow--compile-text-node (node)
  "Compile canonical Text NODE to the lightweight native Text IR."
  (when (eq (ebox-get node :visibility) 'hidden)
    (error "Native reflow delegates hidden Text to the Elisp renderer"))
  (let* ((region-id (ebox--ensure-region-id node))
         (content
          (ebox--propertize-typography
           (or (plist-get node :ebox-text-value)
               (ebox-get node :content)
               "")
           node))
         (typography-style
          (ebox-native-reflow--compile-add-face-style
           (append (ebox-buffer--font-face node)
                   (ebox-buffer--text-decoration-face node))))
         (foreground-style
          (ebox-native-reflow--compile-add-face-style
           (ebox-native-reflow--compile-foreground-face
            (ebox-get node :color))))
         (surface-template-id
          (ebox-native-reflow--register-property-template
           (ebox-interaction--node-surface-properties node) "text surface"))
         (wrap-mode (or (ebox-get node :wrap-mode) 'none)))
    (list :type "text"
          :region-id region-id
          :content
          (ebox-native-reflow--compile-text content)
          :typography-style (or typography-style :null)
          :foreground-style (or foreground-style :null)
          :surface-template-id (or surface-template-id :null)
          :wrap-mode
          (ebox-native-reflow--symbol-name
           wrap-mode 'none '(none word char) "Text wrap-mode"))))

(defun ebox-native-reflow--compile-box
    (box &optional child-override child-override-p child-resolved-p)
  "Compile normalized Ebox BOX to strict layout IR."
  (when (eq (ebox-get box :visibility) 'hidden)
    (error "Native reflow delegates hidden Box to the Elisp renderer"))
  (let* ((ebox-native-reflow--compile-size-node box)
         (typed-box-p (eq (plist-get box :ebox-kind) 'box))
         (typed-text-p (eq (plist-get box :ebox-kind) 'text))
         (typed-layout-kind
          (and typed-box-p
               (ebox-layout-config-kind
                (plist-get box :ebox-layout-config))))
         (_inline-children-proof
          ;; An inline Box composes its material children on one flow through
          ;; `ebox--render-normal-box-children', including soft wrapping at
          ;; child boundaries.  The native IR represents one fused child per
          ;; Box, so a Box with more than one child delegates to the Elisp
          ;; renderer instead of dropping the siblings.
          (when (and typed-box-p
                     (memq typed-layout-kind '(nil normal))
                     (cdr (ebox-tree-node-children box)))
            (error "Native reflow delegates an inline Box with multiple children to the Elisp renderer")))
         (source-child (plist-get box :ebox-content-node))
         (child (if (or child-override-p child-resolved-p)
                    child-override
                  (if typed-box-p
                      (ebox-native-reflow--compile-typed-box-child box)
                    (and source-child
                         (ebox-native-reflow--compile-node source-child)))))
         (wrap-mode (or (ebox-get box :wrap-mode) 'none))
         (kp-content
          (and (not child)
               (eq wrap-mode 'kp)
               (ebox-native-reflow--compile-kp-content box)))
         (region-id (ebox--ensure-region-id box))
         (padding-left (ebox-native-reflow--compile-edge box :padding-left-pixel))
         (padding-right (ebox-native-reflow--compile-edge box :padding-right-pixel))
         (padding-top (ebox-native-reflow--compile-edge box :padding-top-height))
         (padding-bottom (ebox-native-reflow--compile-edge box :padding-bottom-height))
         (margin-left (ebox-native-reflow--compile-edge box :margin-left-pixel))
         (margin-right (ebox-native-reflow--compile-edge box :margin-right-pixel))
         (margin-top (ebox-native-reflow--compile-edge box :margin-top-height))
         (margin-bottom (ebox-native-reflow--compile-edge box :margin-bottom-height))
         (border-left (ebox-native-reflow--compile-edge box :border-left-pixel))
         (border-right (ebox-native-reflow--compile-edge box :border-right-pixel))
         (border-top (ebox-native-reflow--compile-edge box :border-top-pixel))
         (border-bottom (ebox-native-reflow--compile-edge box :border-bottom-pixel))
         (_border-capability
          (when (or (> border-top 1) (> border-bottom 1))
            (signal 'ebox-surface-capability-error
                    (list :border '(top bottom)
                          :declared-pixels (max border-top border-bottom)
                          :supported-pixels '(0 1)))))
         (foreground-style
          (ebox-native-reflow--compile-add-face-style
           (ebox-native-reflow--compile-foreground-face
            (and (ebox-style--text-paint-owner-p box)
                 (ebox-get box :color)))))
         (typography-style
          (and (ebox-style--text-paint-owner-p box)
               (ebox-native-reflow--compile-add-face-style
                (append (ebox-buffer--font-face box)
                        (ebox-buffer--text-decoration-face box)))))
         (background-style
          (ebox-native-reflow--compile-add-face-style
           (let ((background (ebox-get box :bgcolor)))
             (cond
              ((ebox-paint-slot-p background)
               (ebox-paint-slot-face background))
              (background (list :background background))))))
         (border-left-style
          (ebox-native-reflow--compile-border-face-style
           border-left (ebox-get box :border-left-color)))
         (border-right-style
          (ebox-native-reflow--compile-border-face-style
           border-right (ebox-get box :border-right-color)))
         (border-top-style
          (and (> border-top 0)
               (ebox-native-reflow--compile-add-face-style
                (let ((color (ebox-get box :border-top-color)))
                  (if (ebox-paint-slot-p color)
                      (ebox-paint-slot-face color)
                    (list :overline (or color t)))))))
         (border-bottom-style
          (and (> border-bottom 0)
               (ebox-native-reflow--compile-add-face-style
                (let ((color (ebox-get box :border-bottom-color)))
                  (if (ebox-paint-slot-p color)
                      (ebox-paint-slot-face color)
                    (list :underline
                          (append (list :position t)
                                  (when color (list :color color)))))))))
         (surface-template-id
          (ebox-native-reflow--register-property-template
           (ebox-interaction--node-surface-properties box) "surface"))
         (fused-text-p
          (and typed-box-p
               (eq typed-layout-kind 'normal)
               (equal (plist-get child :type) "text"))))
    (list
     :type "box"
     :region-id region-id
     :content (cond
               (fused-text-p (plist-get child :content))
               (child :null)
               (t
                (ebox-native-reflow--compile-text
                 (or kp-content (ebox-get box :content) "")
                 (and kp-content t))))
     :content-region-id
     (if fused-text-p (plist-get child :region-id) :null)
     :content-typography-style
     (if fused-text-p (plist-get child :typography-style) :null)
     :content-foreground-style
     (if fused-text-p (plist-get child :foreground-style) :null)
     :content-surface-template-id
     (if fused-text-p (plist-get child :surface-template-id) :null)
     :child (if fused-text-p :null (or child :null))
     :content-width-exact
     (if (or child-override-p
             (memq typed-layout-kind '(row column flex grid))
             (ebox-native-reflow--transparent-stack-content-exact-p
              box source-child))
         t
       :false)
     :width (ebox-native-reflow--compile-size
             (if typed-text-p 'max-content (ebox-get box :width))
             'horizontal "auto")
     :min-width (ebox-native-reflow--compile-size
                 (ebox-get box :min-width) 'horizontal "auto")
     :max-width (ebox-native-reflow--compile-size
                 (ebox-get box :max-width) 'horizontal "none")
     :height (ebox-native-reflow--compile-size
              (ebox-get box :height) 'vertical "auto")
     :min-height (ebox-native-reflow--compile-size
                  (ebox-get box :min-height) 'vertical "auto")
     :max-height (ebox-native-reflow--compile-size
                  (ebox-get box :max-height) 'vertical "none")
     :box-sizing
     (ebox-native-reflow--symbol-name
      (ebox-get box :box-sizing) 'border-box
      '(border-box content-box) "box-sizing")
     :padding-left padding-left
     :padding-right padding-right
     :padding-top padding-top
     :padding-bottom padding-bottom
     :margin-left margin-left
     :margin-right margin-right
     :margin-top margin-top
     :margin-bottom margin-bottom
     :border-left border-left
     :border-right border-right
     :typography-style (or typography-style :null)
     :foreground-style (or foreground-style :null)
     :background-style (or background-style :null)
     :border-left-style (or border-left-style :null)
     :border-right-style (or border-right-style :null)
     :border-top-style (or border-top-style :null)
     :border-bottom-style (or border-bottom-style :null)
     :surface-template-id (or surface-template-id :null)
     :text-align
     (ebox-native-reflow--symbol-name
      (if kp-content 'left (ebox-get box :text-align))
      'left '(left center right) "text-align")
     :vertical-align
     (ebox-native-reflow--symbol-name
      (ebox-get box :vertical-align) 'top '(top center bottom)
      "vertical-align")
     :overflow
     (ebox-native-reflow--symbol-name
      (ebox-get box :overflow) 'scroll '(scroll hidden visible) "overflow")
     :wrap-mode
     (ebox-native-reflow--symbol-name
      (if kp-content 'none wrap-mode) 'none '(none word char) "wrap-mode")
     :scroll-offset (max 0 (floor (or (ebox-get box :scroll-offset) 0))))))

(defun ebox-native-reflow--compile-flex-align (value fallback label)
  "Compile flex alignment VALUE with FALLBACK for LABEL."
  (ebox-native-reflow--symbol-name
   value fallback
   '(auto normal stretch flex-start flex-end center start end self-start
          self-end left right top bottom baseline space-between space-around
          space-evenly)
   label))

(defun ebox-native-reflow--compile-flex-item
    (item axis &optional compiled-node compiled-node-p
          content-min-width content-min-width-p)
  "Compile flex ITEM metadata and source for AXIS."
  (let* ((source item)
         (props (ebox--flex-item-props item))
         (order (plist-get props :order))
         (grow (plist-get props :flex-grow))
         (shrink (plist-get props :flex-shrink))
         (compiled (if compiled-node-p
                       compiled-node
                     (ebox-native-reflow--compile-node source)))
         (missing (make-symbol "missing-native-content-min"))
         (captured-content-min
          (if (and (not content-min-width-p)
                   (hash-table-p ebox--flex-content-min-width-table))
              (gethash source ebox--flex-content-min-width-table missing)
            missing)))
    (unless (eq captured-content-min missing)
      (setq content-min-width captured-content-min
            content-min-width-p t))
    (unless (integerp order)
      (error "Native reflow flex order must be an integer: %S" order))
    (unless (and (numberp grow) (>= grow 0)
                 (numberp shrink) (>= shrink 0))
      (error "Native reflow flex factors must be nonnegative numbers"))
    ;; Rust consults this fact only for shrinkable wrapped boxes on a row
    ;; axis.  The ordinary flex renderer already measured it for the first
    ;; visible frame; a flat scene reuses that exact value instead of rendering
    ;; the source subtree again during native package construction.
    (when (and (eq axis 'row)
               (eq (plist-get source :ebox-type) 'box)
               (not (eq (plist-get source :ebox-kind) 'text))
               (ebox-style-soft-wrap-p (ebox-get source :wrap-mode))
                ;; A composite child already exists in the compiled fragment;
                ;; Rust derives its intrinsic minimum directly from that child
                ;; when the visible Elisp render did not measure it yet.
                (or content-min-width-p
                    (and (null (plist-get source :ebox-content-node))
                         (null (ebox-tree-node-children source)))))
      (unless content-min-width-p
        (setq content-min-width (ebox--content-min-pixel source)))
      (setq compiled
            (plist-put compiled :content-min-width
                       (max 0 (floor content-min-width)))))
    (list :node compiled
          :order order
          :grow grow
          :shrink shrink
          :basis
          (ebox-native-reflow--compile-size
           (plist-get props :flex-basis)
           (if (eq axis 'row) 'horizontal 'vertical)
           "auto" source)
          :align-self
          (if (eq (plist-get source :ebox-kind) 'text)
              "flex-start"
            (ebox-native-reflow--compile-flex-align
             (plist-get props :align-self) 'auto "align-self")))))

(defun ebox-native-reflow--compile-flex-inner
    (props items &optional fragments flex-content-min-widths)
  "Compile Flex PROPS and ITEMS to one backend-neutral native IR node."
  (let ((axis (ebox--flex-axis props)))
    (list
     :type "flex"
     :direction
     (ebox-native-reflow--symbol-name
      (plist-get props :flex-direction) 'row
      '(row row-reverse column column-reverse) "flex-direction")
     :wrap
     (ebox-native-reflow--symbol-name
      (plist-get props :flex-wrap) 'nowrap
      '(nowrap wrap wrap-reverse) "flex-wrap")
     :justify
     (ebox-native-reflow--compile-flex-align
      (plist-get props :justify-content) 'flex-start "justify-content")
     :align-items
     (ebox-native-reflow--compile-flex-align
      (plist-get props :align-items) 'stretch "align-items")
     :align-content
     (ebox-native-reflow--compile-flex-align
      (plist-get props :align-content) 'stretch "align-content")
     :width
     (ebox-native-reflow--compile-size
      (plist-get props :width) 'horizontal "auto")
     :height
     (ebox-native-reflow--compile-size
      (plist-get props :height) 'vertical "auto")
     :row-gap
     (ebox-native-reflow--compile-gap (plist-get props :row-gap) 'vertical)
     :column-gap
     (ebox-native-reflow--compile-gap (plist-get props :column-gap) 'horizontal)
     :items
     (vconcat
      (mapcar
       (lambda (item)
         (if fragments
             (let* ((source item)
                    (missing (make-symbol "missing-content-min"))
                    (content-min
                     (if flex-content-min-widths
                         (gethash source flex-content-min-widths missing)
                       missing)))
               (ebox-native-reflow--compile-flex-item
                item axis
                (ebox-native-reflow--compiled-scene-child fragments source)
                t content-min (not (eq content-min missing))))
           (ebox-native-reflow--compile-flex-item item axis)))
       items)))))

(defun ebox-native-reflow--compile-flex-content-props (node)
  "Return NODE's native Flex constraints without freezing relative gaps."
  (let* ((wrapper (plist-get node :box))
         (source (plist-get node :props))
         (_size-proof
          (dolist (property '(:width :height :row-gap :column-gap))
            (ebox-native-reflow--require-static-size
             (plist-get source property))))
         (props (ebox--flex-container-content-props
                 source (plist-get node :raw-props) wrapper)))
    (dolist (property '(:row-gap :column-gap))
      (when (plist-member source property)
        (plist-put props property (plist-get source property))))
    (when wrapper
      ;; The surrounding native box supplies its resolved content width to the
      ;; child for each frame.  Do not freeze the compiler's ambient viewport.
      (plist-put props :width nil)
      (when (plist-member (plist-get node :raw-props) :height)
        (plist-put props :height 'viewport-height)))
    props))

(defun ebox-native-reflow--compile-flex
    (node &optional fragments flex-content-min-widths)
  "Compile normalized legacy flex NODE through the shared Flex IR builder."
  (let* ((wrapper (plist-get node :box))
         (ebox-native-reflow--compile-size-node (or wrapper node))
         (props (ebox-native-reflow--compile-flex-content-props node)))
    (let ((inner
           (ebox-native-reflow--compile-flex-inner
            props (ebox-tree-layout-children node)
            fragments flex-content-min-widths)))
      (if wrapper
          (ebox-native-reflow--compile-box wrapper inner t)
        inner))))

(defun ebox-native-reflow--compile-node (node)
  "Compile supported normalized Ebox NODE to strict layout IR."
  (pcase (and (listp node) (plist-get node :ebox-type))
    ('box (if (eq (plist-get node :ebox-kind) 'text)
              (ebox-native-reflow--compile-text-node node)
            (ebox-native-reflow--compile-box node)))
    ('concat
     (list :type "row"
           :children
           (vconcat (mapcar #'ebox-native-reflow--compile-node
                            (ebox--layout-children node)))))
    ('stack
     (list :type "column"
           :children
           (vconcat (mapcar #'ebox-native-reflow--compile-node
                            (ebox--layout-children node)))))
    ('flex (ebox-native-reflow--compile-flex node))
    (_ (error "Native reflow unsupported node type: %S"
              (and (listp node) (plist-get node :ebox-type))))))

(defun ebox-native-reflow--height-expression-supported-p (value)
  "Return non-nil if VALUE has a native height expression representation."
  (or (ebox-native-reflow--static-size-p value)
      (eq (car-safe value) 'vh)
      (and (memq (car-safe value) '(calc + -))
           (cl-every #'ebox-native-reflow--height-expression-supported-p
                     (cdr value)))))

(defun ebox-native-reflow--node-sizes-supported-p (node)
  "Return non-nil if NODE's own sizes can survive retained native resize."
  (let ((config (plist-get node :ebox-layout-config)))
    (cl-every
     (lambda (properties)
       (cl-loop for (property value) on properties by #'cddr
                always
                (and
                 (or (not (memq property '(:height :min-height :max-height)))
                     (not (memq value
                                '(min-content max-content fit-content stretch))))
                 (or (not (memq property
                                '(:width :min-width :max-width
                                  :height :min-height :max-height :flex-basis
                                  :item-gap :row-gap :column-gap
                                  :padding-top-height :padding-bottom-height
                                  :padding-left-pixel :padding-right-pixel
                                  :margin-top-height :margin-bottom-height
                                  :margin-left-pixel :margin-right-pixel
                                  :border-top-pixel :border-bottom-pixel
                                  :border-left-pixel :border-right-pixel)))
                     (ebox-native-reflow--static-size-p value)
                     (and (memq property '(:width :min-width :max-width :flex-basis))
                          (eq (car-safe value) 'vw))
                     (and (memq property '(:height :min-height :max-height :flex-basis))
                          (ebox-native-reflow--height-expression-supported-p
                           value))))))
     (list node (plist-get node :props)
           (and config (ebox-layout-config-props config))))))

(defun ebox-native-reflow--native-node-supported-p (node)
  "Return non-nil when NODE contains only native-supported layout nodes.
Only a proven fixed/fractional Grid row uses native allocation; general
Grid retains the ordinary two-dimensional renderer."
  (cond
   ((or (null node) (stringp node) (not (listp node))) t)
   ((or (ebox-layer-host-p node) (ebox-layer-positioned-p node)) nil)
   ((eq (plist-get node :visibility) 'hidden) nil)
   ((not (ebox-native-reflow--node-sizes-supported-p node)) nil)
   ((plist-get node :ebox-child-sequence) nil)
   ((eq (plist-get node :ebox-type) 'grid) nil)
   ((eq (plist-get node :ebox-type) 'box)
    (if-let* ((config (and (eq (plist-get node :ebox-kind) 'box)
                            (plist-get node :ebox-layout-config))))
        (let ((kind (ebox-layout-config-kind config))
              (children (ebox-tree-node-children node)))
          (and
           (pcase kind
             ('normal (<= (length children) 1))
             ((or 'row 'column)
              t)
             ('flex t)
             ('grid (ebox-native-reflow--grid-row-p node))
             (_ nil))
           (cl-every #'ebox-native-reflow--native-node-supported-p children)))
      (and (not (plist-member node :children))
           (ebox-native-reflow--native-node-supported-p
            (plist-get node :ebox-content-node)))))
   ((memq (plist-get node :ebox-type) '(concat stack))
    (cl-every #'ebox-native-reflow--native-node-supported-p
              (ebox--layout-children node)))
   ((eq (plist-get node :ebox-type) 'flex)
    (cl-every #'ebox-native-reflow--native-node-supported-p
              (append (when-let* ((box (plist-get node :box)))
                        (list box))
                      (ebox-tree-layout-children node))))
   (t nil)))

(defun ebox-native-reflow--compile-typed-scene-child
    (box fragments flex-content-min-widths)
  "Compile typed BOX child layout from already compiled FRAGMENTS."
  (let* ((ebox-native-reflow--compile-size-node box)
         (config (plist-get box :ebox-layout-config))
         (kind (ebox-layout-config-kind config))
         (children (ebox-tree-node-children box)))
    (pcase kind
      ('normal
       (and children
            (ebox-native-reflow--compiled-scene-child
             fragments (car children))))
      ((or 'row 'column)
       (ebox-native-reflow--compile-typed-axis-children
        kind config children fragments))
      ('flex
       (ebox-native-reflow--compile-flex-inner
        (copy-sequence (ebox-layout-config-props config))
        children fragments flex-content-min-widths))
      ('grid (ebox-native-reflow--compile-grid-row box fragments))
      (_ (error "Native reflow unsupported typed scene LayoutConfig: %S"
                kind)))))

(defun ebox-native-reflow--compiled-scene-child (fragments node)
  "Return NODE's compiled fragment from FRAGMENTS, failing closed."
  (let ((missing (make-symbol "missing-native-scene-fragment")))
    (let ((fragment (gethash node fragments missing)))
      (when (eq fragment missing)
        (error "Native render scene is missing child node %S (%S/%S)"
               (plist-get node :node-id)
               (plist-get node :ebox-kind)
               (and (plist-get node :ebox-layout-config)
                    (ebox-layout-config-kind
                     (plist-get node :ebox-layout-config)))))
      fragment)))

(defun ebox-native-reflow--compile-scene-node
    (node fragments flex-content-min-widths)
  "Compile one flat scene NODE from already compiled FRAGMENTS."
  (pcase (and (listp node) (plist-get node :ebox-type))
    ('box
     (if (eq (plist-get node :ebox-kind) 'text)
         (ebox-native-reflow--compile-text-node node)
       (if (eq (plist-get node :ebox-kind) 'box)
         (ebox-native-reflow--compile-box
         node
          (ebox-native-reflow--compile-typed-scene-child
           node fragments flex-content-min-widths)
          nil t)
       (let ((child (plist-get node :ebox-content-node)))
         (ebox-native-reflow--compile-box
          node
          (and child
               (ebox-native-reflow--compiled-scene-child fragments child))
          nil t)))))
    ('concat
     (list :type "row"
           :children
           (vconcat
            (mapcar
             (lambda (child)
               (ebox-native-reflow--compiled-scene-child fragments child))
             (ebox--layout-children node)))))
    ('stack
     (list :type "column"
           :children
           (vconcat
            (mapcar
             (lambda (child)
               (ebox-native-reflow--compiled-scene-child fragments child))
             (ebox--layout-children node)))))
    ('flex
     (ebox-native-reflow--compile-flex
      node fragments flex-content-min-widths))
    (_ (error "Native reflow unsupported scene node type: %S"
              (and (listp node) (plist-get node :ebox-type))))))

(defun ebox-native-reflow--layout-package-from-root
    (root styles &optional property-templates document-revision)
  "Return one immutable native package from compiled ROOT and STYLES.
PROPERTY-TEMPLATES are Emacs-owned plists addressed by opaque native ids.
DOCUMENT-REVISION is the exact retained-input revision, defaulting to one."
  (list :document
        (list :version 2
              :space-width (ebox--space-pixel-width)
              :style-count (length styles)
              :property-template-count (length property-templates)
              :styles
              (vconcat
               (mapcar
                (lambda (descriptor)
                  (list :mode
                        (symbol-name (plist-get descriptor :mode))
                        ;; The Rust IR treats this compiler-produced literal
                        ;; as opaque style data and returns it by numeric id.
                        ;; `prin1-to-string' preserves every valid Emacs face
                        ;; form without leaking Lisp symbols into JSON.
                        :face
                        (list :lisp
                              (prin1-to-string
                               (plist-get descriptor :face)))))
                styles))
              :root root)
        :document-revision (or document-revision 1)
        :styles (vconcat styles)
        :property-templates (vconcat property-templates)))

(defun ebox-native-reflow--vector-elements-eq-p (left right)
  "Return non-nil when LEFT and RIGHT contain the same objects in order."
  (and (vectorp left)
       (vectorp right)
       (= (length left) (length right))
       (cl-loop for index below (length left)
                always (eq (aref left index) (aref right index)))))

(defun ebox-native-reflow--reuse-exact-layout-package (old candidate)
  "Return OLD when CANDIDATE has exactly the same immutable layout input.
Otherwise return CANDIDATE with the next document revision."
  (let ((old-document (plist-get old :document))
        (candidate-document (plist-get candidate :document)))
    (if (and old old-document candidate-document
             (eq (plist-get old-document :root)
                 (plist-get candidate-document :root))
             (equal (plist-get old-document :version)
                    (plist-get candidate-document :version))
             (equal (plist-get old-document :space-width)
                    (plist-get candidate-document :space-width))
             (equal (plist-get old-document :style-count)
                    (plist-get candidate-document :style-count))
             (equal (plist-get old-document :property-template-count)
                    (plist-get candidate-document
                               :property-template-count))
             (ebox-native-reflow--vector-elements-eq-p
              (plist-get old :styles) (plist-get candidate :styles))
             (ebox-native-reflow--vector-elements-eq-p
              (plist-get old :property-templates)
              (plist-get candidate :property-templates)))
        old
      (let ((replacement (copy-sequence candidate)))
        (plist-put replacement :document-revision
                   (1+ (or (plist-get old :document-revision) 0)))))))

(defun ebox-native-reflow--confirmed-layout-package (package)
  "Return PACKAGE without one-shot retained input transport fields."
  (if (plist-get package :document-delta)
      (let ((confirmed (copy-sequence package)))
        (dolist (key '(:document-delta :native-fragment-index
                       :native-fragment-revision :native-style-index))
          (cl-remf confirmed key))
        confirmed)
    package))

(defun ebox-native-reflow--buffer-display-signature (buffer)
  "Return BUFFER's live canonical Surface display capability."
  (with-current-buffer buffer
    (ebox--display-signature-for-window
     (ebox-surface--buffer-display-window buffer))))

(defun ebox-native-reflow-capture-layout-scene (buffer)
  "Capture BUFFER's render-owned flat native scene without walking its tree."
  (unless (buffer-live-p buffer)
    (error "Native layout scene needs a live buffer"))
  (let* ((state (ebox--buffer-render-state buffer))
         (root (and state (plist-get state :root-node)))
         (postorder (and state (plist-get state :native-node-postorder))))
    (unless (and root (vectorp postorder) (> (length postorder) 0)
                 (equal (plist-get root :node-id)
                        (let ((entry (aref postorder
                                           (1- (length postorder)))))
                          (if (and (listp entry)
                                   (plist-member entry :node-id))
                              (plist-get entry :node-id)
                            entry))))
      (error "Native layout scene is absent from the render transaction"))
    (with-current-buffer buffer
      (ebox-native-reflow--make-layout-scene
       :buffer buffer
       :render-state state
       :root root
       :node-postorder postorder
       :flex-content-min-widths
       (plist-get state :flex-content-min-widths)
       :display-signature (plist-get state :display-signature)
       :runtime-revision (or (plist-get state :runtime-revision) 0)))))

(defun ebox-native-reflow-layout-scene-new-builder (scene)
  "Return a fresh interruptible builder for captured layout SCENE."
  (unless (ebox-native-reflow-layout-scene-p scene)
    (error "Native layout builder needs a captured scene"))
  (ebox-native-reflow--make-layout-builder
   :scene scene
   :fragments (make-hash-table :test 'eq)
   :styles nil
   :index 0
   :flat-node-visits 0
   :tree-node-visits 0
   :string-pixel-width-cache (make-hash-table :test 'equal)
   :string-max-pixel-width-cache (make-hash-table :test 'eq)
   :property-templates nil
   :property-template-ids (make-hash-table :test 'ebox-native-property-template)))

(defun ebox-native-reflow--layout-builder-current-p (builder)
  "Return non-nil when BUILDER still identifies its live render scene."
  (let* ((scene (ebox-native-reflow-layout-builder-scene builder))
         (buffer (ebox-native-reflow-layout-scene-buffer scene)))
    (and (buffer-live-p buffer)
         (eq (ebox--buffer-render-state buffer)
             (ebox-native-reflow-layout-scene-render-state scene))
         (equal (ebox-native-reflow--buffer-display-signature buffer)
                (ebox-native-reflow-layout-scene-display-signature scene)))))

(defun ebox-native-reflow-layout-builder-step (builder budget-seconds)
  "Advance flat layout BUILDER for at most BUDGET-SECONDS.
Nil BUDGET-SECONDS drains the builder.  At least one source node is processed
per call, and no call recursively visits the captured Ebox tree."
  (unless (ebox-native-reflow-layout-builder-p builder)
    (error "Native layout builder state is invalid"))
  (or (ebox-native-reflow-layout-builder-package builder)
      (progn
        (unless (ebox-native-reflow--layout-builder-current-p builder)
          (error "Native layout scene became stale before compilation"))
        (let* ((scene (ebox-native-reflow-layout-builder-scene builder))
               (buffer (ebox-native-reflow-layout-scene-buffer scene))
               (nodes (ebox-native-reflow-layout-scene-node-postorder scene))
               (fragments
                (ebox-native-reflow-layout-builder-fragments builder))
               (started (float-time))
               processed-p)
          (ebox--with-buffer-render-context buffer
            (ebox--validate-display-cache)
            (let ((ebox--display-cache-validated t)
                  (ebox--render-display-signature
                   (ebox-native-reflow-layout-scene-display-signature scene))
                  (ebox--render-string-pixel-width-cache
                   (ebox-native-reflow-layout-builder-string-pixel-width-cache
                    builder))
                  (ebox--render-string-max-pixel-width-cache
                   (ebox-native-reflow-layout-builder-string-max-pixel-width-cache
                    builder))
                  (ebox-native-reflow--compile-styles
                   (ebox-native-reflow-layout-builder-styles builder))
                  (ebox-native-reflow--compile-property-templates
                   (ebox-native-reflow-layout-builder-property-templates
                    builder))
                  (ebox-native-reflow--compile-property-template-ids
                   (ebox-native-reflow-layout-builder-property-template-ids
                    builder))
                  (ebox-native-reflow--compile-root-node
                   (ebox-native-reflow-layout-scene-root scene)))
              (while
                  (and (< (ebox-native-reflow-layout-builder-index builder)
                          (length nodes))
                       (or (not processed-p)
                           (null budget-seconds)
                           (< (- (float-time) started) budget-seconds)))
                (let* ((index
                        (ebox-native-reflow-layout-builder-index builder))
                       (node
                        (ebox-native-reflow--postorder-node
                         (aref nodes index)
                         (plist-get
                          (ebox-native-reflow-layout-scene-render-state scene)
                          :node-table)))
                       (fragment
                        (ebox-native-reflow--compile-scene-node
                         node fragments
                         (ebox-native-reflow-layout-scene-flex-content-min-widths
                          scene))))
                  (puthash node fragment fragments)
                  (setf (ebox-native-reflow-layout-builder-index builder)
                        (1+ index)
                        (ebox-native-reflow-layout-builder-flat-node-visits
                         builder)
                        (1+ (ebox-native-reflow-layout-builder-flat-node-visits
                             builder)))
                  (setq processed-p t)))
              (setf (ebox-native-reflow-layout-builder-styles builder)
                    ebox-native-reflow--compile-styles)
              (setf (ebox-native-reflow-layout-builder-property-templates
                     builder)
                    ebox-native-reflow--compile-property-templates)
              (when (= (ebox-native-reflow-layout-builder-index builder)
                       (length nodes))
                (setf
                 (ebox-native-reflow-layout-builder-package builder)
                 (ebox-native-reflow--layout-package-from-root
                  (ebox-native-reflow--compiled-scene-child
                   fragments
                   (ebox-native-reflow-layout-scene-root scene))
                  ebox-native-reflow--compile-styles
                  ebox-native-reflow--compile-property-templates)))))
          (ebox-native-reflow-layout-builder-package builder)))))

(defun ebox-native-reflow--compile-layout-package
    (node &optional retained-styles retained-property-templates)
  "Compile NODE, extending optional retained native registries."
  (unless (fboundp 'ebox--grapheme-clusters)
    (error "Native reflow layout compiler requires Ebox"))
  (ebox--with-validated-display-cache
    (let* ((ebox-native-reflow--compile-styles
            (append retained-styles nil))
           (ebox-native-reflow--compile-property-templates
            (append retained-property-templates nil))
           (ebox-native-reflow--compile-property-template-ids
            (make-hash-table :test 'ebox-native-property-template))
          (ebox-native-reflow--compile-display-signature
           (ebox--current-display-signature))
          (ebox-native-reflow--compile-root-node node))
      (cl-loop
       for template in ebox-native-reflow--compile-property-templates
       for index from 0
       do (puthash template index
                   ebox-native-reflow--compile-property-template-ids))
      (let ((root (ebox-native-reflow--compile-node node)))
        (ebox-native-reflow--layout-package-from-root
         root ebox-native-reflow--compile-styles
         ebox-native-reflow--compile-property-templates)))))

(defun ebox-native-reflow--retained-layout-children (node)
  "Return NODE children referenced by one compiled native fragment."
  (pcase (plist-get node :ebox-type)
    ('box
     (if (eq (plist-get node :ebox-kind) 'box)
         (ebox-tree-node-children node)
       (when-let* ((child (plist-get node :ebox-content-node)))
         (list child))))
    ((or 'concat 'stack) (ebox--layout-children node))
    ('flex (ebox-tree-layout-children node))
    (_ nil)))

(defun ebox-native-reflow--retained-layout-postorder (root)
  "Return compiler-owned postorder for retained ROOT."
  (let (nodes)
    (cl-labels
        ((visit (node)
           (dolist (child
                    (ebox-native-reflow--retained-layout-children node))
             (visit child))
           (push node nodes)))
      (visit root))
    (vconcat (nreverse nodes))))

(defun ebox-native-reflow--retained-layout-signature
    (node child-revisions flex-content-min-widths source-index)
  "Return exact retained compiler signature for NODE and CHILD-REVISIONS."
  (let ((wrapper (and (eq (plist-get node :ebox-type) 'flex)
                      (plist-get node :box))))
    (list
     (plist-get node :ebox-type)
     (plist-get node :node-id)
     (or (plist-get node :region-id)
         (and wrapper (plist-get wrapper :region-id)))
     (ebox-tree-node-local-source-signature node)
     (and wrapper (ebox-tree-node-local-source-signature wrapper))
     (plist-get node :ebox-font-fact)
     (and wrapper (plist-get wrapper :ebox-font-fact))
     ebox-native-reflow--compile-display-signature
     (and source-index
          (when-let* ((handle (plist-get node :ebox-source-handle)))
            (ebox-source--index-record source-index handle)))
     (and source-index wrapper
          (when-let* ((handle (plist-get wrapper :ebox-source-handle)))
            (ebox-source--index-record source-index handle)))
     child-revisions
     (and (eq (plist-get node :ebox-type) 'flex)
          (mapcar
           (lambda (child)
             (and (hash-table-p flex-content-min-widths)
                  (gethash child flex-content-min-widths)))
           (ebox-native-reflow--retained-layout-children node))))))

(defun ebox-native-reflow--retained-layout-signature-equal-p (old new)
  "Compare OLD and NEW compiler signatures including native callback identity."
  (and (equal old new)
       ;; Positions 3 and 4 contain the node and optional flex-wrapper facts.
       ;; Keep existing structural comparison for immutable font/source records.
       (cl-loop for index in '(3 4)
                always (ebox-interaction-surface-equal-p
                        (plist-get (nth index old) :surface-properties)
                        (plist-get (nth index new) :surface-properties)))))

(defun ebox-native-reflow--retained-edge-rule (node)
  "Return NODE's exact child-edge lowering rule, or nil for plain edges."
  (let ((node-id (plist-get node :node-id))
        (ebox-native-reflow--compile-size-node node))
    (cond
     ((and (eq (plist-get node :ebox-type) 'box)
           (eq (plist-get node :ebox-kind) 'box))
      (let* ((config (plist-get node :ebox-layout-config))
             (kind (and config (ebox-layout-config-kind config)))
             (props (and config (ebox-layout-config-props config))))
        (pcase kind
          ('flex
           (list :parent-id node-id :slot 1 :kind 'flex-item
                 :axis (ebox--flex-axis props)))
          ((or 'row 'column)
           (if (and (zerop (ebox-native-reflow--compile-gap
                            (plist-get props :item-gap)
                            (if (eq kind 'row) 'horizontal 'vertical)))
                    (eq (plist-get props :cross-align) 'stretch))
               (list :parent-id node-id :slot 1 :kind 'direct-axis
                     :axis kind)
             (list :parent-id node-id :slot 1 :kind 'typed-axis-item
                   :axis kind :cross-align
                   (plist-get props :cross-align)))))))
     ((eq (plist-get node :ebox-type) 'flex)
      (let* ((wrapper (plist-get node :box))
             (props (plist-get node :props)))
        (list :parent-id node-id :slot (if wrapper 1 0) :kind 'flex-item
              :axis (ebox--flex-axis props)))))))

(defun ebox-native-reflow--retained-edge-item-local (item)
  "Return exact derived edge fields from compiled ITEM."
  (let* ((node (plist-get item :node))
         (local
          (cl-loop for (key value) on item by #'cddr
                   unless (eq key :node) append (list key value))))
    ;; Flex compilation may augment the edge's child view with this measured
    ;; scalar without changing the independently retained child fragment.
    (if (plist-member node :content-min-width)
        (append local
                (list :content-min-width
                      (plist-get node :content-min-width)))
      local)))

(defun ebox-native-reflow--postorder-node (entry node-table)
  "Resolve POSTORDER ENTRY through NODE-TABLE when it is a node id."
  (if (and (listp entry) (plist-member entry :ebox-type))
      entry
    (or (ebox-runtime-index-get entry node-table)
        (error "Native postorder references an absent node: %S" entry))))

(defun ebox-native-reflow--retained-edge-index
    (postorder cache &optional node-table)
  "Build exact child-edge facts from full POSTORDER fragments in CACHE.
Resolve node-ID entries through NODE-TABLE; legacy node plists need no index."
  (let (index)
    (cl-loop for entry across postorder
             for parent = (ebox-native-reflow--postorder-node
                           entry node-table)
             for parent-id = (plist-get parent :node-id)
             for rule = (ebox-native-reflow--retained-edge-rule parent)
             when rule do
             (setq index
                   (ebox-native-reflow--persistent-index-put
                    index (cons 'rule parent-id) rule))
             when (memq (plist-get rule :kind)
                        '(flex-item typed-axis-item)) do
             (let* ((entry (gethash parent-id cache))
                    (fragment (plist-get entry :fragment))
                    (inner (if (= (plist-get rule :slot) 1)
                               (plist-get fragment :child)
                             fragment))
                    (items (plist-get inner :items))
                    (children
                     (ebox-native-reflow--retained-layout-children parent)))
               (unless (= (length children) (length items))
                 (error "Native retained edge facts do not match children"))
               (cl-loop for child in children
                        for item across items
                        for position from 0 do
                        (setq index
                              (ebox-native-reflow--persistent-index-put
                               index
                               (cons 'child (plist-get child :node-id))
                               (append
                                (list :parent-id parent-id
                                      :slot (plist-get rule :slot)
                                      :item-position position)
                                (ebox-native-reflow--retained-edge-item-local
                                 item)))))))
    index))

(defun ebox-native-reflow--compile-retained-layout-package-full
    (session state node)
  "Compile a complete retained package for NODE in SESSION from STATE."
  (let ((postorder (plist-get state :native-node-postorder))
        (node-table (plist-get state :node-table)))
    (unless (and (vectorp postorder) (> (length postorder) 0))
      (setq postorder
            (ebox-native-reflow--retained-layout-postorder node)))
    (ebox--with-validated-display-cache
        (let* ((old-cache
                (or (ebox-native-reflow-session-layout-fragment-cache session)
                    (make-hash-table :test 'equal)))
               (fragments (make-hash-table :test 'eq))
               (revision
                (or (ebox-native-reflow-session-layout-fragment-revision session)
                    0))
               (flex-content-min-widths
                (plist-get state :flex-content-min-widths))
               (source-index (plist-get state :source-index))
               (touched-ids (plist-get state :native-touched-node-ids))
               (inherited-dirty-ids
                (plist-get state :native-inherited-dirty-node-ids))
               (touched-set
                (and (plist-member state :native-touched-node-ids)
                     (proper-list-p touched-ids)
                     ;; A structural native object delta still identifies the
                     ;; exact changed node partition.  Retain the compiled
                     ;; fragments for its untouched complement; only stable
                     ;; topology is required to reuse Ebox publication objects, not to reuse
                     ;; pure layout fragments.
                     (or (plist-get state :native-topology-stable-p)
                         (consp touched-ids))
                     (make-hash-table :test 'equal)))
               (inherited-touched-set
                (and touched-set inherited-dirty-ids
                     (make-hash-table :test 'equal)))
               (retained-fast-p
                (and touched-set
                     (= (hash-table-count old-cache) (length postorder))
                     (gethash (plist-get node :node-id) old-cache)))
               (new-cache
                (if retained-fast-p
                    (copy-hash-table old-cache)
                  (make-hash-table :test 'equal)))
               (postorder-id-set
                (let ((set (make-hash-table :test 'equal)))
                  (dotimes (index (length postorder))
                    (puthash
                     (plist-get
                      (ebox-native-reflow--postorder-node
                       (aref postorder index) node-table)
                      :node-id)
                             t set))
                  set))
               (ebox-native-reflow--compile-styles
                (append (ebox-native-reflow-session-styles session) nil))
               (ebox-native-reflow--compile-property-templates
                (append
                 (plist-get
                  (ebox-native-reflow-session-layout-package session)
                  :property-templates)
                 nil))
               (ebox-native-reflow--compile-property-template-ids
                (make-hash-table :test 'ebox-native-property-template))
               (ebox-native-reflow--compile-display-signature
                (ebox--current-display-signature))
               (ebox-native-reflow--compile-root-node node)
               (ebox--render-string-pixel-width-cache
                (make-hash-table :test 'equal))
               (ebox--render-string-max-pixel-width-cache
                (make-hash-table :test 'eq)))
          ;; Structural Range updates replace a bounded item partition.  The
          ;; untouched shell remains cache-valid, while departed item ids must
          ;; not accumulate and make the next update miss the retained-cache
          ;; cardinality proof.
          (when retained-fast-p
            (maphash
             (lambda (node-id _entry)
               (unless (gethash node-id postorder-id-set)
                 (remhash node-id new-cache)))
             new-cache))
          (dolist (node-id touched-ids)
            (when touched-set (puthash node-id t touched-set)))
          (when (and touched-set inherited-dirty-ids)
            (let ((inherited-set (make-hash-table :test 'equal)))
              (dolist (node-id inherited-dirty-ids)
                (puthash node-id t inherited-set))
              (cl-labels
                  ((mark
                    (current inherited-p)
                    (let* ((node-id (plist-get current :node-id))
                           (inherited-p
                            (or inherited-p (gethash node-id inherited-set))))
                      (when inherited-p (puthash node-id t touched-set))
                      (when inherited-p
                        (puthash node-id t inherited-touched-set))
                      (dolist (child
                               (ebox-native-reflow--retained-layout-children
                                current))
                        (mark child inherited-p)))))
                (mark node nil))))
          (cl-loop
           for template in ebox-native-reflow--compile-property-templates
           for index from 0
           do (puthash template index
                       ebox-native-reflow--compile-property-template-ids))
          (cl-labels
              ((seed-fragment
                (current)
                (let ((entry (gethash (plist-get current :node-id)
                                      new-cache)))
                  (unless entry
                    (error "Native retained layout cache lost a stable node"))
                  (puthash current (plist-get entry :fragment) fragments)
                  entry))
               (compile-current
                (current)
                (let* ((node-id (plist-get current :node-id))
                       (cached (gethash node-id old-cache))
                       (children
                        (ebox-native-reflow--retained-layout-children current))
                       (_seeded
                        (when retained-fast-p
                          (dolist (child children)
                            (seed-fragment child))))
                       (child-revisions
                        (mapcar
                         (lambda (child)
                           (plist-get
                            (gethash (plist-get child :node-id) new-cache)
                            :revision))
                         children))
                       (signature
                        (ebox-native-reflow--retained-layout-signature
                         current child-revisions flex-content-min-widths
                         source-index))
                       fragment entry)
                  (if (and cached
                           (not (and inherited-touched-set
                                     (gethash node-id inherited-touched-set)))
                           (ebox-native-reflow--retained-layout-signature-equal-p
                            signature (plist-get cached :signature)))
                      (setq fragment (plist-get cached :fragment)
                            entry cached)
                    (setq fragment
                          (ebox-native-reflow--compile-scene-node
                           current fragments flex-content-min-widths)
                          fragment (plist-put fragment :node-id node-id)
                          revision (1+ revision)
                          fragment (plist-put fragment :node-revision revision)
                          entry (list :signature signature
                                      :fragment fragment
                                      :revision revision)))
                  (puthash current fragment fragments)
                  (puthash node-id entry new-cache))))
            (dotimes (index (length postorder))
              (let* ((current
                      (ebox-native-reflow--postorder-node
                       (aref postorder index) node-table))
                     (node-id (plist-get current :node-id)))
                (if (and retained-fast-p
                         (not (gethash node-id touched-set)))
                    nil
                  (compile-current current))))
            (when retained-fast-p
              (seed-fragment node)))
          (let* ((candidate
                  (ebox-native-reflow--layout-package-from-root
                   (ebox-native-reflow--compiled-scene-child fragments node)
                   ebox-native-reflow--compile-styles
                   ebox-native-reflow--compile-property-templates))
                 (package
                  (ebox-native-reflow--reuse-exact-layout-package
                   (ebox-native-reflow-session-layout-package session)
                   candidate)))
            (setf (ebox-native-reflow-session-layout-fragment-cache session)
                  new-cache
                  (ebox-native-reflow-session-layout-fragment-index session)
                  (let (index)
                    (maphash
                     (lambda (node-id entry)
                       (setq index
                             (ebox-native-reflow--persistent-index-put
                              index node-id entry)))
                     new-cache)
                    index)
                  (ebox-native-reflow-session-layout-fragment-revision session)
                  revision
                  (ebox-native-reflow-session-layout-style-index session)
                  (ebox-native-reflow--persistent-index-from-sequence
                   (plist-get package :styles))
                  (ebox-native-reflow-session-layout-property-template-index
                   session)
                  (ebox-native-reflow--persistent-index-from-sequence
                   (plist-get package :property-templates) t)
                  (ebox-native-reflow-session-layout-edge-index session)
                  (ebox-native-reflow--retained-edge-index
                   postorder new-cache node-table))
            package)))))

(defconst ebox-native-reflow--delta-edge-fields
  '(:type :child :children :items :node-id :node-revision)
  "Fragment fields that a stable local node delta cannot replace.")

(defun ebox-native-reflow--current-edge-item-fact
    (state owner parent rule retained)
  "Return OWNER's current edge fact from STATE under PARENT.
RULE identifies the compiler lowering, and RETAINED supplies its stable slot."
  (let ((local
         (pcase (plist-get rule :kind)
           ('flex-item
            (let* ((widths (plist-get state :flex-content-min-widths))
                   (missing (make-symbol "missing-native-edge-width"))
                   (width (if (hash-table-p widths)
                              (gethash owner widths missing)
                            missing)))
              (ebox-native-reflow--retained-edge-item-local
               (ebox-native-reflow--compile-flex-item
                owner (plist-get rule :axis) nil t width
                (not (eq width missing))))))
           ('typed-axis-item
            (list :order 0 :grow 0 :shrink 0
                  :basis (list :kind "auto")
                  :align-self
                  (ebox-native-reflow--simple-axis-item-align
                   (plist-get rule :axis) owner
                   (plist-get rule :cross-align)))))))
    (and local
         (append
          (list :parent-id (plist-get parent :node-id)
                :slot (plist-get retained :slot)
                :item-position (plist-get retained :item-position))
          local))))

(defun ebox-native-reflow--delta-edge-change-p (session state index)
  "Return non-nil when STATE changes a retained derived edge in SESSION."
  (let ((edge-index (ebox-native-reflow-session-layout-edge-index session))
        (missing (make-symbol "missing-native-edge-fact"))
        (ids
         (append
          (mapcar (lambda (dirty) (plist-get dirty :node-id))
                  (plist-get state :native-local-dirty-entries))
          (plist-get state :native-touched-node-ids))))
  (cl-some
   (lambda (dirty-id)
     (let* ((parents (plist-get state :parent-table))
            (nodes (plist-get state :node-table))
            (owner-id
             (and nodes parents
                  (ebox-native-reflow--delta-owner-id state dirty-id index)))
            (owner (and owner-id (ebox-runtime-index-get owner-id nodes)))
            (parent-id (and owner-id (ebox-runtime-index-get owner-id parents)))
            (parent (and parent-id (ebox-runtime-index-get parent-id nodes)))
            (current-parent-rule
             (and parent (ebox-native-reflow--retained-edge-rule parent)))
            (retained-parent-rule
             (and parent-id
                  (ebox-native-reflow--persistent-index-get
                   edge-index (cons 'rule parent-id) missing)))
            (retained-item
             (and owner-id
                  (ebox-native-reflow--persistent-index-get
                   edge-index (cons 'child owner-id) missing)))
            (current-owner-rule
             (and owner (ebox-native-reflow--retained-edge-rule owner)))
            (retained-owner-rule
             (and owner-id
                  (ebox-native-reflow--persistent-index-get
                   edge-index (cons 'rule owner-id) missing))))
       (or (null owner)
           (not (equal current-owner-rule
                       (unless (eq retained-owner-rule missing)
                         retained-owner-rule)))
           (not (equal current-parent-rule
                       (unless (eq retained-parent-rule missing)
                         retained-parent-rule)))
           (if (memq (plist-get current-parent-rule :kind)
                     '(flex-item typed-axis-item))
               (or (eq retained-item missing)
                   (not
                    (equal
                     retained-item
                     (ebox-native-reflow--current-edge-item-fact
                      state owner parent current-parent-rule retained-item))))
             (not (eq retained-item missing))))))
   (delete-dups (copy-sequence ids)))))

(defun ebox-native-reflow--fragment-local (fragment)
  "Return FRAGMENT's scalar and local-content fields."
  (let ((tail fragment) local)
    (while tail
      (let ((key (pop tail))
            (value (pop tail)))
        (unless (memq key ebox-native-reflow--delta-edge-fields)
          (setq local (nconc local (list key value))))))
    local))

(defun ebox-native-reflow--local-difference (old new)
  "Return NEW local fields whose values differ from OLD."
  (let ((tail new) difference)
    (while tail
      (let ((key (pop tail))
            (value (pop tail)))
        (unless (equal value (plist-get old key))
          (setq difference (nconc difference (list key value))))))
    difference))

(defun ebox-native-reflow--apply-local-difference (fragment difference)
  "Return FRAGMENT with scalar fields from DIFFERENCE replaced."
  (let ((copy (copy-sequence fragment))
        (tail difference))
    (while tail
      (setq copy (plist-put copy (pop tail) (pop tail))))
    copy))

(defun ebox-native-reflow--delta-owner-id (state node-id index)
  "Return addressable owner for NODE-ID in STATE and retained INDEX."
  (let ((parents (plist-get state :parent-table))
        (nodes (plist-get state :node-table))
        (current node-id))
    (when-let* ((source (and nodes (ebox-runtime-index-get current nodes)))
                (parent-id (and parents (ebox-runtime-index-get current parents)))
                (parent (and nodes (ebox-runtime-index-get parent-id nodes))))
      (when (and (eq (plist-get source :ebox-kind) 'text)
                 (eq (plist-get parent :ebox-kind) 'box)
                 (eq (ebox-layout-config-kind
                      (plist-get parent :ebox-layout-config))
                     'normal))
        (setq current parent-id)))
    (while (and current
                (null (ebox-native-reflow--persistent-index-get
                       index current)))
      (setq current (and parents (ebox-runtime-index-get current parents))))
    current))

(defun ebox-native-reflow--compile-delta-slots (node old-fragment)
  "Compile NODE local slots while retaining OLD-FRAGMENT edges."
  (pcase (plist-get node :ebox-type)
    ('box
     (if (eq (plist-get node :ebox-kind) 'text)
         (vector (ebox-native-reflow--compile-text-node node))
       (let* ((ebox-native-reflow--compile-size-node node)
              (config (and (eq (plist-get node :ebox-kind) 'box)
                           (plist-get node :ebox-layout-config)))
              (kind (and config (ebox-layout-config-kind config)))
              (old-child
               (let ((child (plist-get old-fragment :child)))
                 ;; JSON null is an absent edge, not a compiled child.
                 (unless (eq child :null) child)))
              (fused-p (and (eq kind 'normal)
                            (let ((child (car (ebox-tree-node-children node))))
                              (and child
                                   (eq (plist-get child :ebox-kind) 'text)))))
              (inner
               (pcase kind
                 ((or 'row 'column)
                  (ebox-native-reflow--compile-typed-axis-children
                   kind config nil))
                 ('flex
                  (ebox-native-reflow--compile-flex-inner
                   (copy-sequence (ebox-layout-config-props config)) nil))
                 (_ nil)))
              (child (cond (fused-p
                            (ebox-native-reflow--compile-text-node
                             (car (ebox-tree-node-children node))))
                           (inner inner)
                           (t old-child)))
              (outer (ebox-native-reflow--compile-box node child nil t)))
         (if inner (vector outer inner) (vector outer)))))
    ('flex
     (let* ((wrapper (plist-get node :box))
            (ebox-native-reflow--compile-size-node (or wrapper node))
            (props (ebox-native-reflow--compile-flex-content-props node)))
       (let ((inner (ebox-native-reflow--compile-flex-inner props nil)))
         (if wrapper
             (vector (ebox-native-reflow--compile-box wrapper inner t) inner)
           (vector inner)))))
    (_ (vector old-fragment))))

(defun ebox-native-reflow--delta-direct-owner-ids (state index)
  "Return owners for STATE's direct dirty entries found in INDEX."
  (let ((seen (make-hash-table :test 'equal)) result)
    (dolist (dirty (plist-get state :native-local-dirty-entries))
      (when-let* ((owner
                   (ebox-native-reflow--delta-owner-id
                    state (plist-get dirty :node-id) index)))
        (unless (gethash owner seen)
          (puthash owner t seen)
          (push owner result))))
    (nreverse result)))

(defun ebox-native-reflow--compile-retained-layout-delta
    (session state node)
  "Return SESSION's local delta for NODE under STATE, or nil for fallback."
  (let* ((old-package (ebox-native-reflow-session-layout-package session))
         (old-index (ebox-native-reflow-session-layout-fragment-index session))
         (node-table (plist-get state :node-table))
         (touched (plist-get state :native-touched-node-ids)))
    (when (and old-package old-index (ebox-runtime-index-like-p node-table)
               (plist-get state :native-topology-stable-p)
               (plist-member state :native-local-dirty-entries)
               (not (ebox-native-reflow--delta-edge-change-p
                     session state old-index))
               ;; Grid track allocation is part of the parent's item records.
               ;; Rebuild when a Grid owner or a cell changes: cell chrome
               ;; contributes to its parent's basis, and eligibility depends
               ;; on cell sizing.  Scalar deltas cannot update those records.
               (not (cl-some
                     (lambda (id)
                       (let* ((parent-id (ebox-runtime-index-get
                                          id (plist-get state :parent-table)))
                              (owners (list (ebox-runtime-index-get id node-table)
                                            (and parent-id
                                                 (ebox-runtime-index-get
                                                  parent-id node-table)))))
                         (cl-some
                          (lambda (owner)
                            (let ((config (plist-get owner :ebox-layout-config)))
                              (eq (and config (ebox-layout-config-kind config)) 'grid)))
                          owners)))
                     touched))
               ;; Descendant inherited-style expansion needs its own bounded
               ;; affected-node index.  Until then it is an explicit full
               ;; input fallback rather than a partial semantic update.
               (null (plist-get state :native-inherited-dirty-node-ids)))
      (if (null touched)
          old-package
        (let* ((style-base (length (plist-get old-package :styles)))
               (template-base
                (length (plist-get old-package :property-templates)))
               (ebox-native-reflow--compile-styles nil)
               (ebox-native-reflow--compile-style-base-count style-base)
               (ebox-native-reflow--compile-style-index
                (ebox-native-reflow-session-layout-style-index session))
               (ebox-native-reflow--compile-property-templates nil)
               (ebox-native-reflow--compile-property-template-base-count
                template-base)
               (ebox-native-reflow--compile-property-template-index
                (ebox-native-reflow-session-layout-property-template-index
                 session))
               (ebox-native-reflow--compile-retained-registry-p t)
               (ebox-native-reflow--compile-display-signature
                (ebox--current-display-signature))
               (ebox-native-reflow--compile-root-node node)
               (ebox--render-string-pixel-width-cache
                (make-hash-table :test 'equal))
               (ebox--render-string-max-pixel-width-cache
                (make-hash-table :test 'eq))
               (direct (ebox-native-reflow--delta-direct-owner-ids
                        state old-index))
               (direct-set (make-hash-table :test 'equal))
               (entry-ids nil)
               (seen (make-hash-table :test 'equal))
               (new-index old-index)
               (revision
                (or (ebox-native-reflow-session-layout-fragment-revision
                     session) 0))
               entries unsupported)
          (dolist (id direct) (puthash id t direct-set))
          (dolist (id touched)
            (when-let* ((owner
                         (ebox-native-reflow--delta-owner-id state id old-index)))
              (unless (gethash owner seen)
                (puthash owner t seen)
                (push owner entry-ids))))
          (dolist (owner-id (nreverse entry-ids))
            (let* ((cached (ebox-native-reflow--persistent-index-get
                            old-index owner-id))
                   (old-fragment (plist-get cached :fragment))
                   (source (ebox-runtime-index-get owner-id node-table))
                   (expected (plist-get cached :revision))
                   patches new-fragment)
              (unless (and cached source (integerp expected))
                (setq unsupported t))
              (when (and (not unsupported) (gethash owner-id direct-set))
                (let ((slots
                       (ebox-native-reflow--compile-delta-slots
                        source old-fragment)))
                  (unless (equal (plist-get (aref slots 0) :type)
                                 (plist-get old-fragment :type))
                    (setq unsupported t))
                  (unless unsupported
                    (let ((local
                           (ebox-native-reflow--local-difference
                            (ebox-native-reflow--fragment-local old-fragment)
                            (ebox-native-reflow--fragment-local
                             (aref slots 0)))))
                      (when local
                        (push (list :slot 0 :local local) patches)
                        (setq new-fragment
                              (ebox-native-reflow--apply-local-difference
                               old-fragment local))))
                    (when (> (length slots) 1)
                      (let ((old-inner (plist-get old-fragment :child))
                            (new-inner (aref slots 1)))
                        (unless (equal (plist-get old-inner :type)
                                       (plist-get new-inner :type))
                          (setq unsupported t))
                        (unless unsupported
                          (let ((local
                                 (ebox-native-reflow--local-difference
                                  (ebox-native-reflow--fragment-local old-inner)
                                  (ebox-native-reflow--fragment-local new-inner))))
                            (when local
                              (push (list :slot 1 :local local) patches)
                              (let ((outer (or new-fragment
                                               (copy-sequence old-fragment))))
                                (plist-put
                                 outer :child
                                 (ebox-native-reflow--apply-local-difference
                                  old-inner local))
                                (setq new-fragment outer))))))))))
              (unless unsupported
                (setq revision (1+ revision))
                (unless new-fragment
                  (setq new-fragment (copy-sequence old-fragment)))
                (plist-put new-fragment :node-id owner-id)
                (plist-put new-fragment :node-revision revision)
                (let* ((entry
                        (append
                         (list :node-id owner-id
                               :expected-revision expected
                               :target-revision revision)
                         (when patches
                           (list :slot-patches (vconcat (nreverse patches))))))
                       (new-cache-entry
                        (list :signature nil
                              :fragment (or new-fragment old-fragment)
                              :revision revision)))
                  (push entry entries)
                  (setq new-index
                        (ebox-native-reflow--persistent-index-put
                         new-index owner-id new-cache-entry))))))
          (when (and (not unsupported)
                     ;; N1 can authenticate retained templates, but cannot
                     ;; append their Emacs-owned values to Rust atomically.
                     (= template-base
                        (+ template-base
                           (length ebox-native-reflow--compile-property-templates))))
            (let* ((styles-append ebox-native-reflow--compile-styles)
                   (styles
                    (if styles-append
                        ;; Materializing the global style output is explicitly
                        ;; outside retained input work; the common no-append
                        ;; path preserves the old vector by identity.
                        (vconcat (plist-get old-package :styles) styles-append)
                      (plist-get old-package :styles)))
                   (base (or (plist-get old-package :document-revision) 0))
                   (package (copy-sequence old-package)))
              (plist-put package :document-revision (1+ base))
              (plist-put package :styles styles)
              (plist-put
               package :document-delta
               (list :style-base-count style-base
                     :styles-append
                     (vconcat
                      (mapcar
                       (lambda (descriptor)
                         (list :mode (symbol-name (plist-get descriptor :mode))
                               :face
                               (list :lisp
                                     (prin1-to-string
                                      (plist-get descriptor :face)))))
                       styles-append))
                     :property-template-base-count template-base
                     :property-template-target-count template-base
                     :entries (vconcat (nreverse entries))))
              (plist-put package :native-fragment-index new-index)
              (plist-put package :native-fragment-revision revision)
              (plist-put package :native-style-index
                         ebox-native-reflow--compile-style-index)
              package)))))))

(defun ebox-native-reflow--compile-retained-layout-package
    (session state node)
  "Compile NODE for SESSION using a delta when STATE proves it supported."
  (or (ebox-native-reflow--compile-retained-layout-delta session state node)
      (ebox-native-reflow--compile-retained-layout-package-full
       session state node)))

(defun ebox-native-reflow-compile-layout-ir (node)
  "Compile NODE to one complete versioned native layout document."
  (plist-get (ebox-native-reflow--compile-layout-package node) :document))

(defun ebox-native-reflow--serialize-layout-control (control)
  "Serialize layout CONTROL without penalizing ordinary wide documents."
  (condition-case err
      (json-serialize control)
    (error
     (unless
         (equal (error-message-string err)
                "Maximum JSON serialization depth exceeded")
       (signal (car err) (cdr err)))
     (let ((json-false :false)
           (json-null :null))
       (encode-coding-string
        (json-encode control) 'utf-8-unix)))))

(defun ebox-native-reflow--layout-control-json
    (document frames &optional document-base-revision
              document-target-revision document-delta)
  "Return strict control JSON for optional layout DOCUMENT and FRAMES.
DOCUMENT-BASE-REVISION and DOCUMENT-TARGET-REVISION bind retained input.
DOCUMENT-DELTA is the stable-topology local replacement batch."
  (unless (and (listp frames) frames)
    (error "Native reflow requires at least one layout frame"))
  (let ((control
         (list
          :version 1
          :frames
          (vconcat
           (mapcar
            (lambda (frame)
              (let ((key (plist-get frame :key))
                    (viewport-width (plist-get frame :viewport-width))
                    (viewport-width-known
                     (if (plist-member frame :viewport-width-known)
                         (plist-get frame :viewport-width-known)
                       t))
                    (viewport-height (plist-get frame :viewport-height))
                    (root-width (or (plist-get frame :root-width)
                                    (plist-get frame :viewport-width)))
                    (root-width-override-p (plist-member frame :root-width))
                    (patch-p (plist-member frame :base-viewport-width))
                    (base-viewport-width
                     (plist-get frame :base-viewport-width))
                    (base-viewport-width-known
                     (if (plist-member frame :base-viewport-width-known)
                         (plist-get frame :base-viewport-width-known)
                       t))
                    (base-viewport-height
                     (plist-get frame :base-viewport-height))
                    (base-root-width
                     (or (plist-get frame :base-root-width)
                         (plist-get frame :base-viewport-width)))
                    (base-root-width-override-p
                     (plist-member frame :base-root-width))
                    (runtime-revision (or (plist-get frame :runtime-revision) 0))
                    (context-hash (or (plist-get frame :context-hash) 0))
                    (complete (if (plist-member frame :complete)
                                  (plist-get frame :complete)
                                t))
                    (root-metadata
                     (if (plist-member frame :root-metadata)
                         (plist-get frame :root-metadata)
                       t))
                    (scroll-producers (plist-get frame :scroll-producers))
                    (delay (or (plist-get frame :delay-ms) 0)))
                (unless (integerp key)
                  (error "Native reflow layout key must be an integer: %S" key))
                (unless (and (integerp viewport-width) (> viewport-width 0)
                             (integerp viewport-height) (> viewport-height 0))
                  (error "Native reflow layout viewport must be positive integers"))
                (unless (memq viewport-width-known '(t nil :false))
                  (error "Native reflow viewport-width-known flag must be boolean"))
                (unless (and (integerp root-width) (> root-width 0))
                  (error "Native reflow layout root width must be a positive integer"))
                (when patch-p
                  (unless (and (integerp base-viewport-width)
                               (> base-viewport-width 0)
                               (integerp base-viewport-height)
                               (> base-viewport-height 0)
                               (integerp base-root-width)
                               (> base-root-width 0))
                    (error "Native reflow patch base geometry must be positive integers")))
                (when patch-p
                  (unless (memq base-viewport-width-known '(t nil :false))
                    (error "Native reflow base viewport-width-known flag must be boolean")))
                (unless (and (integerp runtime-revision) (>= runtime-revision 0))
                  (error "Native reflow runtime revision must be nonnegative"))
                (unless (integerp context-hash)
                  (error "Native reflow context hash must be an integer"))
                (unless (memq complete '(t nil :false))
                  (error "Native reflow complete flag must be boolean"))
                (unless (memq root-metadata '(t nil :false))
                  (error "Native reflow root-metadata flag must be boolean"))
                (unless (memq scroll-producers '(t nil :false))
                  (error "Native reflow scroll-producers flag must be boolean"))
                (when (and (eq scroll-producers t) (not (eq complete t)))
                  (error "Native root scroll producer requires complete properties"))
                (append
                 (list :key key
                       :viewport-width viewport-width
                       :viewport-width-known
                       (if (eq viewport-width-known t) t :false)
                       :viewport-height viewport-height
                       :root-width root-width
                       :root-width-override
                       (if root-width-override-p t :false)
                       :patch (if patch-p t :false)
                       :runtime-revision runtime-revision
                       :context-hash context-hash
                       :complete (if (eq complete t) t :false)
                       :root-metadata
                       (if (eq root-metadata t) t :false)
                       :delay-ms delay)
                 (when (eq scroll-producers t)
                   (list :scroll-producers t))
                 (when patch-p
                   (list
                    :base-viewport-width base-viewport-width
                    :base-viewport-width-known
                    (if (eq base-viewport-width-known t) t :false)
                    :base-viewport-height base-viewport-height
                    :base-root-width base-root-width
                    :base-root-width-override
                    (if base-root-width-override-p t :false))))))
            frames)))))
    (when document-base-revision
      (setq control
            (plist-put control :document-base-revision
                       document-base-revision)))
    (when document-target-revision
      (setq control
            (plist-put control :document-target-revision
                       document-target-revision)))
    (when document
      (setq control (plist-put control :document document)))
    (when document-delta
      (setq control (plist-put control :document-delta document-delta)))
    (ebox-native-reflow--serialize-layout-control control)))

(defun ebox-native-reflow-submit-layout
    (session generation node frames &optional layout-package)
  "Compile NODE and submit all layout FRAMES for SESSION GENERATION.
LAYOUT-PACKAGE may reuse a caller-validated document for the same NODE."
  (unless (and (integerp generation) (>= generation 0))
    (error "Native reflow generation must be a nonnegative integer"))
  (let* ((old-package (ebox-native-reflow-session-layout-package session))
         (candidate-package
          (or layout-package
              (ebox-native-reflow--compile-layout-package
               node
               (ebox-native-reflow-session-styles session)
               (plist-get old-package :property-templates))))
         (document-delta (plist-get candidate-package :document-delta))
         (package
          (if document-delta
              candidate-package
            (ebox-native-reflow--reuse-exact-layout-package
             old-package candidate-package)))
         (register-layout-p
          (not (eq package
                   old-package)))
         (base-revision (or (plist-get old-package :document-revision) 0))
         (target-revision (or (plist-get package :document-revision)
                              (1+ base-revision)))
         (accepted
          (ebox-native--module-submit
           (ebox-native-reflow--live-handle session)
           generation
           (ebox-native-reflow--layout-control-json
            (and register-layout-p (not document-delta)
                 (plist-get package :document))
            frames base-revision target-revision document-delta))))
    (setf (ebox-native-reflow-session-generation session) generation)
    (setf (ebox-native-reflow-session-styles session)
          (plist-get package :styles))
    (setf (ebox-native-reflow-session-layout-package session)
          (ebox-native-reflow--confirmed-layout-package package))
    accepted))

(defun ebox-native-reflow--tape-cursor (payload &optional position)
  "Return a bounded binary cursor over unibyte tape PAYLOAD."
  (unless (and (stringp payload) (not (multibyte-string-p payload)))
    (error "Native reflow tape must be an unibyte string"))
  (vector payload (or position 0) (length payload)))

(defun ebox-native-reflow--tape-require (cursor count)
  "Require COUNT readable bytes at CURSOR and return its position."
  (let ((position (aref cursor 1))
        (end (aref cursor 2)))
    (unless (and (integerp count) (>= count 0)
                 (<= count (- end position)))
      (error "Native reflow tape is truncated"))
    position))

(defun ebox-native-reflow--tape-read-u16 (cursor)
  "Read one little-endian unsigned 16-bit value from CURSOR."
  (let* ((position (ebox-native-reflow--tape-require cursor 2))
         (bytes (aref cursor 0))
         (value (+ (aref bytes position)
                   (ash (aref bytes (1+ position)) 8))))
    (aset cursor 1 (+ position 2))
    value))

(defun ebox-native-reflow--tape-read-u8 (cursor)
  "Read one unsigned byte from CURSOR."
  (let* ((position (ebox-native-reflow--tape-require cursor 1))
         (value (aref (aref cursor 0) position)))
    (aset cursor 1 (1+ position))
    value))

(defun ebox-native-reflow--tape-read-u32 (cursor)
  "Read one little-endian unsigned 32-bit value from CURSOR."
  (let* ((position (ebox-native-reflow--tape-require cursor 4))
         (bytes (aref cursor 0))
         (value (+ (aref bytes position)
                   (ash (aref bytes (+ position 1)) 8)
                   (ash (aref bytes (+ position 2)) 16)
                   (ash (aref bytes (+ position 3)) 24))))
    (aset cursor 1 (+ position 4))
    value))

(defun ebox-native-reflow--tape-read-u64 (cursor)
  "Read one little-endian unsigned 64-bit value from CURSOR."
  (let* ((position (ebox-native-reflow--tape-require cursor 8))
         (bytes (aref cursor 0))
         (value 0))
    (dotimes (index 8)
      (setq value (+ value (ash (aref bytes (+ position index))
                                (* index 8)))))
    (aset cursor 1 (+ position 8))
    value))

(defun ebox-native-reflow--tape-read-i64 (cursor)
  "Read one little-endian signed 64-bit value from CURSOR."
  (let ((value (ebox-native-reflow--tape-read-u64 cursor)))
    (if (>= value #x8000000000000000)
        (- value #x10000000000000000)
      value)))

(defun ebox-native-reflow--tape-read-bytes (cursor count)
  "Read COUNT raw bytes from CURSOR."
  (let* ((position (ebox-native-reflow--tape-require cursor count))
         (end (+ position count))
         (bytes (substring (aref cursor 0) position end)))
    (aset cursor 1 end)
    bytes))

(defun ebox-native-reflow--tape-decode-utf8 (bytes label)
  "Strictly decode UTF-8 BYTES for LABEL."
  (let ((decoded
         (condition-case nil
             (decode-coding-string bytes 'utf-8 t)
           (error nil))))
    (unless (and decoded
                 (equal bytes (encode-coding-string decoded 'utf-8 t)))
      (error "Native reflow tape has invalid UTF-8 %s" label))
    decoded))

(defun ebox-native-reflow--tape-read-header (cursor styles expected)
  "Read and validate a fixed tape header from CURSOR.
STYLES is the Emacs-owned style vector and EXPECTED is an optional identity
plist supplied by the caller."
  (let* ((magic (ebox-native-reflow--tape-read-bytes cursor 4))
         (version (ebox-native-reflow--tape-read-u16 cursor))
         (flags (ebox-native-reflow--tape-read-u16 cursor))
         (header-length (ebox-native-reflow--tape-read-u32 cursor))
         (total-length (ebox-native-reflow--tape-read-u64 cursor))
         (session-id (ebox-native-reflow--tape-read-u64 cursor))
         (generation (ebox-native-reflow--tape-read-u64 cursor))
         (key (ebox-native-reflow--tape-read-i64 cursor))
         (runtime-revision (ebox-native-reflow--tape-read-u64 cursor))
         (context-hash (ebox-native-reflow--tape-read-i64 cursor))
         (viewport-width (ebox-native-reflow--tape-read-i64 cursor))
         (viewport-height (ebox-native-reflow--tape-read-i64 cursor))
         (root-width (ebox-native-reflow--tape-read-i64 cursor))
         (style-count (ebox-native-reflow--tape-read-u32 cursor))
         (line-count (ebox-native-reflow--tape-read-u32 cursor))
         (character-count (ebox-native-reflow--tape-read-u64 cursor))
         (body-length (ebox-native-reflow--tape-read-u64 cursor))
         (reserved (ebox-native-reflow--tape-read-u32 cursor))
         (ok-p (not (zerop (logand flags ebox-native-reflow--tape-flag-ok))))
         (complete-p
          (not (zerop (logand flags ebox-native-reflow--tape-flag-complete))))
         (patch-p
          (not (zerop (logand flags ebox-native-reflow--tape-flag-patch))))
         (header
          (list :session-id session-id :generation generation :key key
                :runtime-revision runtime-revision
                :context-hash context-hash
                :viewport-width viewport-width
                :viewport-height viewport-height :root-width root-width
                :style-count style-count :line-count line-count
                :character-count character-count :complete complete-p
                :patch patch-p :ok ok-p)))
    (unless (equal magic ebox-native-reflow--tape-magic)
      (error "Native reflow tape magic mismatch"))
    (unless (= version ebox-native-reflow--tape-version)
      (error "Native reflow tape version mismatch: %S" version))
    (unless (zerop (logand flags
                           (lognot
                            (logior ebox-native-reflow--tape-flag-ok
                                    ebox-native-reflow--tape-flag-complete
                                    ebox-native-reflow--tape-flag-patch))))
      (error "Native reflow tape has unknown flags"))
    (unless (= header-length ebox-native-reflow--tape-header-length)
      (error "Native reflow tape header length mismatch"))
    (unless (and (= total-length (aref cursor 2))
                 (= body-length (- total-length header-length)))
      (error "Native reflow tape byte length mismatch"))
    (unless (zerop reserved)
      (error "Native reflow tape header has reserved bits"))
    (unless (and (> session-id 0) (> viewport-width 0)
                 (> viewport-height 0) (> root-width 0))
      (error "Native reflow tape has invalid frame identity"))
    (dolist (field '(:session-id :generation :key :runtime-revision
                     :context-hash :viewport-width :viewport-height
                     :root-width :complete))
      (when (and expected (plist-member expected field)
                 (not (equal (plist-get expected field)
                             (plist-get header field))))
        (error "Native reflow tape identity mismatch for %S" field)))
    (if ok-p
        (progn
          (when (and (zerop line-count) (not (zerop character-count)))
            (error "Native reflow zero-line tape contains characters"))
          (unless (= style-count (length styles))
            (error "Native reflow tape style table mismatch")))
      (unless (and (zerop style-count) (zerop line-count)
                   (zerop character-count) (not patch-p))
        (error "Native reflow error tape has invalid counts")))
    header))

(defun ebox-native-reflow--tape-style-faces (styles)
  "Return validated face values represented by style vector STYLES."
  (mapcar
   (lambda (descriptor)
     (unless (and (listp descriptor)
                  (memq (plist-get descriptor :mode) '(set add))
                  (plist-member descriptor :face))
       (error "Native reflow has an invalid style descriptor"))
     (plist-get descriptor :face))
   (append styles nil)))

(defun ebox-native-reflow--tape-valid-face-p (face style-faces)
  "Return non-nil when FACE is composed only from STYLE-FACES."
  (or (cl-find face style-faces :test #'equal)
      (and (proper-list-p face)
           (> (length face) 1)
           (cl-every
            (lambda (entry)
              (cl-find entry style-faces :test #'equal))
            face))))

(defun ebox-native-reflow--property-template-symbols (property-templates)
  "Return property symbols allowed by PROPERTY-TEMPLATES."
  (let (symbols)
    (when property-templates
      (dotimes (index (length property-templates))
        (let ((tail (plist-get (aref property-templates index) :properties)))
          (ebox-native-reflow--validate-property-template
           tail "materialized")
          (while tail
            (cl-pushnew (pop tail) symbols)
            (pop tail)))))
    symbols))

(defun ebox-native-reflow--face-list (face)
  "Return FACE as a face property list preserving priority."
  (cond
   ((null face) nil)
   ((and (listp face) (not (keywordp (car face)))) face)
   (t (list face))))

(defun ebox-native-reflow--apply-source-face (rendered start end face)
  "Prepend source FACE to RENDERED from START to END."
  (let ((position start))
    (while (< position end)
      (let* ((next (or (next-single-property-change
                        position 'face rendered end)
                       end))
             (existing (get-text-property position 'face rendered))
             (combined
              (if existing
                  (append (ebox-native-reflow--face-list face)
                          (ebox-native-reflow--face-list existing))
                face)))
        (put-text-property position next 'face combined rendered)
        (setq position (max next (1+ position)))))))

(defun ebox-native-reflow--add-absent-nil-source-property
    (rendered start end property)
  "Add nil source PROPERTY only where RENDERED has no such property."
  (let ((position start))
    (while (< position end)
      (let* ((next (or (next-property-change position rendered end) end))
             (properties (text-properties-at position rendered)))
        (unless (plist-member properties property)
          (add-text-properties
           position next (list property nil) rendered))
        (setq position (max next (1+ position)))))))

(defun ebox-native-reflow--apply-property-template-span
    (rendered start end template)
  "Apply opaque TEMPLATE to RENDERED from START to END."
  (let ((kind (plist-get template :kind))
        (tail (plist-get template :properties)))
    (while tail
      (let ((property (pop tail))
            (value (pop tail))
            (position start))
        (if (and (eq kind 'source) (null value))
            (ebox-native-reflow--add-absent-nil-source-property
             rendered start end property)
          (if (not (eq kind 'source))
              (ebox-interaction--fill-property
               rendered start end property value)
            (when value
            (if (and (eq kind 'source) (eq property 'face))
                (ebox-native-reflow--apply-source-face
                 rendered start end value)
              (while (< position end)
                (let ((next (or (next-single-property-change
                                 position property rendered end)
                                end)))
                  (unless (get-text-property position property rendered)
                    (add-text-properties
                     position next (list property value) rendered))
                  (setq position (max next (1+ position)))))))))))))

(defun ebox-native-reflow--expand-property-templates
    (rendered property-templates)
  "Expand native opaque template ids in RENDERED using PROPERTY-TEMPLATES."
  (let ((position 0)
        (limit (length rendered))
        (template-count (and property-templates (length property-templates))))
    (while (< position limit)
      (let* ((ids
              (get-text-property
               position 'ebox-native-property-template-ids rendered))
             (next
              (or (next-single-property-change
                   position 'ebox-native-property-template-ids rendered limit)
                  limit)))
        (when ids
          (unless (and property-templates
                       (proper-list-p ids)
                       ids
                       (cl-every
                        (lambda (id)
                          (and (integerp id) (>= id 0)
                               (< id template-count)))
                        ids))
            (error "Native reflow tape has invalid property template ids"))
          (remove-text-properties
           position next '(ebox-native-property-template-ids nil) rendered)
          (dolist (id ids)
            (ebox-native-reflow--apply-property-template-span
             rendered position next (aref property-templates id))))
        (setq position next)))
    (ebox-interaction--refresh-hover! rendered 0 limit)))

(defun ebox-native-reflow--validate-literal-properties
    (rendered styles complete-p &optional property-templates)
  "Validate all text properties in RENDERED against STYLES and COMPLETE-P."
  (let ((style-faces (ebox-native-reflow--tape-style-faces styles))
        (template-symbols
         (ebox-native-reflow--property-template-symbols property-templates))
        (position 0)
        (limit (length rendered)))
    (while (< position limit)
      (let ((properties (text-properties-at position rendered)))
        (unless (and (proper-list-p properties)
                     (zerop (% (length properties) 2)))
          (error "Native reflow tape has a malformed property list"))
        (while properties
          (let ((property (pop properties))
                (value (pop properties)))
            (pcase property
              ((guard (memq property template-symbols))
               nil)
              ('face
               (unless (ebox-native-reflow--tape-valid-face-p
                        value style-faces)
                 (error "Native reflow tape has an invalid face value")))
              ('display
               (unless (and (proper-list-p value)
                            (= (length value) 3)
                            (eq (nth 0 value) 'space)
                            (eq (nth 1 value) :width)
                            (proper-list-p (nth 2 value))
                            (= (length (nth 2 value)) 1)
                            (integerp (car (nth 2 value)))
                            (>= (car (nth 2 value)) 0))
                 (error "Native reflow tape has an invalid display value")))
              ('ebox-content-idx
               (unless (and complete-p (integerp value) (>= value 0))
                 (error "Native reflow tape has an invalid content index")))
              ('ebox-content-owners
               (unless (and complete-p (proper-list-p value) value
                            (cl-every
                             (lambda (region-id)
                               (and (integerp region-id) (> region-id 0)))
                             value))
                 (error "Native reflow tape has an invalid owner stack")))
              ((or 'ebox-content 'ebox-content-owner 'ebox-scroll-window
                   'ebox-pl 'ebox-pr 'ebox-pt 'ebox-pb
                   'ebox-bl 'ebox-br 'ebox-bt 'ebox-bb
                   'ebox-ml 'ebox-mr 'ebox-mt 'ebox-mb)
               (unless (and complete-p (integerp value) (> value 0))
                 (error "Native reflow tape has an invalid region property")))
              (_
               (error "Native reflow tape has an unknown property: %S"
                      property)))))
      (setq position (next-property-change position rendered limit))))))

(defun ebox-native-reflow--patch-payload-metadata
    (metadata metadata-record-count target-character-count complete-p
              property-template-count style-count)
  "Validate patch METADATA against its declared record count."
  (cond
   ((null metadata)
    (unless (zerop metadata-record-count)
      (error "Native reflow patch metadata count has no payload"))
    nil)
   ((not complete-p)
    (error "Native reflow light tape contains root metadata"))
   ((> metadata-record-count most-positive-fixnum)
    (error "Native reflow tape has too many metadata records"))
   (t
    (ebox-native-reflow--validate-root-metadata
     metadata metadata-record-count target-character-count
     property-template-count style-count))))

(defun ebox-native-reflow--patch-payload-replacements (text descriptors)
  "Split aggregate patch TEXT into replacement strings for DESCRIPTORS."
  (let ((start 0)
        replacements)
    (dolist (patch descriptors (nreverse replacements))
      (let ((end (+ start (- (plist-get patch :new-end)
                             (plist-get patch :new-start)))))
        (let ((replacement (substring text start end)))
          (plist-put patch :replacement replacement)
          (push replacement replacements))
        (setq start end)))))

(defun ebox-native-reflow--tape-read-patch-payload
    (cursor descriptors styles complete-p target-character-count
            metadata-record-count trusted-native-encoder-p property-templates)
  "Read one aggregate patch payload vector from CURSOR."
  (let* ((literal (ebox-native-reflow--tape-decode-utf8
                   (ebox-native-reflow--tape-read-bytes
                    cursor (- (aref cursor 2) (aref cursor 1)))
                   "patch payload literal"))
         (read-circle t)
         (read-symbol-shorthands nil)
         (parsed
          (condition-case err
              (read-from-string literal)
            (error
             (error "Native reflow patch payload literal is invalid: %s"
                    (error-message-string err)))))
         (payload (car parsed)))
    (unless (= (cdr parsed) (length literal))
      (error "Native reflow patch payload literal has trailing data"))
    (unless (and (vectorp payload) (memq (length payload) '(2 3))
                 (stringp (aref payload 0)))
      (error "Native reflow patch payload shape mismatch"))
    (let* ((text (aref payload 0))
           (expected (cl-loop for patch in descriptors
                              sum (- (plist-get patch :new-end)
                                     (plist-get patch :new-start)))))
      (unless (= (length text) expected)
        (error "Native reflow patch replacement length mismatch"))
      (unless trusted-native-encoder-p
        (ebox-native-reflow--validate-literal-properties
         text styles complete-p property-templates))
      (ebox-native-reflow--expand-property-templates text property-templates)
      (list
       :replacements (ebox-native-reflow--patch-payload-replacements
                      text descriptors)
       :metadata
       (ebox-native-reflow--patch-payload-metadata
        (aref payload 1) metadata-record-count target-character-count
        complete-p (length property-templates) (length styles))
       :fragment-paint-delta
       (when (= (length payload) 3)
         (let ((delta (aref payload 2)) (previous -1))
           (unless (proper-list-p delta)
             (error "Native fragment paint delta is not a list"))
           (dolist (entry delta)
             (unless (and (proper-list-p entry) (= (length entry) 3)
                          (integerp (car entry)) (> (car entry) previous)
                          (proper-list-p (nth 1 entry))
                          (proper-list-p (nth 2 entry))
                          (cl-every
                           (lambda (id)
                             (and (integerp id) (>= id 0)
                                  (< id (length property-templates))))
                           (nth 1 entry))
                          (cl-every
                           (lambda (id)
                             (and (integerp id) (>= id 0)
                                  (< id (length styles))))
                           (nth 2 entry)))
               (error "Native fragment paint delta is invalid"))
             (setq previous (car entry)))
           delta))))))

(defun ebox-native-reflow--root-metadata-point-span-p
    (span character-count)
  "Return non-nil when SPAN is a valid one-based root point range."
  (and (consp span)
       (integerp (car span)) (integerp (cdr span))
       (<= 1 (car span)) (< (car span) (cdr span))
       (<= (cdr span) (1+ character-count))))

(defun ebox-native-reflow--validate-root-role-template
    (table character-count)
  "Validate root role TABLE and return its semantic record count."
  (unless (and (hash-table-p table) (eq (hash-table-test table) 'equal))
    (error "Native reflow tape has an invalid role metadata table"))
  (let ((count 0))
    (maphash
     (lambda (key spans)
       (unless (and (consp key) (consp (cdr key)) (null (cddr key))
                    (integerp (car key)) (> (car key) 0)
                    (memq (cadr key)
                          ebox-native-reflow--tape-metadata-role-symbols)
                    (consp spans))
         (error "Native reflow tape has invalid role metadata"))
       (while (consp spans)
         (unless (ebox-native-reflow--root-metadata-point-span-p
                  (car spans) character-count)
           (error "Native reflow tape has invalid role metadata"))
         (setq count (1+ count)
               spans (cdr spans)))
       (unless (null spans)
         (error "Native reflow tape has invalid role metadata")))
     table)
    count))

(defun ebox-native-reflow--validate-root-extent-template
    (table character-count)
  "Validate root extent TABLE and return its semantic record count."
  (unless (and (hash-table-p table) (eq (hash-table-test table) 'equal))
    (error "Native reflow tape has an invalid extent metadata table"))
  (maphash
   (lambda (region-id span)
     (unless (and (integerp region-id) (> region-id 0)
                  (ebox-native-reflow--root-metadata-point-span-p
                   span character-count))
       (error "Native reflow tape has invalid extent metadata")))
   table)
  (hash-table-count table))

(defun ebox-native-reflow--validate-root-scroll-template
    (table character-count)
  "Validate root scroll TABLE and return its semantic record count."
  (unless (and (hash-table-p table) (eq (hash-table-test table) 'equal))
    (error "Native reflow tape has an invalid scroll metadata table"))
  (let ((count 0))
    (maphash
     (lambda (region-id records)
       (unless (and (integerp region-id) (> region-id 0)
                    (consp records))
         (error "Native reflow tape has invalid scroll metadata"))
       (while (consp records)
         (let ((record (car records)))
         (unless (and (consp record) (integerp (car record))
                      (>= (car record) 0) (consp (cdr record))
                      (integerp (cadr record)) (>= (cadr record) 0)
                      (integerp (cddr record))
                      (< (cadr record) (cddr record))
                      (<= (cddr record) character-count))
             (error "Native reflow tape has invalid scroll metadata")))
         (setq count (1+ count)
               records (cdr records)))
       (unless (null records)
         (error "Native reflow tape has invalid scroll metadata")))
     table)
    count))

(defun ebox-native-reflow--validate-root-fragment-template
    (template character-count property-template-count style-count)
  "Validate compact root fragment TEMPLATE and return its record count."
  (unless (vectorp template)
    (error "Native reflow tape has an invalid fragment template"))
  (let ((cursor 0)
        (previous-line 0)
        (allowed-roles ebox-native-reflow--tape-metadata-role-symbols))
    (dotimes (index (length template))
      (let ((record (aref template index)))
        (unless (and (vectorp record) (= (length record) 8))
          (error "Native reflow tape has an invalid fragment record"))
        (let ((start (aref record 0))
              (end (aref record 1))
              (line (aref record 2))
              (roles (aref record 3))
              (content-owner (aref record 4))
              (content-index (aref record 5))
              (template-ids (aref record 6))
              (style-ids (aref record 7))
              (seen (make-hash-table :test #'equal)))
          (unless (and (integerp start) (integerp end)
                       (= start cursor) (< start end)
                       (<= end character-count)
                       (integerp line) (<= previous-line line))
            (error "Native reflow tape fragment coordinates are invalid"))
          (unless (proper-list-p roles)
            (error "Native reflow tape fragment roles are invalid"))
          (dolist (role roles)
            (unless (and (consp role) (memq (car role) allowed-roles)
                         (integerp (cdr role)) (> (cdr role) 0)
                         (not (gethash role seen)))
              (error "Native reflow tape fragment role is invalid"))
            (puthash role t seen))
          (unless (or (null content-owner)
                      (and (integerp content-owner) (> content-owner 0)))
            (error "Native reflow tape fragment owner is invalid"))
          (unless (or (null content-index)
                      (and (integerp content-index) (>= content-index 0)))
            (error "Native reflow tape fragment content index is invalid"))
          (unless (and (proper-list-p template-ids)
                       (cl-every
                        (lambda (template-id)
                          (and (integerp template-id) (>= template-id 0)
                               (< template-id property-template-count)))
                        template-ids))
            (error "Native reflow tape fragment property template is invalid"))
          (unless (and (proper-list-p style-ids)
                       (cl-every
                        (lambda (style-id)
                          (and (integerp style-id) (>= style-id 0)
                               (< style-id style-count)))
                        style-ids))
            (error "Native reflow tape fragment style is invalid"))
          (setq cursor end
                previous-line line))))
    (unless (= cursor character-count)
      (error "Native reflow tape fragment template is incomplete"))
    (length template)))

(defun ebox-native-reflow--validate-root-metadata
    (metadata record-count character-count _property-template-count
              &optional _style-count)
  "Validate precompiled METADATA against its declared dimensions."
  (pcase metadata
    (`(:prepared-p t
       :role-span-template ,roles
       :box-extent-template ,extents
       :scroll-content-span-template ,scroll
       :scroll-window-p ,(and window-p (or 'nil 't)) . ,extra)
     (unless (or (null extra)
                 (and (proper-list-p extra) (= (length extra) 2)
                      (eq (car extra) :scroll-producers)
                      (vectorp (cadr extra))))
       (error "Native reflow tape has invalid root scroll metadata"))
     (let ((actual-count
            (+ (ebox-native-reflow--validate-root-role-template
                roles character-count)
               (ebox-native-reflow--validate-root-extent-template
                extents character-count)
               (ebox-native-reflow--validate-root-scroll-template
                scroll character-count)
               (if window-p 1 0)
               (if extra (length (cadr extra)) 0))))
       (unless (= actual-count record-count)
         (error "Native reflow tape metadata record count mismatch")))
     metadata)
    (_
     (error "Native reflow tape has invalid prepared root metadata"))))

(defun ebox-native-reflow--decode-scroll-producers
    (metadata styles property-templates &optional allow-reuse-p)
  "Decode METADATA's complete scroll content, indexed by owning region."
  (when-let* ((encoded-plans (plist-get metadata :scroll-producers)))
    (unless (vectorp encoded-plans)
      (error "Native scroll producers must be a vector"))
    (let ((producers (make-hash-table :test 'equal)))
      (seq-doseq (encoded encoded-plans)
        (unless (and (vectorp encoded) (= (length encoded) 6)
                     (integerp (aref encoded 0)) (> (aref encoded 0) 0)
                     (not (gethash (aref encoded 0) producers))
                     (integerp (aref encoded 1)) (>= (aref encoded 1) 0)
                     (integerp (aref encoded 2)) (>= (aref encoded 2) 0)
                     (integerp (aref encoded 3)) (>= (aref encoded 3) 0)
                     (<= (aref encoded 3)
                         (max 0 (- (aref encoded 1) (aref encoded 2)))))
          (error "Native scroll producer has invalid ownership or geometry"))
        (let ((producer (copy-sequence encoded)))
          (unless (or (and (<= (aref encoded 1) (aref encoded 2))
                           (eq (aref encoded 4) :inactive)
                           (eq (aref encoded 5) :inactive))
                      (and allow-reuse-p (> (aref encoded 1) (aref encoded 2))
                           (eq (aref encoded 4) :reuse)
                           (eq (aref encoded 5) :reuse)))
            (dolist (index '(4 5))
              (let* ((literal (aref encoded index))
                     (read-circle t)
                     (read-symbol-shorthands nil)
                     (parsed (and (stringp literal) (read-from-string literal)))
                     (rendered (car parsed)))
                (unless (and (stringp rendered) (= (cdr parsed) (length literal))
                             (= (length (ebox-string-lines rendered))
                                (aref encoded 1)))
                  (error "Native scroll producer has invalid complete content"))
                (ebox-native-reflow--expand-property-templates rendered property-templates)
                (ebox-native-reflow--validate-literal-properties
                 rendered styles t property-templates)
                (aset producer index (ebox-string-lines rendered)))))
          (puthash (aref producer 0) producer producers)))
      (plist-put metadata :scroll-producers producers)))
  metadata)

(defun ebox-native-reflow--tape-read-root-metadata
    (cursor metadata-byte-count record-count character-count complete-p
            property-template-count style-count
            &optional _trusted-native-encoder-p)
  "Read and validate one precompiled root metadata literal from CURSOR."
  (cond
   ((zerop metadata-byte-count)
    (unless (zerop record-count)
      (error "Native reflow tape metadata count has no payload"))
    nil)
   ((not complete-p)
    (error "Native reflow light tape contains root metadata"))
   ((> record-count most-positive-fixnum)
    (error "Native reflow tape has too many metadata records"))
   (t
    (let* ((bytes (ebox-native-reflow--tape-read-bytes
                   cursor metadata-byte-count))
           (literal (ebox-native-reflow--tape-decode-utf8
                     bytes "root metadata"))
           (read-circle t)
           (read-symbol-shorthands nil)
           (parsed
            (condition-case err
                (read-from-string literal)
              (error
               (error "Native reflow root metadata is invalid: %s"
                      (error-message-string err)))))
           (metadata (car parsed)))
      (unless (= (cdr parsed) (length literal))
        (error "Native reflow root metadata has trailing data"))
      (ebox-native-reflow--validate-root-metadata
       metadata record-count character-count property-template-count
       style-count)))))

(defun ebox-native-reflow--fragment-role-symbol (kind)
  "Return the semantic role symbol encoded by fragment KIND."
  (and (integerp kind) (<= 1 kind 14)
       (nth (1- kind) ebox-native-reflow--tape-metadata-role-symbols)))

(defun ebox-native-reflow--fragment-template-from-flat
    (flat record-count character-count property-template-count style-count)
  "Validate native-decoded FLAT fragment effects and return compact records."
  (unless (and (vectorp flat) (integerp record-count)
               (>= record-count 0))
    (error "Native reflow decoded fragment tape is invalid"))
  (let ((cursor 0)
        (length (length flat))
        (template (make-vector record-count nil))
        (none-value (- (ash 1 63))))
    (dotimes (index record-count)
      (when (> (+ cursor 8) length)
        (error "Native reflow decoded fragment record is truncated"))
      (let* ((start (aref flat cursor))
             (finish (aref flat (+ cursor 1)))
             (line (aref flat (+ cursor 2)))
             (owner-value (aref flat (+ cursor 3)))
             (content-index-value (aref flat (+ cursor 4)))
             (role-count (aref flat (+ cursor 5)))
             (template-count (aref flat (+ cursor 6)))
             (fragment-style-count (aref flat (+ cursor 7)))
             roles template-ids style-ids)
        (setq cursor (+ cursor 8))
        (unless (and (integerp role-count) (>= role-count 0)
                     (integerp template-count) (>= template-count 0)
                     (integerp fragment-style-count)
                     (>= fragment-style-count 0)
                     (<= (+ cursor (* role-count 2)
                            template-count fragment-style-count)
                         length))
          (error "Native reflow decoded fragment dimensions are invalid"))
        (dotimes (_ role-count)
          (let ((role
                 (ebox-native-reflow--fragment-role-symbol
                  (aref flat cursor)))
                (region-id (aref flat (1+ cursor))))
            (unless (and role (integerp region-id) (> region-id 0)
                         (not (member (cons role region-id) roles)))
              (error "Native reflow decoded fragment role is invalid"))
            (push (cons role region-id) roles)
            (setq cursor (+ cursor 2))))
        (dotimes (_ template-count)
          (let ((template-id (aref flat cursor)))
            (unless (and (integerp template-id) (>= template-id 0)
                         (< template-id property-template-count))
              (error "Native reflow decoded property template is invalid"))
            (push template-id template-ids)
            (setq cursor (1+ cursor))))
        (dotimes (_ fragment-style-count)
          (let ((style-id (aref flat cursor)))
            (unless (and (integerp style-id) (>= style-id 0)
                         (< style-id style-count))
              (error "Native reflow decoded fragment style is invalid"))
            (push style-id style-ids)
            (setq cursor (1+ cursor))))
        (aset template index
              (vector start finish line (nreverse roles)
                      (unless (= owner-value none-value) owner-value)
                      (unless (= content-index-value none-value)
                        content-index-value)
                      (nreverse template-ids) (nreverse style-ids)))))
    (unless (= cursor length)
      (error "Native reflow decoded fragment tape has trailing values"))
    (ebox-native-reflow--validate-root-fragment-template
     template character-count property-template-count style-count)
    template))

(defun ebox-native-reflow--tape-read-fragment-template
    (cursor byte-count record-count character-count
            property-template-count style-count
            &optional flat flat-record-count)
  "Read and validate one compact binary fragment effect tape from CURSOR."
  (cond
   ((and (zerop byte-count) (zerop record-count)) [])
   ((or (zerop byte-count) (zerop record-count))
    (error "Native reflow fragment tape has inconsistent dimensions"))
   ((or (> record-count most-positive-fixnum)
        (> record-count character-count))
    (error "Native reflow fragment tape has too many records"))
   (t
    (let* ((end (+ (aref cursor 1) byte-count))
           (fragment-cursor (vector (aref cursor 0) (aref cursor 1) end))
           (template (make-vector record-count nil))
           (previous-end 0)
           (previous-line 0)
           (none-value (- (ash 1 63))))
      (when (> end (aref cursor 2))
        (error "Native reflow fragment tape exceeds its frame"))
      (if flat
          (progn
            (unless (= flat-record-count record-count)
              (error "Native reflow decoded fragment count mismatch"))
            (aset cursor 1 end)
            (ebox-native-reflow--fragment-template-from-flat
             flat record-count character-count property-template-count
             style-count))
        (progn
          (dotimes (index record-count)
        (ebox-native-reflow--tape-require fragment-cursor 56)
        (let* ((start (ebox-native-reflow--tape-read-u64 fragment-cursor))
               (finish (ebox-native-reflow--tape-read-u64 fragment-cursor))
               (line (ebox-native-reflow--tape-read-u64 fragment-cursor))
               (owner-value
                (ebox-native-reflow--tape-read-i64 fragment-cursor))
               (content-index-value
                (ebox-native-reflow--tape-read-i64 fragment-cursor))
               (role-count
                (ebox-native-reflow--tape-read-u32 fragment-cursor))
               (template-count
                (ebox-native-reflow--tape-read-u32 fragment-cursor))
               (fragment-style-count
                (ebox-native-reflow--tape-read-u32 fragment-cursor))
               (reserved
                (ebox-native-reflow--tape-read-u32 fragment-cursor))
               roles template-ids style-ids)
          (unless (and (= start previous-end) (< start finish)
                       (<= finish character-count)
                       (<= previous-line line) (zerop reserved))
            (error "Native reflow fragment tape has invalid coordinates"))
          (dotimes (_ role-count)
            (let ((role
                   (ebox-native-reflow--fragment-role-symbol
                    (ebox-native-reflow--tape-read-u8 fragment-cursor)))
                  (region-id
                   (ebox-native-reflow--tape-read-i64 fragment-cursor)))
              (unless (and role (> region-id 0)
                           (not (member (cons role region-id) roles)))
                (error "Native reflow fragment tape has an invalid role"))
              (push (cons role region-id) roles)))
          (dotimes (_ template-count)
            (let ((template-id
                   (ebox-native-reflow--tape-read-u32 fragment-cursor)))
              (unless (< template-id property-template-count)
                (error "Native reflow fragment tape has an invalid property template"))
              (push template-id template-ids)))
          (dotimes (_ fragment-style-count)
            (let ((style-id
                   (ebox-native-reflow--tape-read-u32 fragment-cursor)))
              (unless (< style-id style-count)
                (error "Native reflow fragment tape has an invalid style"))
              (push style-id style-ids)))
          (aset template index
                (vector start finish line (nreverse roles)
                        (unless (= owner-value none-value) owner-value)
                        (unless (= content-index-value none-value)
                          content-index-value)
                        (nreverse template-ids) (nreverse style-ids)))
            (setq previous-end finish
                  previous-line line)))
          (unless (and (= previous-end character-count)
                       (= (aref fragment-cursor 1) end))
            (error "Native reflow fragment tape is incomplete"))
          (aset cursor 1 end)
          (ebox-native-reflow--validate-root-fragment-template
           template character-count property-template-count style-count)
          template))))))

(defun ebox-native-reflow--preflight-layout-patch-tape
    (cursor header styles trusted-native-encoder-p property-templates
            &optional fragment-flat fragment-flat-count)
  "Decode one Rust-origin minimal patch body from CURSOR.
HEADER supplies the already validated target identity.  STYLES owns the face
         registry.  TRUSTED-NATIVE-ENCODER-P is retained for full-tape
 compatibility; exact native patch literals trust the ABI-matched encoder's
 property intervals after reader, type, trailing-data, and length checks."
  (ebox-native-reflow--tape-require
   cursor ebox-native-reflow--tape-patch-body-preamble-length)
  (let* ((base-character-count (ebox-native-reflow--tape-read-u64 cursor))
         (patch-count (ebox-native-reflow--tape-read-u32 cursor))
         (reserved (ebox-native-reflow--tape-read-u32 cursor))
         (metadata-record-count (ebox-native-reflow--tape-read-u64 cursor))
         (payload-byte-length (ebox-native-reflow--tape-read-u64 cursor))
         (fragment-byte-length (ebox-native-reflow--tape-read-u64 cursor))
         (fragment-record-count (ebox-native-reflow--tape-read-u64 cursor))
         (coordinate-patch-count
          (ebox-native-reflow--tape-read-u32 cursor))
         (coordinate-reserved
          (ebox-native-reflow--tape-read-u32 cursor))
         (target-character-count (plist-get header :character-count))
         (descriptor-bytes
          (* (+ patch-count coordinate-patch-count)
             ebox-native-reflow--tape-patch-descriptor-length))
         (required-bytes
          (+ descriptor-bytes payload-byte-length fragment-byte-length)))
    (unless (and (integerp reserved) (<= 0 reserved 15))
      (error "Native reflow patch flags are invalid"))
    (unless (zerop coordinate-reserved)
      (error "Native reflow coordinate patch reserved field is nonzero"))
    (when (and (/= (logand reserved 1) 0)
               (not (and (zerop fragment-byte-length)
                         (zerop fragment-record-count))))
      (error "Native reflow reused fragment tape has a payload"))
    (when (and (/= (logand reserved 8) 0)
               (not (and (zerop fragment-byte-length)
                         (zerop fragment-record-count))))
      (error "Native fragment paint delta has a full fragment payload"))
    (unless (= required-bytes (- (aref cursor 2) (aref cursor 1)))
      (error "Native reflow patch body length mismatch"))
    (let ((descriptors nil)
          (coordinate-descriptors nil)
          (previous-old-end 0)
          (previous-new-end 0))
      (dotimes (_ patch-count)
        (let ((old-start (ebox-native-reflow--tape-read-u64 cursor))
              (old-end (ebox-native-reflow--tape-read-u64 cursor))
              (new-start (ebox-native-reflow--tape-read-u64 cursor))
              (new-end (ebox-native-reflow--tape-read-u64 cursor)))
          (unless (and (<= previous-old-end old-start old-end
                           base-character-count)
                       (<= previous-new-end new-start new-end
                           target-character-count)
                       (= (- old-start previous-old-end)
                          (- new-start previous-new-end))
                       (or (< old-start old-end) (< new-start new-end)))
            (error "Native reflow patch has invalid or unaligned ranges"))
          (push (list :old-start old-start :old-end old-end
                      :new-start new-start :new-end new-end)
                descriptors)
          (setq previous-old-end old-end
                previous-new-end new-end)))
      (unless (= (- base-character-count previous-old-end)
                 (- target-character-count previous-new-end))
        (error "Native reflow patch target length is inconsistent"))
      (setq descriptors (nreverse descriptors))
      (setq previous-old-end 0 previous-new-end 0)
      (dotimes (_ coordinate-patch-count)
        (let ((old-start (ebox-native-reflow--tape-read-u64 cursor))
              (old-end (ebox-native-reflow--tape-read-u64 cursor))
              (new-start (ebox-native-reflow--tape-read-u64 cursor))
              (new-end (ebox-native-reflow--tape-read-u64 cursor)))
          (unless (and (<= previous-old-end old-start old-end
                           base-character-count)
                       (<= previous-new-end new-start new-end
                           target-character-count)
                       (= (- old-start previous-old-end)
                          (- new-start previous-new-end))
                       (or (< old-start old-end) (< new-start new-end)))
            (error "Native reflow coordinate patch is invalid"))
          (push (list :old-start old-start :old-end old-end
                      :new-start new-start :new-end new-end)
                coordinate-descriptors)
          (setq previous-old-end old-end
                previous-new-end new-end)))
      (unless (= (- base-character-count previous-old-end)
                 (- target-character-count previous-new-end))
        (error "Native reflow coordinate patch length is inconsistent"))
      (setq coordinate-descriptors (nreverse coordinate-descriptors))
      (let* ((payload-end (+ (aref cursor 1) payload-byte-length))
             (payload-cursor
              (vector (aref cursor 0) (aref cursor 1) payload-end))
             (payload
              (ebox-native-reflow--tape-read-patch-payload
               payload-cursor descriptors styles
               (plist-get header :complete) target-character-count
               metadata-record-count trusted-native-encoder-p
               property-templates)))
        (unless (= (aref payload-cursor 1) payload-end)
          (error "Native reflow patch body has trailing bytes"))
        (aset cursor 1 payload-end)
        (let* ((paint-delta (plist-get payload :fragment-paint-delta))
               (_paint-delta-contract
                (unless (eq (/= (logand reserved 8) 0)
                            (and paint-delta t))
                  (error "Native fragment paint delta flag mismatch")))
               (fragments
                (unless paint-delta
                  (ebox-native-reflow--tape-read-fragment-template
                   cursor fragment-byte-length fragment-record-count
                   target-character-count (length property-templates)
                   (length styles) fragment-flat fragment-flat-count))))
          (when paint-delta
            (aset cursor 1 (+ (aref cursor 1) fragment-byte-length)))
        (unless (= (aref cursor 1) (aref cursor 2))
          (error "Native reflow patch tape has trailing bytes"))
        (list :native-patch t
              :reuse-fragment-template (/= (logand reserved 1) 0)
              :reuse-ownership-template (/= (logand reserved 2) 0)
              :reuse-mount-projection (/= (logand reserved 4) 0)
              :fragment-paint-delta paint-delta
              :patch-origin 'rust
              :base-character-count base-character-count
              :target-character-count target-character-count
              :target-line-count (plist-get header :line-count)
              :patches descriptors
              :coordinate-patches coordinate-descriptors
              :root-render-metadata
              (append (plist-get payload :metadata)
                      (list :fragment-span-template fragments))
              :metadata-record-count metadata-record-count
              :replacement-bytes
              (cl-loop for replacement in (plist-get payload :replacements)
                       sum (string-bytes replacement))
              :full-frame-bytes 0))))))

(defun ebox-native-reflow--preflight-layout-tape
    (payload styles expected &optional trusted-native-encoder-p
             property-templates fragment-flat fragment-flat-count)
  "Validate and decode one versioned Rust materialization tape PAYLOAD."
  (unless (vectorp styles)
    (error "Native reflow styles must be a vector"))
  (let* ((cursor (ebox-native-reflow--tape-cursor payload))
         (header (ebox-native-reflow--tape-read-header
                  cursor styles expected))
         (ok-p (plist-get header :ok)))
    (unless ok-p
      (let* ((message-length (ebox-native-reflow--tape-read-u32 cursor))
             (message-bytes
              (ebox-native-reflow--tape-read-bytes cursor message-length)))
        (unless (= (aref cursor 1) (aref cursor 2))
          (error "Native reflow error tape has trailing bytes"))
        (error "Native reflow layout failed: %s"
               (ebox-native-reflow--tape-decode-utf8
                message-bytes "error message"))))
    (if (plist-get header :patch)
        (ebox-native-reflow--preflight-layout-patch-tape
         cursor header styles trusted-native-encoder-p property-templates
         fragment-flat fragment-flat-count)
      (ebox-native-reflow--tape-require
       cursor ebox-native-reflow--tape-body-preamble-length)
      (let* ((literal-byte-length (ebox-native-reflow--tape-read-u64 cursor))
           (line-width-count (ebox-native-reflow--tape-read-u32 cursor))
           (metadata-byte-length (ebox-native-reflow--tape-read-u32 cursor))
           (metadata-record-count (ebox-native-reflow--tape-read-u64 cursor))
           (fragment-byte-length (ebox-native-reflow--tape-read-u64 cursor))
           (fragment-record-count (ebox-native-reflow--tape-read-u64 cursor))
           (line-count (plist-get header :line-count))
           (declared-characters (plist-get header :character-count))
           (required-bytes (+ (* line-width-count 8)
                              literal-byte-length
                              metadata-byte-length
                              fragment-byte-length)))
      (unless (= line-width-count line-count)
        (error "Native reflow tape body metadata mismatch"))
      (unless (= required-bytes (- (aref cursor 2) (aref cursor 1)))
        (error "Native reflow tape body length mismatch"))
      (let ((line-widths (make-vector line-count 0)))
        (dotimes (index line-count)
          (let ((width (ebox-native-reflow--tape-read-u64 cursor)))
            (unless (<= width most-positive-fixnum)
              (error "Native reflow tape line width is too large"))
            (aset line-widths index width)))
        (let* ((literal-bytes
                (ebox-native-reflow--tape-read-bytes
                 cursor literal-byte-length))
               (literal
                (ebox-native-reflow--tape-decode-utf8
                 literal-bytes "materialized literal"))
               (read-circle t)
               (read-symbol-shorthands nil)
               (parsed
                (condition-case err
                    (read-from-string literal)
                  (error
                   (error "Native reflow tape literal is invalid: %s"
                          (error-message-string err)))))
               (rendered (car parsed)))
          (unless (and (stringp rendered) (= (cdr parsed) (length literal)))
            (error "Native reflow tape literal has trailing or non-string data"))
          (unless (= (length rendered) declared-characters)
            (error "Native reflow tape character count mismatch"))
          (unless (= (ebox-string-height rendered) line-count)
            (error "Native reflow tape has invalid line break metadata"))
          (ebox-native-reflow--expand-property-templates
           rendered property-templates)
          (let ((metadata
                 (ebox-native-reflow--tape-read-root-metadata
                  cursor metadata-byte-length metadata-record-count
                  declared-characters (plist-get header :complete)
                  (length property-templates)
                  (length styles)
                  trusted-native-encoder-p)))
            (let ((fragments
                   (ebox-native-reflow--tape-read-fragment-template
                    cursor fragment-byte-length fragment-record-count
                    declared-characters (length property-templates)
                    (length styles) fragment-flat fragment-flat-count)))
            (unless (= (aref cursor 1) (aref cursor 2))
              (error "Native reflow tape has trailing bytes"))
            (vector header rendered line-widths metadata fragments)))))))))

(defun ebox-native-reflow--materialize-layout-tape
    (payload &optional styles expected trusted-native-encoder-p
             property-templates return-frame-p fragment-flat
             fragment-flat-count)
  "Validate and materialize binary layout tape PAYLOAD.
STYLES supplies Emacs-owned face templates.  EXPECTED optionally constrains
the identity header before any result string is allocated.  When
TRUSTED-NATIVE-ENCODER-P is non-nil, trust the ABI-matched Rust encoder's
typed line-width and property invariants instead of repeating them in Emacs."
  (let* ((styles (or styles []))
         (decoded (ebox-native-reflow--preflight-layout-tape
                   payload styles expected trusted-native-encoder-p
                   property-templates fragment-flat fragment-flat-count)))
    (if (plist-get decoded :native-patch)
        (let* ((patch-count (length (plist-get decoded :patches)))
               (metadata-count
                (or (plist-get decoded :metadata-record-count) 0))
               (retained-estimate
                (+ (or (plist-get decoded :replacement-bytes) 0)
                   (* patch-count 128)
                   (* metadata-count 64))))
          (ebox-native-reflow--decode-scroll-producers
           (plist-get decoded :root-render-metadata) styles property-templates t)
          (plist-put decoded :tape-bytes (string-bytes payload))
          (plist-put decoded :artifact-byte-estimate
                     (max (string-bytes payload) retained-estimate))
          decoded)
      (let ((header (aref decoded 0))
            (rendered (aref decoded 1))
            (line-widths (aref decoded 2))
            (metadata (aref decoded 3))
            (fragments (aref decoded 4)))
        (ebox-native-reflow--decode-scroll-producers
         metadata styles property-templates)
        (unless trusted-native-encoder-p
          (ebox-native-reflow--validate-literal-properties
           rendered styles (plist-get header :complete)
           property-templates)
          (let ((lines (ebox-string-lines rendered)))
            (unless (= (length lines) (plist-get header :line-count))
              (error "Native reflow materialized line count mismatch"))
            (cl-loop for line in lines
                     for index from 0
                     unless (= (ebox-string-pixel-width line)
                               (aref line-widths index))
                     do (error "Native reflow tape line width mismatch"))))
        (if return-frame-p
            (list :native-frame t :rendered rendered
                  :root-render-metadata metadata
                  :effect-tape
                  (append metadata (list :fragment-span-template fragments))
                  :line-widths line-widths
                  :styles styles
                  :property-templates property-templates)
          rendered)))))

(defun ebox-native-reflow-take-layout
    (session generation key &optional expected)
  "Take and materialize SESSION's semantic layout result.
EXPECTED may add exact tape identity fields beyond GENERATION and KEY."
  (when-let* ((payload
              (ebox-native--module-take
               (ebox-native-reflow--live-handle session) generation key)))
    (let ((identity (copy-sequence expected)))
      (setq identity (plist-put identity :generation generation)
            identity (plist-put identity :key key))
      ;; The ABI-matched Rust encoder constructs this literal only from typed,
      ;; bounded layout data.  Re-scanning every property interval here costs
      ;; more than one 50 ms frame on the maintained flex fixture; corruption
      ;; tests exercise the same materializer without this trust flag.
      (ebox-native-reflow--materialize-layout-tape
       payload (ebox-native-reflow-session-styles session) identity t
       (plist-get (ebox-native-reflow-session-layout-package session)
                  :property-templates)))))

(defun ebox-native-reflow-execute-sync
    (node frame &optional layout-package)
  "Execute NODE once through the native synchronous frame path.
FRAME supplies positive viewport geometry and optional `:root-width'.  The
result contains the fully materialized propertized string plus the validated
root effect metadata required by a thin host commit."
  (when (and (ebox-native-reflow-layout-ready-p)
             (fboundp 'ebox-native--module-render-frame))
    (let* ((package (or layout-package
                        (ebox-native-reflow--compile-layout-package node)))
           (native-key (or (plist-get frame :key) 1))
           (control-frame (copy-sequence frame)))
      (setq control-frame (plist-put control-frame :key native-key))
      (ebox-native-reflow--materialize-module-frame
       (ebox-native--module-render-frame
        (ebox-native-reflow--layout-control-json
         (plist-get package :document)
         (list control-frame)))
       package control-frame 0))))

(defun ebox-native-reflow--materialize-module-frame
    (native-frame package control-frame generation)
  "Materialize NATIVE-FRAME for PACKAGE and CONTROL-FRAME identity."
  (let* ((payload (aref native-frame 0))
         (fragment-flat (aref native-frame 1))
         (fragment-flat-count (aref native-frame 2))
         (expected
          (list :generation generation
                :key (or (plist-get control-frame :key) 1)
                :runtime-revision
                (or (plist-get control-frame :runtime-revision) 0)
                :context-hash
                (or (plist-get control-frame :context-hash) 0)
                :viewport-width (plist-get control-frame :viewport-width)
                :viewport-height (plist-get control-frame :viewport-height)
                :root-width
                (or (plist-get control-frame :root-width)
                    (plist-get control-frame :viewport-width))
                :complete
                (if (plist-member control-frame :complete)
                    (plist-get control-frame :complete)
                  t)))
         (result
          (ebox-native-reflow--materialize-layout-tape
           payload (plist-get package :styles) expected t
           (plist-get package :property-templates) t
           fragment-flat fragment-flat-count)))
    (when (plist-get result :native-patch)
      (plist-put result :styles (plist-get package :styles))
      (plist-put result :property-templates
                 (plist-get package :property-templates)))
    result))

(defun ebox-native-reflow-execute-session-sync
    (session node frame &optional layout-package state)
  "Execute NODE synchronously through retained native SESSION."
  (unless (and (ebox-native-reflow-session-p session)
               (fboundp 'ebox-native--module-render-session-frame))
    (error "Native retained frame execution is unavailable"))
  (let* ((old-package
          (ebox-native-reflow-session-layout-package session))
         (candidate-package
          (or layout-package
              (if state
                  (ebox-native-reflow--compile-retained-layout-package
                   session state node)
                (ebox-native-reflow--compile-layout-package
                 node
                 (ebox-native-reflow-session-styles session)
                 (plist-get
                  (ebox-native-reflow-session-layout-package session)
                  :property-templates)))))
         (document-delta (plist-get candidate-package :document-delta))
         (package
          (if document-delta
              candidate-package
            (ebox-native-reflow--reuse-exact-layout-package
             old-package candidate-package)))
         (generation (1+ (ebox-native-reflow-session-generation session)))
         (control-frame (copy-sequence frame))
         (native-key (or (plist-get control-frame :key) 1))
         (reuse-document-p (or document-delta (eq package old-package)))
         (base-revision (or (plist-get old-package :document-revision) 0))
         (target-revision (or (plist-get package :document-revision)
                              (1+ base-revision))))
    (setq control-frame (plist-put control-frame :key native-key))
    (let ((result
           (ebox-native-reflow--materialize-module-frame
            (ebox-native--module-render-session-frame
             (ebox-native-reflow--live-handle session)
             generation
             (ebox-native-reflow--layout-control-json
              (unless reuse-document-p (plist-get package :document))
              (list control-frame) base-revision target-revision
              document-delta))
            package control-frame generation)))
      (setf (ebox-native-reflow-session-generation session) generation
            (ebox-native-reflow-session-layout-package session)
            (ebox-native-reflow--confirmed-layout-package package)
            (ebox-native-reflow-session-styles session)
            (plist-get package :styles))
      (when document-delta
        (setf (ebox-native-reflow-session-layout-fragment-cache session) nil
              (ebox-native-reflow-session-layout-fragment-index session)
              (plist-get package :native-fragment-index)
              (ebox-native-reflow-session-layout-fragment-revision session)
              (plist-get package :native-fragment-revision)
              (ebox-native-reflow-session-layout-style-index session)
              (plist-get package :native-style-index)))
      result)))

(defun ebox-native-reflow-render-proof-sync
    (node frame &optional layout-package)
  "Render NODE once through the native synchronous proof path.
This compatibility entry returns only the rendered string.  New runtime
callers should consume `ebox-native-reflow-execute-sync' and commit its effect
metadata together with the text."
  (when-let* ((result
              (ebox-native-reflow-execute-sync node frame layout-package)))
    (plist-get result :rendered)))

(defun ebox-native-reflow--face-entries (face)
  "Return FACE as an ordered list of face entries."
  (cond ((null face) nil)
        ((and (listp face) (keywordp (car-safe face))) (list face))
        ((listp face) (copy-sequence face))
        (t (list face))))

(defun ebox-native-reflow--face-value (entries)
  "Return canonical face value represented by ENTRIES."
  (pcase entries
    ('() nil)
    (`(,entry) entry)
    (_ entries)))

(defun ebox-native-reflow--fragment-style-faces (style-ids styles)
  "Return effective native face contributions for STYLE-IDS."
  (let (faces)
    (dolist (style-id style-ids faces)
      (let ((style (aref styles style-id)))
        (pcase (plist-get style :mode)
          ('set (setq faces (list (plist-get style :face))))
          ('add
           (let ((face (plist-get style :face)))
             (unless (and (= (length faces) 1)
                          (equal (car faces) face))
               (setq faces (append faces (list face))))))
          (_ (error "Native reflow frame has an invalid style mode")))))))

(defun ebox-native-reflow--fragment-face-baseline
    (rendered start style-ids styles)
  "Remove native STYLE-IDS from RENDERED's face at START."
  (let* ((face (get-text-property start 'face rendered))
         (entries (ebox-native-reflow--face-entries face))
         (contributions
          (ebox-native-reflow--fragment-style-faces style-ids styles))
         (count (length contributions)))
    (when (and (> count 0)
               (or (< (length entries) count)
                   (not (equal (last entries count) contributions))))
      (error "Native reflow fragment face does not match its style tape"))
    (ebox-native-reflow--face-value
     (if (> count 0)
         (seq-take entries (- (length entries) count))
       entries))))

(defun ebox-native-reflow-frame-fragments (frame)
  "Decode FRAME's fragment effect template without scanning rendered text."
  (unless (plist-get frame :native-frame)
    (error "Native reflow fragment decode requires a native frame"))
  (let* ((rendered (plist-get frame :rendered))
         (metadata (plist-get frame :effect-tape))
         (template (and metadata
                        (plist-get metadata :fragment-span-template)))
         (styles (or (plist-get frame :styles) []))
         (baseline-cache (make-hash-table :test #'equal))
         (ordinal-table (make-hash-table :test #'equal))
         fragments previous-role-ids next-role-ids)
    (unless (and (stringp rendered) (vectorp template))
      (error "Native reflow frame has no fragment effect template"))
    (dotimes (index (length template))
      (let* ((record (aref template index))
             (start (aref record 0))
             (end (aref record 1))
             (line (aref record 2))
             (roles (copy-tree (aref record 3)))
             (content-owner (aref record 4))
             (content-index (aref record 5))
             (style-ids (aref record 7))
             (baseline-key
              (list (get-text-property start 'face rendered) style-ids))
             (missing (make-symbol "native-fragment-baseline-missing"))
             (baseline
              (gethash baseline-key baseline-cache missing))
             (prefix
              (and (or roles content-owner (integerp content-index))
                   (list :roles (copy-tree roles)
                         :content-owner content-owner
                         :content-index content-index)))
             (ordinal (and prefix (gethash prefix ordinal-table 0)))
             (address
              (and prefix
                   (list :roles (copy-tree roles)
                         :content-owner content-owner
                         :content-index content-index
                         :ordinal ordinal))))
        (when (eq baseline missing)
          (setq baseline
                (ebox-native-reflow--fragment-face-baseline
                 rendered start style-ids styles))
          (puthash baseline-key baseline baseline-cache))
        (when prefix
          (puthash prefix (1+ ordinal) ordinal-table))
        (push (list :text rendered :text-source-p t
                    :start start :end end :line line
                    :paint-role-ids roles :role-ids roles
                    :paint-address address
                    :paint-token
                    (and address
                         (list :baseline (copy-tree baseline)
                               :roles (copy-tree roles)
                               :content-owner content-owner
                               :content-index content-index))
                    :face-baseline (copy-tree baseline)
                    :face-baseline-known-p t)
              fragments)))
    (setq fragments (nreverse fragments))
    (dolist (fragment fragments)
      (if-let* ((roles (plist-get fragment :role-ids)))
          (setq previous-role-ids roles)
        (plist-put fragment :previous-role-ids previous-role-ids)))
    (dolist (fragment (reverse (copy-sequence fragments)))
      (if-let* ((roles (plist-get fragment :role-ids)))
          (setq next-role-ids roles)
        (plist-put fragment :role-ids
                   (delete-dups
                    (append (copy-sequence
                             (plist-get fragment :previous-role-ids))
                            (copy-sequence next-role-ids))))))
    (cl-loop for fragment in fragments for index from 0
             do (plist-put fragment :key (cons 'ebox/fragment index))
             do (cl-remf fragment :previous-role-ids)
             collect fragment)))

(defun ebox-native-reflow-submit (session generation frames)
  "Submit FRAMES for SESSION GENERATION without waiting for results."
  (unless (and (integerp generation) (>= generation 0))
    (error "Native reflow generation must be a nonnegative integer"))
  (let ((accepted
         (ebox-native--module-submit
          (ebox-native-reflow--live-handle session)
          generation
          (ebox-native-reflow--control-json frames))))
    (setf (ebox-native-reflow-session-generation session) generation)
    accepted))

(defun ebox-native-reflow-ready-p (session generation key)
  "Return non-nil when SESSION has GENERATION KEY ready."
  (ebox-native--module-ready-p
   (ebox-native-reflow--live-handle session) generation key))

(defun ebox-native-reflow-ready-count (session generation keys)
  "Return consecutive ready count at the front of KEYS."
  (let ((count 0))
    (while (and keys
                (ebox-native-reflow-ready-p
                 session generation (car keys)))
      (cl-incf count)
      (setq keys (cdr keys)))
    count))

(defun ebox-native-reflow-take (session generation key)
  "Take SESSION's GENERATION KEY result as a UTF-8 string, or nil."
  (when-let* ((bytes
              (ebox-native--module-take
               (ebox-native-reflow--live-handle session) generation key)))
    (decode-coding-string bytes 'utf-8 t)))

(defun ebox-native-reflow-confirm-native-frame
    (session generation key confirmed-revision)
  "Promote SESSION's GENERATION KEY after a successful publication.
CONFIRMED-REVISION must be the buffer runtime revision observed after the
published frame has been installed."
  (unless (and (integerp generation) (>= generation 0)
               (integerp key)
               (integerp confirmed-revision) (>= confirmed-revision 0))
    (error "Native reflow confirmation requires numeric identity fields"))
  (unless (ebox-native--module-confirm-frame
           (ebox-native-reflow--live-handle session)
           generation key confirmed-revision)
    (error "Native reflow confirmation has no matching pending frame"))
  t)

(defun ebox-native-reflow-cancel (session generation)
  "Cancel SESSION GENERATION and invalidate its queued/results."
  (prog1
      (ebox-native--module-cancel
       (ebox-native-reflow--live-handle session) generation)
    (setf (ebox-native-reflow-session-generation session)
          (1+ generation))))

(defun ebox-native-reflow-stats (session)
  "Return SESSION's bounded runtime statistics as a plist."
  (json-parse-string
   (ebox-native--module-stats (ebox-native-reflow--live-handle session))
   :object-type 'plist :array-type 'list
   :null-object nil :false-object nil))

(defun ebox-native-reflow--detach-session-readiness (session)
  "Detach and close SESSION's native readiness channel."
  (let ((process (ebox-native-reflow-session-readiness-process session)))
    (setf (ebox-native-reflow-session-readiness-process session) nil
          (ebox-native-reflow-session-readiness-preparation session) nil)
    (when process
      (process-put process 'ebox-native-reflow-session nil)
      (unwind-protect
          (when (and (ebox-native-reflow-session-handle session)
                     (not (ebox-native-reflow-session-released-p session))
                     (fboundp
                      'ebox-native--module-detach-readiness-channel))
            (unless (ebox-native--module-detach-readiness-channel
                     (ebox-native-reflow--live-handle session))
              (error "Native reflow readiness channel did not detach")))
        (when (process-live-p process)
          (delete-process process))))))

(defun ebox-native-reflow-release-session (session)
  "Release SESSION idempotently and stop its native workers."
  (when (and (ebox-native-reflow-session-p session)
             (not (ebox-native-reflow-session-released-p session)))
    (let ((handle (ebox-native-reflow-session-handle session)))
      (unwind-protect
          (ebox-native-reflow--detach-session-readiness session)
        (when handle
          (ebox-native--module-release handle))
        (setf (ebox-native-reflow-session-handle session) nil
              (ebox-native-reflow-session-released-p session) t))))
  nil)

(defun ebox-native-reflow-preparation-supported-p (buffer)
  "Return non-nil when BUFFER can use native root-frame preparation."
  (and (buffer-live-p buffer)
       (let ((state (ebox--buffer-render-state buffer)))
         (and state
              (ebox-native-reflow--native-node-supported-p
               (plist-get state :root-node))))
       (ebox-native-reflow-layout-ready-p)))

(defun ebox-native-reflow--preparation-frame
    (spec state native-key source-revision context-hash complete-p)
  "Return one native control frame for logical SPEC and NATIVE-KEY."
  (let ((frame
         (list :key native-key
               :viewport-width
               (or (plist-get spec :viewport-width)
                   (plist-get state :viewport-width))
               :viewport-height
               (or (plist-get spec :viewport-height)
                   (plist-get state :viewport-height))
               :runtime-revision source-revision
               :context-hash context-hash
               :complete complete-p)))
    (when (plist-member spec :root-width)
      (setq frame (plist-put frame :root-width
                             (plist-get spec :root-width))))
    (when (or (plist-member spec :base-viewport-width)
              (plist-member spec :base-root-width))
      (setq frame
            (plist-put frame :base-viewport-width
                       (or (plist-get spec :base-viewport-width)
                           (plist-get state :viewport-width))))
      (setq frame
            (plist-put frame :base-viewport-height
                       (or (plist-get spec :base-viewport-height)
                           (plist-get state :viewport-height))))
      (when (plist-member spec :base-root-width)
        (setq frame
              (plist-put frame :base-root-width
                         (plist-get spec :base-root-width)))))
    frame))

(defun ebox-native-reflow--preparation-key
    (preparation logical-key full-p)
  "Return PREPARATION's native key for LOGICAL-KEY and FULL-P."
  (when-let* ((keys
              (gethash logical-key
                       (ebox-native-reflow-preparation-key-table
                        preparation))))
    (if full-p (cdr keys) (car keys))))

(defun ebox-native-reflow--preparation-cache-key (logical-key full-p)
  "Return the materialized-frame cache key for LOGICAL-KEY and FULL-P."
  (list logical-key (and full-p t)))

(defun ebox-native-reflow-preparation-fully-materialized-p (preparation)
  "Return non-nil when PREPARATION has no native tape left to materialize."
  (and preparation
       (null
        (ebox-native-reflow-preparation-materialization-queue preparation))))

(defun ebox-native-reflow--stop-preparation-ready-watch (preparation)
  "Stop PREPARATION's main-thread readiness timer."
  (when-let* ((timer
              (ebox-native-reflow-preparation-ready-timer preparation)))
    (when (timerp timer)
      (cancel-timer timer))
    (setf (ebox-native-reflow-preparation-ready-timer preparation) nil)))

(defun ebox-native-reflow--readiness-channel-live-p (preparation)
  "Return non-nil when PREPARATION is routed to its session channel."
  (when-let* ((session
               (ebox-native-reflow-preparation-native-session preparation))
              (process
               (ebox-native-reflow-session-readiness-process session)))
    (and (eq preparation
             (ebox-native-reflow-session-readiness-preparation session))
         (process-live-p process))))

(defun ebox-native-reflow--readiness-filter (process _bytes)
  "Handle one native readiness notification delivered through PROCESS."
  (when-let* ((session
               (process-get process 'ebox-native-reflow-session))
              ((eq process
                   (ebox-native-reflow-session-readiness-process session)))
              (preparation
               (ebox-native-reflow-session-readiness-preparation session)))
    (when (and (eq process
                   (ebox-native-reflow-session-readiness-process session))
               (eq session
                   (ebox-native-reflow-preparation-native-session preparation))
               (not (ebox-native-reflow-preparation-stopped-p preparation)))
      (ebox-native-reflow--stop-preparation-ready-watch preparation)
      (ebox-native-reflow--watch-preparation-ready preparation))))

(defun ebox-native-reflow--readiness-sentinel (process _event)
  "Surface an unexpected native readiness channel close for PROCESS."
  (when-let* ((session
              (process-get process 'ebox-native-reflow-session)))
    (when (and (eq process
                   (ebox-native-reflow-session-readiness-process session))
               (not (process-live-p process)))
      (let ((preparation
             (ebox-native-reflow-session-readiness-preparation session)))
        (unwind-protect
            (ebox-native-reflow--detach-session-readiness session)
          (when (and preparation
                     (not (ebox-native-reflow-preparation-stopped-p
                           preparation)))
            (ebox-native-reflow--fail-preparation
             preparation "Native reflow readiness channel closed")))))))

(defun ebox-native-reflow--ensure-session-readiness (session)
  "Return SESSION's live readiness process, attaching it once if needed."
  (when (and (not (eq system-type 'windows-nt))
             (fboundp 'ebox-native--module-attach-readiness-channel))
    (let ((existing
           (ebox-native-reflow-session-readiness-process session)))
      (cond
       ((and existing (process-live-p existing)) existing)
       (existing
        (error "Native reflow readiness channel is closed"))
       ((ebox-native-reflow-session-readiness-preparation session)
        (error "Native reflow readiness route has no channel"))
       (t
        (let ((process
               (make-pipe-process
                :name "ebox-native-reflow-readiness"
                :buffer nil
                :coding 'no-conversion
                :noquery t
                :filter #'ebox-native-reflow--readiness-filter
                :sentinel #'ebox-native-reflow--readiness-sentinel))
              attached-p)
          (unwind-protect
              (progn
                (process-put process 'ebox-native-reflow-session session)
                (unless (ebox-native--module-attach-readiness-channel
                         (ebox-native-reflow--live-handle session) process)
                  (error "Native reflow readiness channel was rejected"))
                (setf (ebox-native-reflow-session-readiness-process session)
                      process)
                (setq attached-p t)
                process)
            (unless attached-p
              (process-put process 'ebox-native-reflow-session nil)
              (when (process-live-p process)
                (delete-process process))))))))))

(defun ebox-native-reflow--route-preparation-readiness (preparation)
  "Route PREPARATION through its session-owned readiness channel."
  (when-let* ((session
               (ebox-native-reflow-preparation-native-session preparation))
              ((ebox-native-reflow--ensure-session-readiness session)))
    (when-let* ((current
                (ebox-native-reflow-session-readiness-preparation session)))
      (unless (eq current preparation)
        (error "Native reflow session already routes another preparation")))
    (setf (ebox-native-reflow-session-readiness-preparation session)
          preparation)
    t))

(defun ebox-native-reflow--clear-preparation-readiness (preparation)
  "Clear PREPARATION's route without closing its session channel."
  (when-let* ((session
              (ebox-native-reflow-preparation-native-session preparation)))
    (when (eq preparation
              (ebox-native-reflow-session-readiness-preparation session))
      (setf (ebox-native-reflow-session-readiness-preparation session) nil))))

(defun ebox-native-reflow--idle-continuation-delay (delay)
  "Return a fresh idle threshold DELAY beyond the current idle duration."
  (+ (or (when-let* ((idle (current-idle-time)))
           (float-time idle))
         0)
     (max 0 (or delay 0))))

(defun ebox-native-reflow--schedule-preparation-ready-watch
    (preparation delay)
  "Schedule PREPARATION's next one-shot materialization turn after DELAY."
  (unless (or (ebox-native-reflow-preparation-stopped-p preparation)
              (ebox-native-reflow-preparation-error preparation))
    (setf (ebox-native-reflow-preparation-ready-timer preparation)
          (if (ebox-native-reflow-preparation-idle-watch-p preparation)
              (run-with-idle-timer
               (ebox-native-reflow--idle-continuation-delay delay)
               nil #'ebox-native-reflow--watch-preparation-ready preparation)
            (run-at-time delay nil
                         #'ebox-native-reflow--watch-preparation-ready
                         preparation)))))

(defun ebox-native-reflow--next-materialization-ready-p (preparation)
  "Return non-nil when PREPARATION's next queued native frame is ready."
  (when-let* ((entry
               (car (ebox-native-reflow-preparation-materialization-queue
                     preparation)))
              (spec (car entry)))
    (ebox-native-reflow-preparation-ready-p
     preparation (plist-get spec :key) (cadr entry))))

(defun ebox-native-reflow-prioritize-preparation (preparation)
  "Promote background PREPARATION to input-driven readiness notification."
  (when preparation
    (setf (ebox-native-reflow-preparation-idle-watch-p preparation) nil)
    (when (ebox-native-reflow-preparation-materialization-queue preparation)
      (ebox-native-reflow--stop-preparation-ready-watch preparation)
      (let ((channel-p
             (or (ebox-native-reflow--readiness-channel-live-p preparation)
                 (ebox-native-reflow--route-preparation-readiness
                  preparation))))
        (when (or (not channel-p)
                  (ebox-native-reflow--next-materialization-ready-p
                   preparation))
          (ebox-native-reflow--schedule-preparation-ready-watch
           preparation 0)))))
  preparation)

(defun ebox-native-reflow--fail-preparation (preparation message)
  "Record PREPARATION failure MESSAGE and notify its owner once."
  (unless (or (ebox-native-reflow-preparation-stopped-p preparation)
              (ebox-native-reflow-preparation-error preparation))
    (setf (ebox-native-reflow-preparation-error preparation) message)
    (when-let* ((function
                (ebox-native-reflow-preparation-error-function preparation)))
      (funcall function preparation message))))

(defun ebox-native-reflow--watch-preparation-ready (preparation)
  "Materialize one PREPARATION frame, then notify its owner."
  (setf (ebox-native-reflow-preparation-ready-timer preparation) nil)
  (cond
   ((or (ebox-native-reflow-preparation-stopped-p preparation)
        (ebox-native-reflow-preparation-error preparation))
    (ebox-native-reflow--stop-preparation-ready-watch preparation))
   (t
    (condition-case err
        ;; Rust jobs may complete in parallel, but Emacs values are created
        ;; only on the main thread.  Convert one result per event-loop turn
        ;; before animation so visible frames never alternate playback and
        ;; parsing.
        (let ((materialized-p
               (ebox-native-reflow--materialize-next-ready-frame
                preparation)))
          (when-let* ((function
                      (ebox-native-reflow-preparation-ready-function
                       preparation)))
            (funcall function preparation nil))
          (when (ebox-native-reflow-preparation-materialization-queue
                 preparation)
            (cond
             ((ebox-native-reflow-preparation-idle-watch-p preparation)
              (ebox-native-reflow--schedule-preparation-ready-watch
               preparation (if materialized-p 0.001 0.01)))
             ((ebox-native-reflow--readiness-channel-live-p preparation)
              (when (ebox-native-reflow--next-materialization-ready-p
                     preparation)
                (ebox-native-reflow--schedule-preparation-ready-watch
                 preparation 0)))
             (t
              (ebox-native-reflow--schedule-preparation-ready-watch
               preparation (if materialized-p 0.001 0.01))))))
      (error
       (ebox-native-reflow--fail-preparation
        preparation (error-message-string err)))))))

(defun ebox-native-reflow-start-preparation
    (buffer kind region-id specs worker-count _batch-cadence
            ready-function error-function &optional idle-watch-p layout-package
            native-session)
  "Start bounded native root preparation for BUFFER and logical SPECS.
KIND is `viewport' or `root-width'.  A spec with `:full-only-p' submits only
its complete result; otherwise each requested frame is submitted with its
light result followed by its optional complete restoration companion.
When IDLE-WATCH-P is non-nil, every main-thread materialization turn waits for
a fresh idle interval so background preparation cannot overtake input.
When NATIVE-SESSION is non-nil, borrow it across generations instead of
creating and releasing a session for this preparation."
  (unless (ebox-native-reflow-preparation-supported-p buffer)
    (error "Native root reflow preparation is unavailable"))
  (unless (memq kind '(viewport root-width))
    (error "Unsupported native root reflow kind %S" kind))
  (unless (and (listp specs) specs)
    (error "Native root reflow preparation requires frame specs"))
  (let* ((state (ebox--buffer-render-state buffer))
         (root (plist-get state :root-node))
         (layout-package
          (or layout-package
              (ebox-native-reflow--compile-layout-package root)))
         (source-revision (or (plist-get state :runtime-revision) 0))
         (display-signature (plist-get state :display-signature))
         (context-hash
          (sxhash-equal
           (list display-signature kind region-id
                 (ebox--ensure-node-id root))))
         (key-table (make-hash-table :test 'equal))
         (next-key 0)
         materialization-queue
         frames)
    (dolist (spec specs)
      (let* ((logical-key (plist-get spec :key))
             (_key-check
              (unless logical-key
                (error "Native root reflow spec has no logical key")))
             (full-only-p (plist-get spec :full-only-p))
             (_full-only-check
              (when (and full-only-p (not (plist-get spec :full-p)))
                (error "Native root reflow full-only spec needs :full-p")))
             (light-key (unless full-only-p (cl-incf next-key)))
             (full-key (and (plist-get spec :full-p)
                            (cl-incf next-key))))
        (when (gethash logical-key key-table)
          (error "Duplicate native root reflow logical key %S" logical-key))
        (puthash logical-key (cons light-key full-key) key-table)
        (when light-key
          (push (ebox-native-reflow--preparation-frame
                 spec state light-key source-revision context-hash nil)
                frames)
          (push (list (copy-sequence spec) nil) materialization-queue))
        (when full-key
          (push (ebox-native-reflow--preparation-frame
                 spec state full-key source-revision context-hash t)
                frames)
          (push (list (copy-sequence spec) t) materialization-queue))))
    (let* ((frames (nreverse frames))
           (frame-count (length frames))
           (_capacity-check
            (when (> frame-count
                     (min ebox-native-reflow-max-jobs
                          ebox-native-reflow-max-results))
              (error
               "Native root reflow needs %d frame slots; configured limit is %d"
               frame-count
               (min ebox-native-reflow-max-jobs
                    ebox-native-reflow-max-results))))
           (borrowed-session-p (and native-session t))
           (native-session
            (or native-session
                (ebox-native-reflow-create-session
                 :workers worker-count)))
           (generation
            (1+ (or (ebox-native-reflow-session-generation native-session)
                    0)))
           (preparation
            (ebox-native-reflow--make-preparation
             :native-session native-session
             :native-session-id
             (plist-get (ebox-native-reflow-stats native-session) :session-id)
             :generation generation
             :buffer buffer
             :kind kind
             :region-id region-id
             :source-root root
             :source-revision source-revision
             :expected-revision source-revision
             :display-signature display-signature
             :context-hash context-hash
             :layout-package layout-package
             :key-table key-table
             :frame-cache (make-hash-table :test 'equal)
             :materialization-queue (nreverse materialization-queue)
             :specs (copy-tree specs)
             :ready-function ready-function
             :error-function error-function
             :idle-watch-p idle-watch-p
             :window-start-line
             (when-let* ((window (get-buffer-window buffer t)))
               (with-current-buffer buffer
                 (save-restriction
                   (widen)
                   (max 1 (line-number-at-pos (window-start window))))))
             :release-native-session-p (not borrowed-session-p)))
           readiness-channel-p
           submitted-p)
      (unwind-protect
          (progn
            (unless idle-watch-p
              (setq readiness-channel-p
                    (ebox-native-reflow--route-preparation-readiness
                     preparation)))
            (unless (= (ebox-native-reflow-submit-layout
                        native-session generation root frames layout-package)
                       (length frames))
              (error "Native root reflow accepted an incomplete frame batch"))
            (when (or (not readiness-channel-p)
                      (ebox-native-reflow--next-materialization-ready-p
                       preparation))
              (ebox-native-reflow--schedule-preparation-ready-watch
               preparation 0))
            (setq submitted-p t)
            preparation)
        (unless submitted-p
          (ebox-native-reflow--clear-preparation-readiness preparation)
          (if borrowed-session-p
              (ignore-errors
                (ebox-native-reflow-cancel native-session generation))
            (ebox-native-reflow-release-session native-session)))))))

(defun ebox-native-reflow-preparation-ready-p
    (preparation logical-key &optional full-p)
  "Return non-nil when PREPARATION has LOGICAL-KEY ready.
When FULL-P is non-nil, query the complete restoration job."
  (when (and preparation
             (not (ebox-native-reflow-preparation-stopped-p preparation)))
    (let ((cache
           (ebox-native-reflow-preparation-frame-cache preparation)))
      (or (and cache
               (gethash
                (ebox-native-reflow--preparation-cache-key
                 logical-key full-p)
                cache))
          (when-let* ((native-key
                      (ebox-native-reflow--preparation-key
                       preparation logical-key full-p)))
            (ebox-native-reflow-ready-p
             (ebox-native-reflow-preparation-native-session preparation)
             (ebox-native-reflow-preparation-generation preparation)
             native-key))))))

(defun ebox-native-reflow-preparation-ready-count (preparation logical-keys)
  "Return PREPARATION's consecutive ready light-frame count."
  (let ((count 0))
    (while (and logical-keys
                (ebox-native-reflow-preparation-ready-p
                 preparation (car logical-keys)))
      (cl-incf count)
      (setq logical-keys (cdr logical-keys)))
    count))

(defun ebox-native-reflow--validated-preparation-state (preparation)
  "Return PREPARATION's current render state after fail-closed validation."
  (let* ((buffer (ebox-native-reflow-preparation-buffer preparation))
         (state (and (buffer-live-p buffer)
                     (ebox--buffer-render-state buffer)))
         (root (plist-get state :root-node)))
    (unless (and state
                 (eq root
                     (ebox-native-reflow-preparation-source-root preparation))
                 (equal
                  (plist-get state :runtime-revision)
                  (ebox-native-reflow-preparation-expected-revision preparation))
                 (equal
                  (ebox-native-reflow--buffer-display-signature buffer)
                  (ebox-native-reflow-preparation-display-signature
                   preparation)))
      (error "Preview runtime changed during native reflow preparation"))
    state))

(defun ebox-native-reflow--materialize-preparation-frame
    (preparation spec full-p state)
  "Take and materialize PREPARATION's SPEC result using validated STATE."
  (let* ((logical-key (plist-get spec :key))
         (native-key
          (ebox-native-reflow--preparation-key
           preparation logical-key full-p))
         (viewport-width
          (or (plist-get spec :viewport-width)
              (plist-get state :viewport-width)))
         (viewport-height
          (or (plist-get spec :viewport-height)
              (plist-get state :viewport-height)))
         (root-width (or (plist-get spec :root-width) viewport-width))
         (result
          (condition-case err
              (ebox-native-reflow-take-layout
               (ebox-native-reflow-preparation-native-session preparation)
               (ebox-native-reflow-preparation-generation preparation)
               native-key
               (list
                :session-id
                (ebox-native-reflow-preparation-native-session-id preparation)
                :runtime-revision
                (ebox-native-reflow-preparation-source-revision preparation)
                :context-hash
                (ebox-native-reflow-preparation-context-hash preparation)
                :viewport-width viewport-width
                :viewport-height viewport-height
                :root-width root-width
                :complete (and full-p t)))
            (error
             (ebox-native-reflow--fail-preparation
              preparation (error-message-string err))
             (signal (car err) (cdr err))))))
    (unless (or (stringp result) (plist-get result :native-patch))
      (error "Native reflow result disappeared before materialization"))
    result))

(defun ebox-native-reflow--materialize-next-ready-frame (preparation)
  "Materialize at most one ready tape into PREPARATION's Emacs frame cache."
  (let* ((queue
          (ebox-native-reflow-preparation-materialization-queue preparation))
         (entry (car queue))
         (spec (car entry))
         (full-p (cadr entry))
         (logical-key (plist-get spec :key))
         (native-key
          (ebox-native-reflow--preparation-key
           preparation logical-key full-p)))
    (when (and native-key
               (ebox-native-reflow-ready-p
                (ebox-native-reflow-preparation-native-session preparation)
                (ebox-native-reflow-preparation-generation preparation)
                native-key))
      (let* ((state
              (ebox-native-reflow--validated-preparation-state preparation))
             (result
              (ebox-native-reflow--materialize-preparation-frame
               preparation spec full-p state)))
        (puthash
         (ebox-native-reflow--preparation-cache-key logical-key full-p)
         result
         (ebox-native-reflow-preparation-frame-cache preparation))
        (setf
         (ebox-native-reflow-preparation-materialization-queue preparation)
         (cdr queue))
        t))))

(defun ebox-native-reflow--drop-materialization-entry
    (preparation logical-key full-p)
  "Remove LOGICAL-KEY's FULL-P entry from PREPARATION's preplay queue."
  (setf (ebox-native-reflow-preparation-materialization-queue preparation)
        (cl-delete-if
         (lambda (entry)
           (and (equal (plist-get (car entry) :key) logical-key)
                (eq (and (cadr entry) t) (and full-p t))))
         (ebox-native-reflow-preparation-materialization-queue preparation))))

(defun ebox-native-reflow--prepared-frame-record
    (preparation spec state result full-p)
  "Return one validated prepared frame record for RESULT and SPEC."
  (let* ((root (plist-get state :root-node))
         (region-id (ebox-native-reflow-preparation-region-id preparation))
         (root-box
          (or (and region-id (ebox--root-region-box root region-id))
              (pcase (plist-get root :ebox-type)
                ('box root)
                ('flex (plist-get root :box)))))
         (base-root-width
          (if (plist-member spec :base-root-width)
              (plist-get spec :base-root-width)
            (ebox--literal-root-pixel-width root-box)))
         (viewport-width
          (or (plist-get spec :viewport-width)
              (plist-get state :viewport-width)))
         (viewport-height
          (or (plist-get spec :viewport-height)
              (plist-get state :viewport-height))))
    (append
     (if (stringp result)
         (list :rendered result)
       (list :native-patch result
             :publication-owner 'prepared-root-native))
     (list
          :render-state state
          :node-id (ebox--ensure-node-id root)
          :runtime-revision (plist-get state :runtime-revision)
          :base-buffer-chars-modified-tick
          (with-current-buffer
              (ebox-native-reflow-preparation-buffer preparation)
            (buffer-chars-modified-tick))
          :display-signature
          (ebox-native-reflow-preparation-display-signature preparation)
          :kind (ebox-native-reflow-preparation-kind preparation)
          :region-id region-id
          :base-root-width base-root-width
          :base-viewport-width
          (if (plist-member spec :base-viewport-width)
              (plist-get spec :base-viewport-width)
            (plist-get state :viewport-width))
          :base-viewport-height
          (if (plist-member spec :base-viewport-height)
              (plist-get spec :base-viewport-height)
            (plist-get state :viewport-height))
          :root-width
          (if (plist-member spec :root-width)
              (plist-get spec :root-width)
            base-root-width)
          :viewport-width viewport-width
          :viewport-height viewport-height
          :full-p (and full-p t)
          :metadata-complete-p
          (and full-p
               (or (stringp result)
                   (plist-get result :root-render-metadata))
               t)))))

(defun ebox-native-reflow-copy-frame (preparation logical-key spec)
  "Borrow PREPARATION's complete LOGICAL-KEY output for occurrence SPEC.
The canonical cache entry remains owned by PREPARATION so a return trip can
reuse the same geometry without another native job or Emacs materialization."
  (let* ((cache (ebox-native-reflow-preparation-frame-cache preparation))
         (result
          (and cache
               (gethash
                (ebox-native-reflow--preparation-cache-key logical-key t)
                cache))))
    (when (or (stringp result) (plist-get result :native-patch))
      (ebox-native-reflow--prepared-frame-record
       preparation spec
       (ebox-native-reflow--validated-preparation-state preparation)
       result t))))

(defun ebox-native-reflow-prepare-frame
    (preparation spec &optional full-p)
  "Return PREPARATION's cached, validated one-shot prepared root for SPEC."
  (let* ((buffer (ebox-native-reflow-preparation-buffer preparation))
         (logical-key (plist-get spec :key))
         (native-key
          (ebox-native-reflow--preparation-key
           preparation logical-key full-p))
         (cache-key
          (ebox-native-reflow--preparation-cache-key logical-key full-p))
         (cache (ebox-native-reflow-preparation-frame-cache preparation)))
    (when (and native-key
               (buffer-live-p buffer)
               (ebox-native-reflow-preparation-ready-p
                preparation logical-key full-p))
      (let* ((state
              (ebox-native-reflow--validated-preparation-state preparation))
             (result
              (or (and cache (gethash cache-key cache))
                  (ebox-native-reflow--materialize-preparation-frame
                   preparation spec full-p state))))
        (when cache
          (remhash cache-key cache))
        (ebox-native-reflow--drop-materialization-entry
         preparation logical-key full-p)
        (ebox-native-reflow--prepared-frame-record
         preparation spec state result full-p)))))

(defun ebox-native-reflow-confirm-frame
    (preparation &optional spec complete-p native-full-p)
  "Advance PREPARATION after successful publication of SPEC.
COMPLETE-P means the published frame has complete root indexes.
NATIVE-FULL-P selects the native key that produced the published frame."
  (when-let* ((buffer (ebox-native-reflow-preparation-buffer preparation))
              ((buffer-live-p buffer))
              (state (ebox--buffer-render-state buffer))
              ((eq (plist-get state :root-node)
                   (ebox-native-reflow-preparation-source-root preparation))))
    (let ((confirmed-revision (or (plist-get state :runtime-revision) 0)))
      (when (and complete-p spec)
        (when-let* ((native-key
                    (ebox-native-reflow--preparation-key
                     preparation (plist-get spec :key) native-full-p)))
          (ebox-native-reflow-confirm-native-frame
           (ebox-native-reflow-preparation-native-session preparation)
           (ebox-native-reflow-preparation-generation preparation)
           native-key confirmed-revision)))
      (setf (ebox-native-reflow-preparation-expected-revision preparation)
            confirmed-revision
            (ebox-native-reflow-preparation-last-spec preparation) spec
            (ebox-native-reflow-preparation-light-p preparation)
            (not complete-p)))))

(defun ebox-native-reflow-preparation-stats (preparation)
  "Return PREPARATION's native bounded-runtime statistics."
  (or (ebox-native-reflow-preparation-final-stats preparation)
      (when-let* ((session
                  (ebox-native-reflow-preparation-native-session
                   preparation)))
        (unless (ebox-native-reflow-session-released-p session)
          (ebox-native-reflow-stats session)))))

(defun ebox-native-reflow-stop-preparation (preparation)
  "Cancel and release PREPARATION idempotently without joining workers."
  (when (and preparation
             (not (ebox-native-reflow-preparation-stopped-p preparation)))
    (setf (ebox-native-reflow-preparation-stopped-p preparation) t)
    (ebox-native-reflow--stop-preparation-ready-watch preparation)
    (ebox-native-reflow--clear-preparation-readiness preparation)
    (when-let* ((cache
                (ebox-native-reflow-preparation-frame-cache preparation)))
      (clrhash cache))
    (setf (ebox-native-reflow-preparation-materialization-queue preparation)
          nil)
    (when-let* ((session
                (ebox-native-reflow-preparation-native-session preparation)))
      (unless (ebox-native-reflow-session-released-p session)
        (ignore-errors
          (ebox-native-reflow-cancel
           session (ebox-native-reflow-preparation-generation preparation)))
        (setf (ebox-native-reflow-preparation-final-stats preparation)
              (ignore-errors (ebox-native-reflow-stats session)))
        (when (ebox-native-reflow-preparation-release-native-session-p
               preparation)
          (unwind-protect
              (ebox-native-reflow-release-session session)
            (when-let* ((stats
                        (ebox-native-reflow-preparation-final-stats
                         preparation)))
              (plist-put stats :alive nil)))))))
  nil)

(provide 'ebox-native-reflow)
;;; ebox-native-reflow.el ends here
