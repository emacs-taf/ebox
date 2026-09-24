;;; ebox-update-raster.el --- Bound raster updates for prepared publication -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Compile paint ownership and fixed Text spans from a retained layer program.
;; Execution touches only those rows, their rich text, and bound style cells.
;; The layer program owns pixel undo; source staging belongs to the caller.

;;; Code:

(require 'cl-lib)
(require 'ebox-geometry)
(require 'ebox-surface)

(cl-defstruct (ebox-update-raster (:constructor ebox-update-raster--create))
  route-index program records recipes output content-index color-index region
  role-properties role-signature content-slots)

(cl-defstruct (ebox-update-raster--recipe
               (:constructor ebox-update-raster--recipe-create))
  affected contributions hover-node hover-color hover-background hover-font)

(defvar ebox-update-raster--font-variants nil
  "Cold metric-proof overrides from bound FontFact cells to variant facts.")

(defvar ebox-update-raster--border-rows nil
  "Cold border-box row bounds keyed by raw owner and region.")
(defvar ebox-update-raster--source-row nil
  "Original row of the raw record currently being compiled.")

(defun ebox-update-raster--compile-border-rows (records)
  "Recover border-box rows from RECORDS before scalar edge tags are overwritten."
  (let ((bounds (make-hash-table :test #'equal)))
    (dotimes (index (length records))
      (let* ((record (aref records index))
             (owner (plist-get (plist-get record :node) :node-id))
             (row (plist-get record :source-row))
             (text (plist-get record :text)) (position 0))
        (while (< position (length text))
          (let ((roles (ebox-update-raster--roles text position)))
            (dolist (role roles)
              (when (and (memq (car role) '(bl br bt bb pl pr pt pb content content-owner))
                         (not (cl-some
                               (lambda (other)
                                 (and (equal (cdr other) (cdr role))
                                      (memq (car other) '(ml mr mt mb overflow-foreground))))
                               roles)))
                (let* ((key (cons owner (cdr role))) (old (gethash key bounds)))
                  (if old
                      (setcar old (min row (car old)))
                    (setq old (cons row row)) (puthash key old bounds))
                  (setcdr old (max row (cdr old)))))))
          (setq position (next-property-change position text (length text))))))
    bounds))

(cl-defstruct (ebox-update-raster--content-slot
               (:constructor ebox-update-raster--content-slot-create))
  parent width hidden content-metadata content-origin content-recipe
  fill-metadata fill-recipe clip-source-roles vertical-signature)

(cl-defstruct (ebox-update-font (:constructor ebox-update-font--create))
  buffer frame capability epoch scene terminal-cell cells originals normal bold saved
  text-cells texts admitted staged)

(defvar ebox-update-font--terminal-cell nil
  "Cold proof of the current non-graphical backend's fixed character cell.")

(defun ebox-update-raster--font-binding (cell)
  "Bind CELL to detached cold paint snapshots, separate from global FontFacts."
  (vector cell (vector (car cell))
          (vector (and (car cell) (ebox-font-paint-face (car cell))))))

(defun ebox-update-raster--font-face (binding)
  "Borrow BINDING's owner-local paint snapshot for its current prepared fact."
  (let* ((cell (aref binding 0))
         (fact (if ebox-update-raster--font-variants
                   (gethash cell ebox-update-raster--font-variants (car cell))
                 (car cell)))
         (index (cl-position fact (aref binding 1) :test #'eq)))
    (unless index (throw 'ebox-update-raster-unsupported nil))
    (aref (aref binding 2) index)))

(defconst ebox-update-raster--content-properties '(face font-lock-face display)
  "Caller Text properties supported without rebuilding a retained Text span.")

(defun ebox-update-raster--roles (text position)
  "Return paint ownership at POSITION in rich TEXT."
  (let ((roles (ebox-surface--role-ids-at text position))
        (origin (get-text-property position 'ebox--paint-origin text)))
    (if (and origin (ebox--paint-origin-source-roles origin))
        (cl-delete-duplicates
         (append (copy-sequence (ebox--paint-origin-source-roles origin)) roles)
         :test #'equal)
      roles)))

(defun ebox-update-raster--contains-region-p (text region)
  "Return whether TEXT carries a material role owned by REGION."
  (let ((position 0) found)
    (while (and (< position (length text)) (not found))
      (setq found (cl-find region (ebox-update-raster--roles text position)
                           :key #'cdr :test #'equal)
            position (next-property-change position text (length text))))
    found))

(defun ebox-update-raster--signature (properties signature text position)
  "Read TEXT at POSITION through cold PROPERTIES into reusable SIGNATURE."
  (dotimes (index (length properties))
    (aset signature index (get-text-property position (aref properties index) text)))
  (let ((origin (get-text-property position 'ebox--paint-origin text)))
    (aset signature (length properties)
          (and origin (ebox--paint-origin-source-roles origin))))
  signature)

(defun ebox-update-raster--lookup-recipe (descriptor recipes text position)
  "Look up TEXT POSITION's bound RECIPES without constructing ownership data."
  (gethash (ebox-update-raster--signature
            (ebox-update-raster-role-properties descriptor)
            (ebox-update-raster-role-signature descriptor) text position)
           recipes))

(defun ebox-update-raster--style (state node cache)
  "Compute NODE's cold cascade provenance in STATE, reusing CACHE."
  (let ((id (plist-get node :node-id)))
    (or (gethash id cache)
        (let* ((source (plist-get state :source-index))
               (parent-id (ebox-runtime-index-get id (plist-get state :parent-table)))
               (parent (and parent-id
                            (ebox-runtime-index-get parent-id (plist-get state :node-table))))
               (parent-style (and parent (ebox-update-raster--style state parent cache)))
               (ebox-selector-view--current (ebox-source--index-selector-view source))
               (ebox-selector-view--topology (ebox-source--index-selector-topology source)))
          (unless (plist-get node :ebox-source-handle)
            (throw 'ebox-update-raster-unsupported nil))
          (puthash
           id
           (ecss-compute-style
            ebox-style-schemas (ebox-source--index-node-subject source node)
            :declarations (ebox-style-node-declarations source node)
            :stylesheet ebox-style-stylesheet :parent-style parent-style
            :scopes (ebox-style-source-scopes source)
            :adapter ebox-selector-view-adapter
            :value-resolver #'ebox-resolve-value :provenance t)
           cache)))))

(defun ebox-update-raster--color-cell (state node styles cache)
  "Bind NODE's effective foreground authority using cold STYLES and CACHE.
Inherited Text colors follow their provider cell even though the Text's
ordinary computed projection is unchanged during a prepared scalar stage."
  (let* ((id (plist-get node :node-id))
         (missing 'ebox-update-raster-missing)
         (cached (gethash id cache missing)))
    (if (not (eq cached missing)) cached
      (let* ((style (ebox-update-raster--style state node styles))
             (origin (plist-get (ecss-computed-style-provenance style)
                               (ebox-style-schema-id :color)))
             (inherited (or (eq (plist-get origin :source) 'inherit)
                            (eq (plist-get origin :value-source) 'inherit)))
             (parent-id (and inherited
                             (ebox-runtime-index-get id (plist-get state :parent-table))))
             (parent (and parent-id
                          (ebox-runtime-index-get parent-id (plist-get state :node-table))))
             (cell (if parent
                       (ebox-update-raster--color-cell state parent styles cache)
                     (cdr (plist-member node :color)))))
        ;; Default foreground projection is a provider-owned sentinel.  An
        ;; inherited nil may map to that sentinel instead of its parent's nil.
        (unless (equal (car cell) (plist-get node :color))
          (throw 'ebox-update-raster-unsupported nil))
        (puthash id cell cache)))))

(defun ebox-update-raster--raw-chain (state roles owner)
  "Return ROLES' paint chain through raw raster OWNER in STATE.
An unrelated part of a full source row can be outside this record's pixel
slice.  Its chain does not reach OWNER and must retain its current paint."
  (let ((chain (ebox-surface--paint-node-chain state roles)) result found)
    (while (and chain (not found))
      (let ((id (pop chain)))
        (push id result)
        (setq found (equal id owner))))
    (and found (nreverse result))))

(defun ebox-update-raster--contributions (state roles chain styles colors owner text position)
  "Compile ROLES' raw CHAIN face contributors using STATE, STYLES and COLORS."
  (let ((nodes (plist-get state :node-table)) (first t) contributions)
    (dolist (id chain)
      (when-let* ((node (ebox-runtime-index-get id nodes))
                  (box (ebox-fragment-style-source-node node)))
        (let* ((region (plist-get box :region-id))
               (owned (cl-loop for (role . owner) in roles
                               when (equal owner region) collect role))
               (foreground (ebox-update-raster--color-cell state box styles colors))
               (background (cdr (plist-member box :bgcolor)))
               (edges (and ebox-update-raster--border-rows
                           (gethash (cons owner region) ebox-update-raster--border-rows)))
               (border-box (and (cl-intersection owned '(bl br bt bb pl pr pt pb content content-owner))
                                (not (cl-intersection owned '(ml mr mt mb overflow-foreground)))))
               (original-faces (ebox-surface--face-list (get-text-property position 'face text)))
               faces)
          (cond
           ((memq 'overflow-foreground owned)
            (push (cons 'foreground foreground) faces))
           ((memq 'bl owned)
            (push (cons 'side-border (cdr (plist-member box :border-left-color))) faces))
           ((memq 'br owned)
            (push (cons 'side-border (cdr (plist-member box :border-right-color))) faces))
           ((or (not first)
                (cl-intersection owned '(content content-owner pt pb pl pr)))
            (when (ebox-style--text-paint-owner-p box)
              (push (cons 'font (ebox-update-raster--font-binding
                                 (cdr (plist-member box :ebox-font-fact)))) faces)
              (when-let* ((decoration (ebox-buffer--text-decoration-face box)))
                (push (cons 'constant decoration) faces))
              (push (cons 'foreground foreground) faces))
            (push (cons 'background background) faces)))
          (when (and (> (or (ebox-get box :border-top-pixel) 0) 0)
                     (or (memq 'bt owned)
                         (and border-box edges (= ebox-update-raster--source-row (car edges))
                              (member (ebox-buffer--color-face (plist-get box :border-top-color) 'overline)
                                      original-faces))))
            (push (cons 'overline (cdr (plist-member box :border-top-color))) faces))
          (when (and (> (or (ebox-get box :border-bottom-pixel) 0) 0)
                     (or (memq 'bb owned)
                         (and border-box edges (= ebox-update-raster--source-row (cdr edges))
                              (member (ebox-buffer--color-face (plist-get box :border-bottom-color) 'underline)
                                      original-faces))))
            (push (cons 'underline (cdr (plist-member box :border-bottom-color))) faces))
          (setq contributions (nconc contributions (nreverse faces)) first nil))))
    (vconcat contributions)))

(defun ebox-update-raster--faces (recipe)
  "Read RECIPE's prebound face contributors without resolving a tree."
  (let (faces)
    (dotimes (index (length (ebox-update-raster--recipe-contributions recipe)))
      (let* ((entry (aref (ebox-update-raster--recipe-contributions recipe) index))
             (cell (cdr entry))
             (face
              (pcase (car entry)
                ('constant cell)
                ('font (ebox-update-raster--font-face cell))
                ('side-border (ebox-buffer-side-border-face (car cell)))
                ((or 'overline 'underline) (ebox-buffer--color-face (car cell) (car entry)))
                (_ (when (car cell) (ebox-buffer--color-face (car cell) (car entry)))))))
        (when face (push face faces))))
    (nreverse faces)))

(defun ebox-update-raster--recipe (state target owner roles text position styles colors)
  "Compile ROLES at TEXT POSITION relative to TARGET inside raw OWNER."
  (let* ((chain (ebox-update-raster--raw-chain state roles owner))
         (declaration (get-text-property position 'ebox--hover-style text))
         (hover-owner (plist-get declaration :owner))
         (hover-id (and hover-owner
                        (ebox-runtime-index-get hover-owner (plist-get state :region-node-table))))
         (hover-node (and hover-id
                          (ebox-fragment-style-source-node
                           (ebox-runtime-index-get hover-id (plist-get state :node-table)))))
         (hover-copy (and hover-node (copy-sequence hover-node))))
    (when (and declaration hover-owner (null hover-node))
      (throw 'ebox-update-raster-unsupported nil))
    (ebox-update-raster--recipe-create
     :affected (member (plist-get target :node-id) chain)
     :contributions (ebox-update-raster--contributions state roles chain styles colors owner text position)
     :hover-node hover-copy
     :hover-color (and hover-node (ebox-update-raster--color-cell state hover-node styles colors))
     :hover-background (and hover-node (cdr (plist-member hover-node :bgcolor)))
     :hover-font (and hover-node (cdr (plist-member hover-node :ebox-font-fact))))))

(defun ebox-update-raster--span (text region)
  "Find REGION's complete contiguous Text span in one known TEXT row."
  (let ((position 0) start end)
    (while (< position (length text))
      (let ((next (next-single-property-change position 'ebox-content text (length text))))
        (when (equal region (get-text-property position 'ebox-content text))
          (when (and end (/= end position))
            (throw 'ebox-update-raster-unsupported nil))
          (unless start (setq start position))
          (setq end next))
        (setq position next)))
    (and start (cons start end))))

(defun ebox-update-raster--parent-span (text region)
  "Find REGION's fixed content interval in the current known TEXT row."
  (let ((position 0) start end)
    (while (< position (length text))
      (let* ((next (next-property-change position text (length text)))
             (owned (or (equal region (get-text-property position 'ebox-content text))
                        (equal region (get-text-property position 'ebox-content-owner text))
                        (member region (get-text-property position 'ebox-content-owners text))))
             (chrome (cl-some
                      (lambda (property) (equal region (get-text-property position property text)))
                      '(ebox-pl ebox-pr ebox-bl ebox-br ebox-pt ebox-pb ebox-mt ebox-mb))))
        (when (and owned (not chrome))
          (when (and end (/= end position))
            (throw 'ebox-update-raster-unsupported nil))
          (unless start (setq start position))
          (setq end next))
        (setq position next)))
    (and start (cons start end))))

(defun ebox-update-raster--ensure-origin! (text recipe)
  "Ensure private single-run TEXT has its exact caller baseline for RECIPE."
  (unless (get-text-property 0 'ebox--paint-origin text)
    (let* ((faces (ebox-update-raster--faces recipe))
           (face (get-text-property 0 'face text))
           (baseline (ebox-surface--face-baseline face faces)))
      (unless (equal face (ebox-surface--compose-face baseline faces))
        (throw 'ebox-update-raster-unsupported nil))
      (put-text-property 0 (length text) 'ebox--paint-origin
                         (ebox--paint-origin-create :baseline (copy-tree baseline)) text)))
  text)

(defun ebox-update-raster--fixed-width-p (state node)
  "Prove NODE's retained width is independent of its sole Text's content."
  (or (not (memq (ebox-get node :width) '(nil auto min-content max-content fit-content)))
      (let* ((parent-id (ebox-runtime-index-get (plist-get node :node-id)
                                              (plist-get state :parent-table)))
             (parent (and parent-id (ebox-runtime-index-get parent-id (plist-get state :node-table))))
             (props (and parent (ebox-tree-layout-props parent)))
             (item (ebox--flex-item-props node))
             (basis (plist-get item :flex-basis))
             (minimum (ebox-get node :min-width)))
        (and (eq (ebox-tree-layout-kind parent) 'flex)
             (memq (plist-get props :flex-direction) '(nil row row-reverse))
             (memq (plist-get props :flex-wrap) '(nil nowrap))
             (> (plist-get item :flex-grow) 0)
             (consp basis) (numberp (cadr basis)) (= (cadr basis) 0)
             (consp minimum) (numberp (cadr minimum)) (= (cadr minimum) 0)
             (not (memq (ebox-get node :max-width) '(min-content max-content fit-content)))))))

(defun ebox-update-raster--prepare-slot
    (state node owner text recipes role-properties styles colors)
  "Bind an optional fixed single-line parent allocation around NODE in TEXT."
  (catch 'ebox-update-raster-unsupported
    (let* ((parent-id (ebox-runtime-index-get (plist-get node :node-id)
                                            (plist-get state :parent-table)))
           (parent (and parent-id (ebox-runtime-index-get parent-id (plist-get state :node-table))))
           (children (and parent (ebox-tree-node-children parent)))
           (parent-region (plist-get parent :region-id))
           (span (and parent-region (ebox-update-raster--parent-span text parent-region)))
           (content (ebox-update-raster--span text (plist-get node :region-id)))
           (overflow (and parent (ebox-get parent :overflow))))
      (unless (and (eq (plist-get parent :ebox-kind) 'box)
                   (= (length children) 1) (eq (car children) node)
                   (ebox-update-raster--fixed-width-p state parent)
                   (equal (ebox-get parent :height) '(lh 1))
                   (eq (ebox-get parent :text-align) 'left)
                   (ebox-style-no-soft-wrap-p (ebox-get parent :wrap-mode))
                   (memq overflow '(nil visible hidden))
                   span content (= (car span) (car content))
                   (< (cdr content) (cdr span)))
        (throw 'ebox-update-raster-unsupported nil))
      (let* ((fill (substring text (cdr content) (cdr span)))
             (sample (substring text (car content) (1+ (car content))))
             (signature (make-vector (1+ (length role-properties)) nil))
             (content-recipe
              (gethash (ebox-update-raster--signature role-properties signature text (car content)) recipes))
             (fill-recipe
              (gethash (ebox-update-raster--signature role-properties signature fill 0) recipes))
             clip-source-roles)
        (unless (and (> (length fill) 0) (string-match-p "\\` *\\'" (substring-no-properties fill))
                     content-recipe fill-recipe
                     (>= (or (next-property-change 0 fill) (length fill)) (length fill)))
          (throw 'ebox-update-raster-unsupported nil))
        (ebox-update-raster--ensure-origin! sample content-recipe)
        (ebox-update-raster--ensure-origin! fill fill-recipe)
        ;; A clipped final glyph keeps its paint-only ownership while the
        ;; parent supplies the noninteractive content interval around it.
        (let* ((clip (ebox-composite--fill sample 0 1))
               (metadata (copy-sequence (text-properties-at 0 fill))))
          (setq clip-source-roles
                (ebox--paint-origin-source-roles
                 (get-text-property 0 'ebox--paint-origin clip)))
          (dolist (property '(face font-lock-face display ebox--paint-origin))
            (cl-remf metadata property))
          (add-text-properties 0 (length clip) metadata clip)
          (let ((roles (ebox-update-raster--roles clip 0)))
            (puthash (copy-sequence
                      (ebox-update-raster--signature role-properties signature clip 0))
                     (ebox-update-raster--recipe state node owner roles clip 0 styles colors)
                     recipes)))
        (ebox-update-raster--content-slot-create
         :parent parent-region :width (ebox--substring-pixel-width text (car span) (cdr span))
         :hidden (eq overflow 'hidden)
         :content-metadata (copy-sequence (text-properties-at 0 sample))
         :content-origin (get-text-property 0 'ebox--paint-origin sample)
         :content-recipe content-recipe
         :fill-metadata (copy-sequence (text-properties-at 0 fill))
         :fill-recipe fill-recipe
         :clip-source-roles clip-source-roles
         :vertical-signature
         (ebox-update-raster--vertical-signature
          (substring text (car content) (cdr content))))))))

(defun ebox-update-raster--supported-text-p (text)
  "Return whether rich TEXT needs no multiline or unsupported caller projection."
  (and (stringp text) (> (length text) 0) (not (string-match-p "[\n\r\t]" text))
       (let ((position 0) (valid t))
         (while (and valid (< position (length text)))
           (let ((properties (text-properties-at position text))
                 (display (get-text-property position 'display text)))
             (unless (or (null display) (stringp display)
                         (memq (car-safe display) '(space image)))
               (setq valid nil))
             (when (and (stringp display)
                        (not (ebox-update-raster--supported-text-p display)))
               (setq valid nil))
             (while properties
               (unless (memq (pop properties) ebox-update-raster--content-properties)
                 (setq valid nil))
               (pop properties)))
           (setq position (next-property-change position text (length text))))
         valid)))

(defun ebox-update-font--plain-run-p (text)
  "Return non-nil when TEXT needs no unproved font/display coupling."
  (and (not (text-property-not-all 0 (length text) 'display nil text))
       (not (text-property-not-all 0 (length text) 'font-lock-face nil text))
       (let ((position 0) (valid t))
         (while (and valid (< position (length text)))
           (let ((face (get-text-property position 'face text)))
             (when face
               (setq valid
                     (and (consp face) (keywordp (car face))
                          (cl-loop for (property _value) on face by #'cddr
                                   always (memq property '(:foreground :background :underline
                                                          :overline :strike-through :inverse-video
                                                          :extend :stipple)))))))
           (setq position (next-property-change position text (length text))))
         valid)))

(defun ebox-update-font--same-vertical-glyphs-p (before after start end window)
  "Prove every actual glyph from START to END keeps vertical metrics in WINDOW."
  (let ((position start) (valid t))
    (while (and valid (< position end))
      (unless ebox-update-font--terminal-cell
        (let ((old (ebox-font--prepared-glyph-metrics before position window))
              (new (ebox-font--prepared-glyph-metrics after position window)))
          (setq valid (and old new (equal old new)))))
      (setq position (1+ position)))
    valid))

(defun ebox-update-font--same-glyph-allocation-p (before after window)
  "Prove BEFORE and AFTER retain real glyph extents under WINDOW's capability.
FontFact metrics cover ch/lh geometry; this also checks fallback fonts and
caller faces, isolated graphemes used by wrapping, and prefix shaping used
by clipping and fragment placement."
  (and (string= before after)
       (let ((before-lines (ebox-string-lines before))
             (after-lines (ebox-string-lines after))
             (valid t))
         (while (and valid before-lines)
           (let* ((old (pop before-lines)) (new (pop after-lines))
                  (position 0) (size (length old)))
             (while (and valid (< position size))
               (let ((next (ebox--grapheme-cluster-end old position)))
                 (setq valid
                       (and (ebox-update-font--same-vertical-glyphs-p old new position next window)
                            (= (ebox--substring-pixel-width old 0 next)
                               (ebox--substring-pixel-width new 0 next))
                            (= (ebox--substring-pixel-width old position next)
                               (ebox--substring-pixel-width new position next))))
                 (setq position next)))))
         valid)))

(defun ebox-update-font--text-with-fact (text fact)
  "Return caller TEXT with immutable FACT's ordinary appended font paint."
  (let ((copy (copy-sequence text)) (face (and fact (ebox-font-paint-face fact))))
    (when face (add-face-text-property 0 (length copy) face t copy))
    copy))

(defun ebox-update-font--variant-row (raster slot variants)
  "Repaint RASTER's raw SLOT with cold FontFact VARIANTS without staging it."
  (let* ((record (aref (ebox-layer--program-records (ebox-update-raster-program raster))
                       (aref (ebox-update-raster-records raster) slot)))
         (text (copy-sequence (plist-get record :text)))
         (recipes (aref (ebox-update-raster-recipes raster) slot))
         (ebox-update-raster--font-variants variants)
         (position 0))
    (while (< position (length text))
      (let* ((next (next-property-change position text (length text)))
             (recipe (ebox-update-raster--lookup-recipe raster recipes text position)))
        (unless recipe (throw 'ebox-update-font-unsupported nil))
        (when (ebox-update-raster--recipe-affected recipe)
          (let* ((origin (get-text-property position 'ebox--paint-origin text))
                 (face (ebox-surface--compose-face
                        (and origin (ebox--paint-origin-baseline origin))
                        (ebox-update-raster--faces recipe))))
            (unless origin (throw 'ebox-update-font-unsupported nil))
            (if face (put-text-property position next 'face face text)
              (remove-text-properties position next '(face nil) text))))
        (setq position next)))
    text))

(defun ebox-update-font--same-row-allocation-p (before after window)
  "Prove a bound raw row's BEFORE/AFTER glyph and fixed-space allocations."
  (and (string= before after)
       (= (ebox--string-pixel-width before) (ebox--string-pixel-width after))
       (let ((position 0) (valid t) (size (length before)))
         (while (and valid (< position size))
           (let* ((display (get-text-property position 'display before))
                  (next (if display
                            (next-single-property-change position 'display before size)
                          (min (next-single-property-change position 'display before size)
                               (ebox--grapheme-cluster-end before position)))))
             (setq valid
                   (and (equal-including-properties display (get-text-property position 'display after))
                        (= (ebox--substring-pixel-width before 0 next)
                           (ebox--substring-pixel-width after 0 next))
                        (= (ebox--substring-pixel-width before position next)
                           (ebox--substring-pixel-width after position next))
                        (if (equal (get-text-property position 'face before)
                                   (get-text-property position 'face after))
                            t
                          (if display
                            ;; Fixed spaces and unchanged images preserve
                            ;; their own extent.  Other display programs use
                            ;; the ordinary path for font transitions.
                              (memq (car-safe display) '(space image))
                            (ebox-update-font--same-vertical-glyphs-p
                             before after position next window)))))
             (setq position next)))
         valid)))

(defun ebox-update-font--bind-variants (raster normal bold)
  "Compile detached NORMAL/BOLD face snapshots into RASTER's fixed bindings."
  (dotimes (slot (length (ebox-update-raster-recipes raster)))
    (maphash
     (lambda (_signature recipe)
       (let ((contributions (ebox-update-raster--recipe-contributions recipe)))
         (dotimes (index (length contributions))
           (let ((entry (aref contributions index)))
             (when (eq (car entry) 'font)
               (let* ((binding (cdr entry)) (cell (aref binding 0))
                      (missing 'ebox-update-font-missing))
                 (dolist (variants (list normal bold))
                   (let ((fact (gethash cell variants missing)))
                     (unless (or (eq fact missing) (cl-position fact (aref binding 1) :test #'eq))
                       (aset binding 1 (vconcat (aref binding 1) (vector fact)))
                       (aset binding 2 (vconcat (aref binding 2)
                                               (vector (and fact (ebox-font-paint-face fact))))))))))))))
     (aref (ebox-update-raster-recipes raster) slot)))
  raster)

(defun ebox-update-font-bind-raster (plan raster)
  "Bind PLAN's detached paint variants into RASTER during cohort preparation.
Call for every prepared cohort raster after all font plans exist; sibling
paint/content recipes then retain current fonts across sparse publications."
  (let ((normal (make-hash-table :test #'eq)) (bold (make-hash-table :test #'eq)))
    (dotimes (index (length (ebox-update-font-cells plan)))
      (let ((cell (aref (ebox-update-font-cells plan) index)))
        (puthash cell (aref (ebox-update-font-normal plan) index) normal)
        (puthash cell (aref (ebox-update-font-bold plan) index) bold)))
    (ebox-update-font--bind-variants raster normal bold)))

(defun ebox-update-font-prepare (state routes node &optional raster scene)
  "Prepare actual normal/bold font variants for NODE's inherited STATE scope.
Call in the target buffer under the scene's display capability.  Optional
RASTER reuses its cold row recipes; SCENE supplies the allocation-free warm
display validity check.  Return nil when any actual FontFact,
caller/fallback glyph, ch/lh dimension or retained row changes allocation.
Preparation never stages source facts or node FontFacts."
  (catch 'ebox-update-font-unsupported
   (catch 'ebox-update-raster-unsupported
    (let* ((buffer (current-buffer))
           (window (or ebox-surface--font-window
                       (ebox-surface--buffer-display-window buffer)
                       (selected-window)))
           (frame (window-frame window))
           (capability (ebox--display-signature-for-frame frame))
           (ebox-update-font--terminal-cell
            (and (not (display-graphic-p frame))
                 (> (frame-char-width frame) 0) (> (frame-char-height frame) 0)
                 (vector (frame-char-width frame) (frame-char-height frame))))
           (styles (make-hash-table :test #'equal))
           (normal-map (make-hash-table :test #'eq))
           (bold-map (make-hash-table :test #'eq))
           (parents (plist-get state :parent-table))
           (nodes (plist-get state :node-table))
           (parent-id (ebox-runtime-index-get (plist-get node :node-id) parents))
           (parent (and parent-id (ebox-runtime-index-get parent-id nodes)))
           (parent-fact (plist-get parent :ebox-font-fact))
           (raster (or raster (ebox-update-raster-prepare state routes node [:font-weight])))
           cells originals normal bold text-cells texts text-facts)
      (unless raster (throw 'ebox-update-font-unsupported nil))
      ;; A font scope enclosing a lower independently composed plane needs
      ;; persistent replay in that plane as well as this raster.  This fixed
      ;; recipe owns one route, so do not admit such a scope opportunistically.
      (dotimes (index (ebox-update-raster-route-index raster))
        (let ((id (plist-get (ebox-geometry--route-wrapper (aref routes index)) :node-id)))
          (while id
            (when (equal id (plist-get node :node-id))
              (throw 'ebox-update-font-unsupported nil))
            (setq id (ebox-runtime-index-get id parents)))))
      (unless (with-current-buffer (window-buffer window)
                (equal capability (ebox--display-signature-for-frame frame)))
        (throw 'ebox-update-font-unsupported nil))
      (cl-labels
          ((visit
            (current parent-normal parent-bold normal-weight bold-weight)
            (let* ((style (ebox-update-raster--style state current styles))
                   (values (ecss-computed-style-values style))
                   (specified (ecss-computed-style-specified-properties style))
                   (origin (plist-get (ecss-computed-style-provenance style) 'ebox/font-weight))
                   (inherit (or (eq (plist-get origin :source) 'inherit)
                                (eq (plist-get origin :value-source) 'inherit)))
                   (weight (plist-get values 'ebox/font-weight))
                   (own-p (eq current node))
                   (normal-weight (if own-p 'normal (if inherit normal-weight weight)))
                   (bold-weight (if own-p 'bold (if inherit bold-weight weight)))
                   (normal-values (plist-put (copy-sequence values) 'ebox/font-weight normal-weight))
                   (bold-values (plist-put (copy-sequence values) 'ebox/font-weight bold-weight))
                   (cell (cdr (plist-member current :ebox-font-fact)))
                   (old (car cell))
                   (next-normal (ebox-font-project-values
                                 normal-values specified capability window parent-normal))
                   (next-bold (ebox-font-project-values
                               bold-values specified capability window parent-bold)))
              (when (and own-p
                         (not (and (memq weight '(normal bold)) (plist-get origin :inline))))
                (throw 'ebox-update-font-unsupported nil))
              (unless cell (throw 'ebox-update-font-unsupported nil))
              (puthash cell next-normal normal-map)
              (puthash cell next-bold bold-map)
              (unless (equal next-normal next-bold)
                (unless (and (ebox-font--prepared-metrics-equal-p
                              old next-normal capability window ebox-update-font--terminal-cell)
                             (ebox-font--prepared-metrics-equal-p
                              old next-bold capability window ebox-update-font--terminal-cell))
                  (throw 'ebox-update-font-unsupported nil))
                (push cell cells) (push old originals)
                (push next-normal normal) (push next-bold bold))
              (when (eq (plist-get current :ebox-kind) 'text)
                (let* ((text-cell (cdr (plist-member current :ebox-text-value)))
                       (text (car text-cell)))
                  (unless (and text-cell (stringp text) (ebox-update-font--plain-run-p text))
                    (throw 'ebox-update-font-unsupported nil))
                  (push text-cell text-cells) (push (copy-sequence text) texts)
                  (push (vector text old next-normal next-bold) text-facts)))
              (ebox-tree-for-each-direct-child
               current (lambda (child)
                         (visit child next-normal next-bold normal-weight bold-weight))))))
        (visit node parent-fact parent-fact
               (and parent (ebox-style-computed-value (ebox-update-raster--style state parent styles) :font-weight))
               (and parent (ebox-style-computed-value (ebox-update-raster--style state parent styles) :font-weight))))
      (unless cells (throw 'ebox-update-font-unsupported nil))
      (dolist (entry text-facts)
        (let* ((text (aref entry 0))
               (before (ebox-update-font--text-with-fact text (aref entry 1))))
          (unless (and (ebox-update-font--same-glyph-allocation-p
                        before (ebox-update-font--text-with-fact text (aref entry 2)) window)
                       (ebox-update-font--same-glyph-allocation-p
                        before (ebox-update-font--text-with-fact text (aref entry 3)) window))
            (throw 'ebox-update-font-unsupported nil))))
      (ebox-update-font--bind-variants raster normal-map bold-map)
      (dotimes (slot (length (ebox-update-raster-records raster)))
        (let* ((record (aref (ebox-layer--program-records (ebox-update-raster-program raster))
                             (aref (ebox-update-raster-records raster) slot)))
               (before (plist-get record :text)))
          (unless (and (ebox-update-font--same-row-allocation-p
                        before (ebox-update-font--variant-row raster slot normal-map) window)
                       (ebox-update-font--same-row-allocation-p
                        before (ebox-update-font--variant-row raster slot bold-map) window))
            (throw 'ebox-update-font-unsupported nil))))
      (setq cells (nreverse cells) originals (nreverse originals)
            normal (nreverse normal) bold (nreverse bold))
      (ebox-update-font--create
       :buffer buffer :frame frame :capability capability :epoch ebox-font--measurement-epoch
       :scene scene :terminal-cell ebox-update-font--terminal-cell
       :cells (vconcat cells) :originals (vconcat originals)
       :normal (vconcat normal) :bold (vconcat bold) :saved (make-vector (length cells) nil)
       :text-cells (vconcat (nreverse text-cells)) :texts (vconcat (nreverse texts))
       :admitted t :staged nil)))))

(defun ebox-update-font-current-p (plan)
  "Return whether PLAN still names its proven Text and display inputs.
Plans prepared without SCENE require the owner to check the shared scene's
display capability before this predicate, as before ordinary raster updates."
  (and (ebox-update-font-p plan) (ebox-update-font-admitted plan)
       (buffer-live-p (ebox-update-font-buffer plan)) (frame-live-p (ebox-update-font-frame plan))
       (= ebox-font--measurement-epoch (ebox-update-font-epoch plan))
       (or (null (ebox-update-font-scene plan))
           (ebox-geometry--display-current-p (ebox-update-font-scene plan)))
       (or (null (ebox-update-font-terminal-cell plan))
           (and (not (display-graphic-p (ebox-update-font-frame plan)))
                (= (frame-char-width (ebox-update-font-frame plan))
                   (aref (ebox-update-font-terminal-cell plan) 0))
                (= (frame-char-height (ebox-update-font-frame plan))
                   (aref (ebox-update-font-terminal-cell plan) 1))))
       (cl-loop for index below (length (ebox-update-font-text-cells plan))
                always (equal-including-properties
                        (car (aref (ebox-update-font-text-cells plan) index))
                        (aref (ebox-update-font-texts plan) index)))
       (cl-loop for index below (length (ebox-update-font-cells plan))
                for current = (car (aref (ebox-update-font-cells plan) index))
                always (or (eq current (aref (ebox-update-font-originals plan) index))
                           (eq current (aref (ebox-update-font-normal plan) index))
                           (eq current (aref (ebox-update-font-bold plan) index))))))

(defun ebox-update-font-valid-p (plan weight)
  "Return whether PLAN admits WEIGHT after all cohort source cells are staged."
  (and (memq weight '(normal bold)) (ebox-update-font-current-p plan)))

(defun ebox-update-font-stage (plan weight)
  "Stage PLAN's prebound FontFact cells for previously validated WEIGHT."
  (unless (and (memq weight '(normal bold)) (not (ebox-update-font-staged plan)))
    (error "Invalid Ebox prepared font stage"))
  (let ((facts (if (eq weight 'bold) (ebox-update-font-bold plan) (ebox-update-font-normal plan)))
        (inhibit-quit t))
    (dotimes (index (length (ebox-update-font-cells plan)))
      (aset (ebox-update-font-saved plan) index (car (aref (ebox-update-font-cells plan) index))))
    (setf (ebox-update-font-staged plan) t)
    (dotimes (index (length (ebox-update-font-cells plan)))
      (setcar (aref (ebox-update-font-cells plan) index) (aref facts index))))
  t)

(defun ebox-update-font-rollback (plan)
  "Restore PLAN's fixed FontFact cells after a declined or rejected cohort."
  (when (ebox-update-font-staged plan)
    (let ((inhibit-quit t))
      (dotimes (index (length (ebox-update-font-cells plan)))
        (setcar (aref (ebox-update-font-cells plan) index) (aref (ebox-update-font-saved plan) index)))
      (setf (ebox-update-font-staged plan) nil)))
  nil)

(defun ebox-update-font-accept (plan)
  "Accept PLAN's staged font variants after successful publication."
  (setf (ebox-update-font-staged plan) nil)
  t)

(defun ebox-update-raster--face-geometry (face)
  "Return FACE's geometry facts, excluding ordinary foreground/background paint."
  (cond
   ((and (consp face) (keywordp (car face)))
    (let ((copy (copy-sequence face)))
      (dolist (property '(:foreground :background :inverse-video))
        (cl-remf copy property))
      copy))
   ((consp face)
    (delq nil (mapcar #'ebox-update-raster--face-geometry face)))
   (t face)))

(defun ebox-update-raster--display-geometry (display)
  "Return DISPLAY's vertical geometry, declining unsupported image measurement."
  (cond
   ((stringp display)
    (list 'string (ebox-update-raster--vertical-signature display)))
   ((eq (car-safe display) 'space)
    (let ((copy (copy-sequence (cdr display))))
      (cl-remf copy :width)
      (cons 'space copy)))
   ((eq (car-safe display) 'image)
    (let ((size (condition-case nil (image-size display t)
                  (error (throw 'ebox-update-raster-unsupported nil)))))
      (unless (and (consp size) (numberp (cdr size)))
        (throw 'ebox-update-raster-unsupported nil))
      (list 'image (cdr size) (plist-get (cdr display) :ascent)
            (plist-get (cdr display) :margin) (plist-get (cdr display) :relief))))
   (t display)))

(defun ebox-update-raster--vertical-signature (text)
  "Return TEXT's ordered distinct vertical glyph and font geometry."
  (let ((position 0) signatures previous)
    (while (< position (length text))
      (let ((signature
             (list (ebox-update-raster--face-geometry
                    (get-text-property position 'face text))
                   (ebox-update-raster--face-geometry
                    (get-text-property position 'font-lock-face text))
                   (ebox-update-raster--display-geometry
                    (get-text-property position 'display text)))))
        (unless (equal signature previous)
          (push signature signatures)
          (setq previous signature)))
      (setq position (next-property-change position text (length text))))
    (nreverse signatures)))

(defun ebox-update-raster-prepare (state routes node properties)
  "Bind NODE's raster PROPERTIES in STATE to the lowest applicable ROUTES.
PROPERTIES fixes the value-vector order and may also include geometry keys.
Return an opaque descriptor or nil when fixed paint or Text ownership cannot
be proved.  Source facts, published pixels and revisions remain untouched."
  (catch 'ebox-update-raster-unsupported
    (let ((region (plist-get node :region-id)) (route-index 0) program
          (content-index (cl-position :content properties))
          (color-index (cl-position :color properties))
          (paint-p (cl-some (lambda (property)
                              (memq property '(:color :background-color :bgcolor :font-weight
                                               :border :border-color :border-top-color
                                               :border-right-color :border-bottom-color :border-left-color)))
                            (append properties nil))))
      (unless (and (vectorp routes) (> (length routes) 0) region)
        (throw 'ebox-update-raster-unsupported nil))
      (when content-index
        (unless (and (eq (plist-get node :ebox-kind) 'text)
                     (ebox-update-raster--supported-text-p (plist-get node :content)))
          (throw 'ebox-update-raster-unsupported nil)))
      (if (not (or paint-p content-index))
          (ebox-update-raster--create :route-index 0 :records [] :output [])
        (while (and (< route-index (length routes)) (null program))
          (let* ((candidate (ebox-geometry--route-program (aref routes route-index)))
                 (records (ebox-layer--program-records candidate))
                 (index 0))
            (while (and (< index (length records)) (null program))
              (when (ebox-update-raster--contains-region-p
                     (plist-get (aref records index) :text) region)
                (setq program candidate))
              (setq index (1+ index))))
          (unless program (setq route-index (1+ route-index))))
        (unless program (throw 'ebox-update-raster-unsupported nil))
        (let* ((records (ebox-layer--program-records program))
              (ebox-update-raster--border-rows (ebox-update-raster--compile-border-rows records))
              (role-properties
               (vconcat '(ebox-overflow-foreground-source ebox-content-owners)
                        (mapcar #'cdr ebox-region-types)))
              (styles (make-hash-table :test #'equal))
              (colors (make-hash-table :test #'equal)) indexes tables slots)
          (dotimes (index (length records))
            (let* ((record (aref records index))
                   (ebox-update-raster--source-row (plist-get record :source-row))
                   (text (plist-get record :text))
                   (owner (plist-get (plist-get record :node) :node-id))
                   (recipes (make-hash-table :test #'equal))
                   (position 0) affected)
              (while (< position (length text))
                (let* ((next (next-property-change position text (length text)))
                       (roles (ebox-update-raster--roles text position))
                       (signature (ebox-update-raster--signature
                                   role-properties (make-vector (1+ (length role-properties)) nil)
                                   text position))
                       (recipe (or (gethash signature recipes)
                                   (puthash signature (ebox-update-raster--recipe
                                                   state node owner roles text position styles colors)
                                            recipes))))
                  (when (ebox-update-raster--recipe-affected recipe) (setq affected t))
                  (setq position next)))
              (when affected
                (when content-index
                  (let ((span (ebox-update-raster--span text region)))
                    (unless (and span
                                 (string= (substring text (car span) (cdr span))
                                          (plist-get node :content)))
                      (throw 'ebox-update-raster-unsupported nil))))
                (push (and content-index
                           (ebox-update-raster--prepare-slot
                            state node owner text recipes role-properties styles colors)) slots)
                (push recipes tables)
                (push index indexes))))
          (unless indexes (throw 'ebox-update-raster-unsupported nil))
          ;; Stamp caller baselines into the private program raster.  They
          ;; travel with the row through later content splices and pixel undo.
          (cl-mapc
           (lambda (index recipes)
            (let* ((text (plist-get (aref records index) :text)) (position 0))
              (while (< position (length text))
                (let* ((next (next-property-change position text (length text)))
                       (recipe (gethash (ebox-update-raster--signature
                                         role-properties (make-vector (1+ (length role-properties)) nil)
                                         text position) recipes)))
                  (when (and (ebox-update-raster--recipe-affected recipe)
                             (not (get-text-property position 'ebox--paint-origin text)))
                    (let* ((faces (ebox-update-raster--faces recipe))
                           (face (get-text-property position 'face text))
                           (baseline (ebox-surface--face-baseline face faces)))
                      (unless (equal face (ebox-surface--compose-face baseline faces))
                        (throw 'ebox-update-raster-unsupported nil))
                      (put-text-property
                       position next 'ebox--paint-origin
                       (ebox--paint-origin-create :baseline (copy-tree baseline)) text)))
                  (setq position next)))))
           indexes tables)
          (setq indexes (nreverse indexes) tables (nreverse tables) slots (nreverse slots))
          (ebox-update-raster--create
           :route-index route-index :program program :records (vconcat indexes)
           :recipes (vconcat tables) :output (make-vector (length indexes) nil)
           :content-index content-index :color-index color-index :region region
           :role-properties role-properties
           :role-signature (make-vector (1+ (length role-properties)) nil)
           :content-slots (vconcat slots)))))))

(defun ebox-update-raster--paint! (text start end recipe)
  "Apply one prebound RECIPE to TEXT between START and END."
  (let* ((origin (get-text-property start 'ebox--paint-origin text))
         (baseline (and origin (ebox--paint-origin-baseline origin)))
         (face (ebox-surface--compose-face baseline (ebox-update-raster--faces recipe))))
    (unless origin (throw 'ebox-update-raster-unsupported nil))
    (if face (put-text-property start end 'face face text)
      (remove-text-properties start end '(face nil) text))
    (when-let* ((declaration (get-text-property start 'ebox--hover-style text))
                (node (ebox-update-raster--recipe-hover-node recipe)))
      (plist-put node :color (car (ebox-update-raster--recipe-hover-color recipe)))
      (plist-put node :bgcolor (car (ebox-update-raster--recipe-hover-background recipe)))
      (plist-put node :ebox-font-fact (car (ebox-update-raster--recipe-hover-font recipe)))
      (put-text-property
       start end 'ebox--hover-style
       (plist-put (copy-sequence declaration) :base
                  (plist-get (ebox-buffer-paint-text-properties node 'content) 'face))
       text))
    (ebox-interaction--refresh-hover! text start end))
  text)

(defun ebox-update-raster--decorate-value (value metadata origin recipe)
  "Project caller VALUE through retained METADATA, paint ORIGIN and RECIPE."
  (let ((text (copy-sequence value))
        (properties (copy-sequence metadata))
        (position 0))
    (dolist (property '(face font-lock-face display ebox--paint-origin))
      (cl-remf properties property))
    (add-text-properties 0 (length text) properties text)
    (while (< position (length text))
      (let ((next (next-property-change position text (length text))))
        (put-text-property
         position next 'ebox--paint-origin
         (ebox--paint-origin-create
          :baseline (copy-tree (get-text-property position 'face text))
          :source-roles (and origin (ebox--paint-origin-source-roles origin))) text)
        (ebox-update-raster--paint! text position next recipe)
        (setq position next)))
    text))

(defun ebox-update-raster--clip-slot (text width slot)
  "Clip rich TEXT to WIDTH with SLOT's cold paint-only clipping ownership."
  (let ((position 0) (pixel 0) result)
    (while (and (< position (length text)) (null result))
      (let* ((next (ebox-composite--unit-end text position))
             (next-pixel (ebox--substring-pixel-width text 0 next)))
        (if (<= next-pixel width)
            (setq position next pixel next-pixel)
          (let* ((remaining (- width pixel))
                 (origin (get-text-property position 'ebox--paint-origin text))
                 (fill
                  (if (ebox--display-space-width (get-text-property position 'display text))
                      (ebox-composite--space text position next remaining)
                    (let ((blank (ebox-pixel-space remaining)))
                      (when (> (length blank) 0)
                        (dolist (property '(face font-lock-face))
                          (when-let* ((value (get-text-property position property text)))
                            (put-text-property 0 (length blank) property value blank)))
                        (put-text-property
                         0 (length blank) 'ebox--paint-origin
                         (ebox--paint-origin-create
                          :baseline (and origin (ebox--paint-origin-baseline origin))
                          :source-roles (ebox-update-raster--content-slot-clip-source-roles slot))
                         blank))
                      blank))))
            (setq result (concat (substring text 0 position) fill))))))
    (or result text)))

(defun ebox-update-raster--replace-slot (descriptor recipes text value slot)
  "Replace VALUE inside SLOT's fixed row in TEXT without changing its extent."
  (let* ((span (ebox-update-raster--parent-span
                text (ebox-update-raster--content-slot-parent slot)))
         (width (ebox-update-raster--content-slot-width slot))
         (replacement
          (ebox-update-raster--decorate-value
           value (ebox-update-raster--content-slot-content-metadata slot)
           (ebox-update-raster--content-slot-content-origin slot)
           (ebox-update-raster--content-slot-content-recipe slot))))
    (unless (and span (= width (ebox--substring-pixel-width text (car span) (cdr span)))
                 (equal (ebox-update-raster--content-slot-vertical-signature slot)
                        (ebox-update-raster--vertical-signature replacement)))
      (throw 'ebox-update-raster-unsupported nil))
    (if (> (ebox--string-pixel-width replacement) width)
        (if (not (ebox-update-raster--content-slot-hidden slot))
            (throw 'ebox-update-raster-unsupported nil)
          (setq replacement (ebox-update-raster--clip-slot replacement width slot))
          (let ((position 0)
                (metadata (copy-sequence (ebox-update-raster--content-slot-fill-metadata slot))))
            (dolist (property '(face font-lock-face display ebox--paint-origin))
              (cl-remf metadata property))
            (while (< position (length replacement))
              (let ((next (next-property-change position replacement (length replacement))))
                (unless (get-text-property position 'ebox-content replacement)
                  (add-text-properties position next metadata replacement))
                (setq position next)))))
      (let* ((remaining (- width (ebox--string-pixel-width replacement)))
             (fill (ebox-pixel-space remaining)))
        (when (> (length fill) 0)
          (let ((metadata (copy-sequence (ebox-update-raster--content-slot-fill-metadata slot))))
            (cl-remf metadata 'display)
            (add-text-properties 0 (length fill) metadata fill))
          (ebox-update-raster--paint!
           fill 0 (length fill) (ebox-update-raster--content-slot-fill-recipe slot)))
        (setq replacement (ebox-composite--join (list replacement fill)))))
    ;; The new clipped paint signature was compiled alongside the ordinary
    ;; trailing fill.  No unknown ownership is admitted after a glyph cut.
    (let ((position 0))
      (while (< position (length replacement))
        (unless (ebox-update-raster--lookup-recipe descriptor recipes replacement position)
          (throw 'ebox-update-raster-unsupported nil))
        (setq position (next-property-change position replacement (length replacement)))))
    (unless (= width (ebox--string-pixel-width replacement))
      (throw 'ebox-update-raster-unsupported nil))
    (concat (substring text 0 (car span)) replacement (substring text (cdr span)))))

(defun ebox-update-raster--replace-content (descriptor recipes text value &optional slot)
  "Splice rich VALUE into DESCRIPTOR's current TEXT using bound RECIPES."
  (unless (ebox-update-raster--supported-text-p value)
    (throw 'ebox-update-raster-unsupported nil))
  (if slot (ebox-update-raster--replace-slot descriptor recipes text value slot)
    (let* ((span (ebox-update-raster--span text (ebox-update-raster-region descriptor)))
         (start (car span)) (end (cdr span))
         (recipe (and span (ebox-update-raster--lookup-recipe descriptor recipes text start))))
    (unless recipe (throw 'ebox-update-raster-unsupported nil))
    (let ((position start))
      (while (< position end)
        (unless (eq recipe (ebox-update-raster--lookup-recipe descriptor recipes text position))
          (throw 'ebox-update-raster-unsupported nil))
        (setq position (next-property-change position text end))))
    (let ((replacement (copy-sequence value))
          (metadata (copy-sequence (text-properties-at start text)))
          (old-origin (get-text-property start 'ebox--paint-origin text))
          (position 0))
      (dolist (property '(face font-lock-face display ebox--paint-origin))
        (cl-remf metadata property))
      (add-text-properties 0 (length replacement) metadata replacement)
      (while (< position (length replacement))
        (let ((next (next-property-change position replacement (length replacement))))
          (put-text-property
           position next 'ebox--paint-origin
           (ebox--paint-origin-create
            :baseline (copy-tree (get-text-property position 'face replacement))
            :source-roles (and old-origin (ebox--paint-origin-source-roles old-origin)))
           replacement)
          (ebox-update-raster--paint! replacement position next recipe)
          (setq position next)))
      (unless (= (ebox--substring-pixel-width text start end)
                 (ebox--string-pixel-width replacement))
        (throw 'ebox-update-raster-unsupported nil))
      (unless (equal (ebox-update-raster--vertical-signature (substring text start end))
                     (ebox-update-raster--vertical-signature replacement))
        (throw 'ebox-update-raster-unsupported nil))
      (concat (substring text 0 start) replacement (substring text end))))))

(defun ebox-update-raster-apply (descriptor values)
  "Apply already staged VALUES through DESCRIPTOR's retained raster bindings.
The caller stages source/node cells before this call and restores them when
nil is returned or an error escapes.  Unknown rich-text ownership and changed
Text pixel footprints decline before this descriptor changes its program.
Layer program settlement owns rollback after successful primitive staging."
  (catch 'ebox-update-raster-unsupported
    (let* ((program (ebox-update-raster-program descriptor))
           (indexes (ebox-update-raster-records descriptor))
           (records (and program (ebox-layer--program-records program)))
           (recipe-tables (ebox-update-raster-recipes descriptor))
           (output (ebox-update-raster-output descriptor))
           (content-index (ebox-update-raster-content-index descriptor)))
      (when (and (ebox-update-raster-color-index descriptor)
                 (null (aref values (ebox-update-raster-color-index descriptor))))
        (throw 'ebox-update-raster-unsupported nil))
      (dotimes (slot (length indexes))
        (let* ((record (aref records (aref indexes slot)))
               (old (plist-get record :text))
               (recipes (aref recipe-tables slot))
               (text (if content-index
                         (ebox-update-raster--replace-content
                          descriptor recipes old (aref values content-index)
                          (aref (ebox-update-raster-content-slots descriptor) slot))
                       (copy-sequence old)))
               (position 0))
          (while (< position (length text))
            (let* ((next (next-property-change position text (length text)))
                   (recipe (ebox-update-raster--lookup-recipe descriptor recipes text position)))
              (unless recipe (throw 'ebox-update-raster-unsupported nil))
              (when (ebox-update-raster--recipe-affected recipe)
                (ebox-update-raster--paint! text position next recipe))
              (setq position next)))
          (unless (= (ebox--string-pixel-width old) (ebox--string-pixel-width text))
            (throw 'ebox-update-raster-unsupported nil))
          (aset output slot text)))
      (dotimes (slot (length indexes))
        (ebox-layer--program-replace-text program (aref indexes slot) (aref output slot)))
      t)))

(provide 'ebox-update-raster)
;;; ebox-update-raster.el ends here
