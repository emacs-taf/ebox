;;; ebox.el --- Pixel-perfect box model renderer -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ebox contributors
;; Version: 3.0.0
;; Package-Requires: ((emacs "29.1") (ecss "0.1.0") (tp "2.0.0"))
;; Keywords: ui, graphics, convenience
;; URL: https://gitea.gklazycat.heiyu.space/geekinney/ebox

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.  See LICENSE for the full text.

;;; Commentary:

;; Public API
;;
;; Load this package with (require 'ebox) after adding the repository
;; root to load-path.
;; Only the interfaces listed below are supported for use by other packages.
;; All unlisted symbols and implementation features are internal, including
;; names without a double hyphen. Do not require files below lisp/ from consumers.
;; This Commentary is the authoritative export list; implementations and precise
;; docstrings remain beside their definitions. The manual contains workflows.
;;
;; Function: ebox-box-create (&rest plist)
;;;###autoload (autoload 'ebox-box-create "ebox" nil nil)
;; Create a canonical BoxNode from evaluated PLIST.
;;
;; `:layout' must occur exactly once as an `ebox-layout-config'.
;; `:children' is a list of canonical nodes or transparent Range descriptors.
;; Range children require an open `:source-builder' owning their source handles.
;; Every Layout accepts zero or more children according to its own formatting
;; algorithm.  `:source-handle' remains the node's only author source input.
;;
;; Function: ebox-box-node-children (node)
;;;###autoload (autoload 'ebox-box-node-children "ebox" nil nil)
;; Return canonical BoxNode NODE's material Text/Box children.
;;
;; Function: ebox-box-node-layout (node)
;;;###autoload (autoload 'ebox-box-node-layout "ebox" nil nil)
;; Return canonical BoxNode NODE's typed layout config.
;;
;; Function: ebox-box-node-p (node)
;;;###autoload (autoload 'ebox-box-node-p "ebox" nil nil)
;; Return non-nil when NODE is a canonical BoxNode.
;;
;; Function: ebox-box-node-range-anchors (node)
;;;###autoload (autoload 'ebox-box-node-range-anchors "ebox" nil nil)
;; Return transparent Range anchors retained by canonical BoxNode NODE.
;;
;; Function: ebox-buffer-mode (&optional arg)
;;;###autoload (autoload 'ebox-buffer-mode "ebox" nil t)
;; Minor mode for mounted Ebox buffers, enabled after successful mount and
;; disabled on unmount. Its shared map supplies scrolling, cyclic TAB/backtab
;; navigation over declared tab stops, and RET/return activation. Native node
;; maps supply their own keys; generated activation commands respect focus.
;;
;; This is a minor mode.  If called interactively, toggle the `Ebox-Buffer
;; mode' mode.  If the prefix argument is positive, enable the mode, and if
;; it is zero or negative, disable the mode.
;;
;; If called from Lisp, toggle the mode if ARG is `toggle'.  Enable the
;; mode if ARG is nil, omitted, or is a positive number.  Disable the mode
;; if ARG is a negative number.
;;
;; To check whether the minor mode is enabled in the current buffer,
;; evaluate the variable `ebox-buffer-mode'.
;;
;; The mode's hook is called both when the mode is enabled and when it is
;; disabled.
;;
;; \{ebox-buffer-mode-map}
;;
;; Hook: ebox-buffer-mode-hook
;; Hook run after entering or leaving `ebox-buffer-mode'.
;; No problems result if this variable is not bound.
;; `add-hook' automatically binds it.  (This is true for all hook variables.)
;; Register callbacks with add-hook; remove them with remove-hook on teardown.
;;
;; Function: ebox-buffer-set-observer (buffer-or-name observer-or-nil)
;;;###autoload (autoload 'ebox-buffer-set-observer "ebox" nil nil)
;; Set BUFFER-OR-NAME's publication observer to OBSERVER-OR-NIL.
;; The observer receives BUFFER and one defensive flat report at a time after an
;; accepted publication.  TP's report is delivered first, followed by Ebox's
;; completed report.  Nil removes observation without affecting rendering.
;;
;; Function: ebox-buffer-update-report (buffer-or-name)
;;;###autoload (autoload 'ebox-buffer-update-report "ebox" nil nil)
;; Return BUFFER-OR-NAME's stored update report.
;; The returned plist is a defensive copy of the report owned by the live rendered
;; buffer.  Signal `user-error' when the target is missing, dead, or has no Ebox
;; runtime.  A freshly rendered buffer returns nil until its first update
;; publication.
;; When `ebox-buffer-set-observer' enables observation, optional
;; :projection-rejections lists attempted local projections and their
;; :reasons; entries contain :projection and :reasons symbols. These are recorded
;; proof boundaries, not exhaustive causes or CPU costs. Another local route may
;; succeed; :projection-kind describes the actual published route. See the manual
;; for reason meanings and the update-effect evaluator for aggregate diagnostics.
;;
;; Function: ebox-build (dsl)
;;;###autoload (autoload 'ebox-build "ebox" nil nil)
;; Compile an Ebox author form into one opaque canonical input.
;; :disabled t derives the disabled selector state. Author :states may contain
;; custom states, but declaring disabled, focus or active there signals an error.
;; Focus and active are derived only for mounted buffers, through ebox-focus and
;; generated primary-button gestures respectively.
;;
;; Function: ebox-byte-compile ()
;;;###autoload (autoload 'ebox-byte-compile "ebox" nil t)
;; Recompile every active Ebox Lisp source into a neighboring `.elc' file.
;; The command is safe to run repeatedly after updating Ebox source.  Exact
;; compiler output is written to `*Ebox Byte Compile*'.  Restart Emacs after a
;; successful build so the current process loads the new bytecode.  This command
;; does not compile the optional Rust module.
;;
;; Function: ebox-call-with-render-burst (function &rest arguments)
;;;###autoload (autoload 'ebox-call-with-render-burst "ebox" nil nil)
;; Call FUNCTION with ARGUMENTS inside one framework render burst.
;;
;; The burst is always ended when FUNCTION returns, signals an error, or quits.
;; Return FUNCTION's value.
;;
;; Function: ebox-call-with-update-batch (callback &optional buffer)
;;;###autoload (autoload 'ebox-call-with-update-batch "ebox" nil nil)
;; Call CALLBACK in BUFFER, coalescing its region updates into one publication.
;; BUFFER defaults to the current buffer.  CALLBACK receives no arguments and its
;; return value is returned unchanged.  Flush after CALLBACK returns normally;
;; an empty or unchanged batch does not publish or replace the last update report.
;;
;; When BUFFER already has an active batch, join it without flushing.  Errors,
;; quits and other nonlocal exits discard only this call's queued changes and
;; preserve the outer batch.  A failed owned flush discards its unpublished batch;
;; the TP publication boundary preserves the previously committed generation.
;;
;; This scope covers queued `ebox-region-update' calls for BUFFER, not arbitrary
;; side effects in CALLBACK.  Leave explicit begin/flush lifecycle calls outside
;; CALLBACK; the existing explicit API retains its separate retry semantics.
;;
;; Function: ebox-candidate-begin (buffer-or-name)
;;;###autoload (autoload 'ebox-candidate-begin "ebox" nil nil)
;; Begin a one-shot logical transaction from BUFFER-OR-NAME's exact runtime.
;;
;; Function: ebox-candidate-patch-host-paint (candidate host-ref previous-input next-input)
;;;###autoload (autoload 'ebox-candidate-patch-host-paint "ebox" nil nil)
;; Patch HOST-REF paint from canonical PREVIOUS-INPUT/NEXT-INPUT in CANDIDATE.
;; Only node-local paint fields may differ.  The Host's children and runtime
;; identities are retained instead of being copied as a replacement subtree.
;; Return CANDIDATE when accepted, or nil when the delta needs ordinary subtree
;; replacement.
;;
;; Function: ebox-candidate-replace (candidate node-id input &optional old-semantic-key new-semantic-key)
;;;###autoload (autoload 'ebox-candidate-replace "ebox" nil nil)
;; Replace NODE-ID in CANDIDATE with canonical INPUT.
;; OLD-SEMANTIC-KEY and NEW-SEMANTIC-KEY may identify a stable anchor's detached
;; semantic variants so a later return can reuse bounded runtime identity.
;; Return CANDIDATE for convenient transaction construction.
;;
;; Function: ebox-candidate-replace-host-ref (candidate host-ref input &optional old-semantic-key new-semantic-key)
;;;###autoload (autoload 'ebox-candidate-replace-host-ref "ebox" nil nil)
;; Replace HOST-REF in CANDIDATE with canonical INPUT.
;; HOST-REF is resolved against the exact published runtime captured by
;; `ebox-candidate-begin'.  OLD-SEMANTIC-KEY and NEW-SEMANTIC-KEY have the same
;; optional detached-identity meaning as in `ebox-candidate-replace'.
;; Return CANDIDATE.
;;
;; Function: ebox-candidate-replace-range-ref (candidate range-ref input &optional reuse-map retain-item-identities-p)
;;;###autoload (autoload 'ebox-candidate-replace-range-ref "ebox" nil nil)
;; Replace RANGE-REF from canonical INPUT, retaining proven REUSE-MAP slots.
;; Nested Range writes refine the ancestor replacement in either recording
;; order. An ancestor that removes the inner Range absorbs that inner write.
;; When RETAIN-ITEM-IDENTITIES-P is non-nil, Ebox retains candidate-owned items
;; only after its strict ownership proof; otherwise it uses the normal copy path.
;;
;; Function: ebox-candidate-replace-root (candidate input)
;;;###autoload (autoload 'ebox-candidate-replace-root "ebox" nil nil)
;; Replace CANDIDATE's exact implicit root with canonical INPUT.
;; The root address is private, base-bound, and cannot collide with host refs.
;; Repeated calls are last-wins and absorb all descendant candidate operations.
;;
;; Function: ebox-canonical-box-configuration (tag declarations)
;;;###autoload (autoload 'ebox-canonical-box-configuration "ebox" nil nil)
;; Return a detached plist with :layout and :outer for the canonical Box
;; constructor. TAG is box, row, column, flex or grid; DECLARATIONS must be
;; canonical declarations accepted by that tag, otherwise an error is signaled.
;; The LayoutConfig is opaque and immutable. Concrete values are projected now;
;; tagged values use provisional defaults until ECSS computes the node. Keep
;; the complete declarations in its source binding and pass facts derived from
;; them to ebox-box-create. This call performs no rendering or value evaluation.
;;
;; Function: ebox-canonical-facts-from-declarations (tag declarations &optional interactions)
;;;###autoload (autoload 'ebox-canonical-facts-from-declarations "ebox" nil nil)
;; Return immutable node-owned facts for TAG from DECLARATIONS.
;; Source declarations stay behind the source handle; the returned value contains
;; provisional concrete node properties. Tagged values require ECSS computation.
;; INTERACTIONS is a plist of fixed node capabilities, separate from CSS:
;; :help-echo, :pointer, :hover-style, :keymap, :tab-index and :disabled.
;; Tab index is nil or an integer; nonnegative values create navigation stops.
;; Disabled is nil or t; t excludes focus and blocks this node's own or inherited
;; keymap and derives the disabled selector state for queries and cascade.
;; Both inputs are local to the node; explicit child capabilities remain
;; independent. Pass the same interactions to its source-builder binding.
;;
;; Function: ebox-canonical-input-create (nodes source-index &optional range-anchors)
;;;###autoload (autoload 'ebox-canonical-input-create "ebox" nil nil)
;; Return one opaque canonical input for ordered forest NODES.
;; SOURCE-INDEX owns every source fact referenced by NODES.  RANGE-ANCHORS are
;; nonvisual structural addresses transported with the same generation.
;;
;; Function: ebox-canonical-input-equal-p (left right)
;;;###autoload (autoload 'ebox-canonical-input-equal-p "ebox" nil nil)
;; Return non-nil when canonical inputs LEFT and RIGHT are exactly equivalent.
;; The comparison includes the ordered forest, transparent Range anchors, source
;; identity order, and every immutable author fact.  Derived selector/runtime
;; indexes are deliberately excluded because they are projections of these
;; canonical inputs, not additional source authority.
;;
;; Function: ebox-canonical-input-import-roots (input roots builder)
;;;###autoload (autoload 'ebox-canonical-input-import-roots "ebox" nil nil)
;; Import INPUT facts owned by selected top-level ROOTS into BUILDER.
;; Each ROOT must be an exact, unique member of INPUT's forest.  The selected
;; subtrees retain their existing nodes, handles, and immutable records without
;; adopting facts from unselected roots.  Return a shallow copy of ROOTS.
;;
;; Function: ebox-canonical-input-p (x)
;;;###autoload (autoload 'ebox-canonical-input-p "ebox" nil nil)
;;
;;
;; Function: ebox-canonical-input-root-host-ref (input)
;;;###autoload (autoload 'ebox-canonical-input-root-host-ref "ebox" nil nil)
;; Return INPUT's detached single-root publication reference.
;; This framework-integration port keeps `ebox-source-handle' opaque: Ebox first
;; validates that the canonical root's exact handle belongs to INPUT's immutable
;; source generation, then returns only the author-owned publication reference.
;;
;; Function: ebox-canonical-input-roots (input)
;;;###autoload (autoload 'ebox-canonical-input-roots "ebox" nil nil)
;; Return a shallow copy of canonical INPUT's ordered forest roots.
;; This is a read-only structural view; it does not adopt INPUT's source facts
;; into another candidate.
;;
;; Function: ebox-child-range (range-ref &rest items)
;;;###autoload (autoload 'ebox-child-range "ebox" nil nil)
;; Return an owned child Range descriptor for non-nil RANGE-REF and ITEMS.
;; ITEMS are declarative nodes.  Child Range descriptors cannot be nested.
;;
;; Function: ebox-clear-cache ()
;;;###autoload (autoload 'ebox-clear-cache "ebox" nil nil)
;; Clear pixel width caches after font or named face metrics change.
;;
;; Function: ebox-column-layout-create (&rest plist)
;;;###autoload (autoload 'ebox-column-layout-create "ebox" nil nil)
;; Return canonical ColumnConfig from evaluated PLIST.
;;
;; Function: ebox-commit (buffer-or-name next-root &optional framework-publish framework-rollback)
;;;###autoload (autoload 'ebox-commit "ebox" nil nil)
;; Atomically commit declarative NEXT-ROOT into BUFFER-OR-NAME.
;;
;; NEXT-ROOT must be a canonical Ebox input or a one-shot logical candidate from
;; `ebox-candidate-begin'.  A complete root is copied into a buffer-owned
;; runtime.  A logical candidate path-copies replaced ancestor chains, shares
;; untouched subtrees, and isolates retained scroll nodes before proof rendering.
;; Both forms reconcile Ebox-owned identity,
;; prove rendered owners in isolation, and publish only property-aware buffer
;; differences.  Validation, render, and publication failures leave the current
;; buffer and runtime unchanged.
;;
;; When FRAMEWORK-PUBLISH is non-nil, it must be a function of one update report.
;; Ebox invokes it inside the quit-free atomic publication boundary after the
;; buffer and runtime agree.  This hook is for framework pointer promotion only;
;; it must not run application code.  An error rolls the Ebox publication back.
;; FRAMEWORK-ROLLBACK, when supplied, receives the same report if publication or
;; a later transaction phase fails, and is contained if it violates no-throw.
;;
;; Return the successful publication report stored by `ebox-buffer-update-report'.
;;
;; Function: ebox-display-buffer (buffer-or-name input &optional action)
;;;###autoload (autoload 'ebox-display-buffer "ebox" nil nil)
;; Render canonical INPUT to BUFFER-OR-NAME, display it, and return its buffer.
;; Render before requesting a window, so invalid input does not disturb the
;; window layout.  ACTION is passed to `display-buffer'; ordinary display rules
;; apply and this function does not select the displayed window.
;;
;; Function: ebox-display-signature ()
;;;###autoload (autoload 'ebox-display-signature "ebox" nil nil)
;; Return the current display signature used for pixel measurements.
;;
;; Function: ebox-file-evaluate-form (form &optional source-file)
;;;###autoload (autoload 'ebox-file-evaluate-form "ebox" nil nil)
;; Evaluate FORM once, loading SOURCE-FILE companions and local styles.
;; Relative paths use SOURCE-FILE's directory.  The result is inert DSL data;
;; file styles are snapshots consumed by the ordinary local scope pipeline.
;;
;; Function: ebox-file-read-file (file)
;;;###autoload (autoload 'ebox-file-read-file "ebox" nil nil)
;; Read one Ebox expression from FILE without evaluating it.
;;
;; Function: ebox-file-read-form (source)
;;;###autoload (autoload 'ebox-file-read-form "ebox" nil nil)
;; Read exactly one Elisp expression from SOURCE.
;;
;; Function: ebox-flex-layout-create (&rest plist)
;;;###autoload (autoload 'ebox-flex-layout-create "ebox" nil nil)
;; Return a typed FlexConfig from canonical evaluated PLIST.
;; PLIST accepts direction, wrap, alignment, and row/column gap longhands.
;; Author shorthands such as `:flex-flow' and `:gap' are normalized before this
;; programmatic port and are therefore rejected here.
;;
;; Function: ebox-framework-spi-capabilities ()
;;;###autoload (autoload 'ebox-framework-spi-capabilities "ebox" nil nil)
;; Return a fresh immutable Ebox framework SPI v2 provider record.
;;
;; Function: ebox-framework-spi-initial (buffer-or-name input framework-stage framework-rollback)
;;;###autoload (autoload 'ebox-framework-spi-initial "ebox" nil nil)
;; Initially mount INPUT and run the paired framework callbacks.
;;
;; FRAMEWORK-STAGE runs after provisional TP state and Ebox mirrors/native state
;; agree.  FRAMEWORK-ROLLBACK receives the same legacy report on any later
;; transaction failure.  Return that same report object after completion.
;;
;; Function: ebox-framework-spi-initial-observation-reports (report)
;;;###autoload (autoload 'ebox-framework-spi-initial-observation-reports "ebox" nil nil)
;; Return TP/Ebox provider snapshots captured by completed initial REPORT.
;; The reports are defensive observational snapshots; they expose no publication
;; or promotion capability.
;;
;; Function: ebox-framework-spi-operation-argument-schema (operation)
;;;###autoload (autoload 'ebox-framework-spi-operation-argument-schema "ebox" nil nil)
;; Return a defensive copy of OPERATION's argument schema.
;;
;; Function: ebox-framework-spi-operation-function (operation)
;;;###autoload (autoload 'ebox-framework-spi-operation-function "ebox" nil nil)
;; Return OPERATION's immutable function symbol.
;;
;; Function: ebox-framework-spi-operation-kind (operation)
;;;###autoload (autoload 'ebox-framework-spi-operation-kind "ebox" nil nil)
;; Return OPERATION's immutable kind.
;;
;; Function: ebox-framework-spi-operation-p (x)
;;;###autoload (autoload 'ebox-framework-spi-operation-p "ebox" nil nil)
;;
;;
;; Function: ebox-framework-spi-operation-paired-stage-rollback-p (operation)
;;;###autoload (autoload 'ebox-framework-spi-operation-paired-stage-rollback-p "ebox" nil nil)
;; Return non-nil when OPERATION requires paired stage and rollback.
;;
;; Function: ebox-framework-spi-operation-result-schema (operation)
;;;###autoload (autoload 'ebox-framework-spi-operation-result-schema "ebox" nil nil)
;; Return OPERATION's immutable result schema.
;;
;; Function: ebox-framework-spi-provider-capabilities (provider)
;;;###autoload (autoload 'ebox-framework-spi-provider-capabilities "ebox" nil nil)
;; Return a defensive copy of PROVIDER's capabilities.
;;
;; Error: ebox-framework-spi-provider-error
;; Invalid Ebox framework SPI provider
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Function: ebox-framework-spi-provider-initial-operation (provider)
;;;###autoload (autoload 'ebox-framework-spi-provider-initial-operation "ebox" nil nil)
;; Return PROVIDER's immutable initial operation descriptor.
;;
;; Function: ebox-framework-spi-provider-p (x)
;;;###autoload (autoload 'ebox-framework-spi-provider-p "ebox" nil nil)
;;
;;
;; Function: ebox-framework-spi-provider-report-semantics (provider)
;;;###autoload (autoload 'ebox-framework-spi-provider-report-semantics "ebox" nil nil)
;; Return PROVIDER's immutable report semantics.
;;
;; Function: ebox-framework-spi-provider-rollback-order (provider)
;;;###autoload (autoload 'ebox-framework-spi-provider-rollback-order "ebox" nil nil)
;; Return a defensive copy of PROVIDER's participant rollback order.
;;
;; Function: ebox-framework-spi-provider-schema-version (provider)
;;;###autoload (autoload 'ebox-framework-spi-provider-schema-version "ebox" nil nil)
;; Return PROVIDER's immutable schema version.
;;
;; Function: ebox-framework-spi-provider-spi-version (provider)
;;;###autoload (autoload 'ebox-framework-spi-provider-spi-version "ebox" nil nil)
;; Return PROVIDER's immutable SPI version.
;;
;; Function: ebox-framework-spi-provider-stage-order (provider)
;;;###autoload (autoload 'ebox-framework-spi-provider-stage-order "ebox" nil nil)
;; Return a defensive copy of PROVIDER's participant stage order.
;;
;; Function: ebox-framework-spi-provider-tp-protocol (provider)
;;;###autoload (autoload 'ebox-framework-spi-provider-tp-protocol "ebox" nil nil)
;; Return PROVIDER's immutable TP protocol.
;;
;; Function: ebox-framework-spi-provider-update-operation (provider)
;;;###autoload (autoload 'ebox-framework-spi-provider-update-operation "ebox" nil nil)
;; Return PROVIDER's immutable update operation descriptor.
;;
;; Function: ebox-framework-spi-update (buffer-or-name input framework-stage framework-rollback)
;;;###autoload (autoload 'ebox-framework-spi-update "ebox" nil nil)
;; Update BUFFER-OR-NAME from INPUT through paired framework callbacks.
;; Return the same completed legacy report object observed by FRAMEWORK-STAGE.
;;
;; Function: ebox-framework-spi-validate-provider (provider)
;;;###autoload (autoload 'ebox-framework-spi-validate-provider "ebox" nil nil)
;; Validate PROVIDER as one complete Ebox framework SPI v2 record.
;;
;; Function: ebox-get (box property)
;;;###autoload (autoload 'ebox-get "ebox" nil nil)
;; Retrieve PROPERTY from BOX, resolving deferred engine edge lengths.
;;
;; Function: ebox-grid-layout-create (&rest plist)
;;;###autoload (autoload 'ebox-grid-layout-create "ebox" nil nil)
;; Return a typed GridConfig from canonical evaluated PLIST.
;; Author `:gap' sugar is expanded before this programmatic port.  Removed
;; grid-gap aliases are rejected at the author schema boundary.
;;
;; Function: ebox-help-create (function)
;;;###autoload (autoload 'ebox-help-create "ebox" nil nil)
;; Adapt zero-argument FUNCTION to a native `help-echo' callback.
;; The help object's buffer, or the live window buffer for a displayed string,
;; becomes current while FUNCTION runs.  Neither point nor window selection is
;; changed.  FUNCTION runs only when Emacs requests help and must return a string
;; or nil.  Existing native three-argument callbacks need no adapter.
;;
;; Function: ebox-host-ref-bounds (buffer-or-name host-ref)
;;;###autoload (autoload 'ebox-host-ref-bounds "ebox" nil nil)
;; Return live integer bounds for HOST-REF in BUFFER-OR-NAME.
;;
;; The result is a `(START . END)' pair spanning the referenced runtime node's
;; rendered border-box characters (excluding margins), or nil when the buffer,
;; reference, or live TP mounts no longer exist.  HOST-REF is opaque and
;; compared with `equal'.
;;
;; Function: ebox-host-ref-position (buffer-or-name host-ref)
;;;###autoload (autoload 'ebox-host-ref-position "ebox" nil nil)
;; Return HOST-REF's first live position in BUFFER-OR-NAME, or nil.
;; See `ebox-host-ref-bounds' for lookup and lifetime semantics.
;;
;; Function: ebox-incremental-begin-batch (buffer)
;;;###autoload (autoload 'ebox-incremental-begin-batch "ebox" nil nil)
;; Begin an explicit incremental update batch for BUFFER.
;;
;; Function: ebox-incremental-flush (buffer)
;;;###autoload (autoload 'ebox-incremental-flush "ebox" nil nil)
;; Flush BUFFER's explicit incremental batch through Surface observation.
;;
;; Function: ebox-incremental-prepare-scoped-commit (buffer next-root report-overrides &optional isolated-candidate-p)
;;;###autoload (autoload 'ebox-incremental-prepare-scoped-commit "ebox" nil nil)
;; Prepare NEXT-ROOT for object-scoped TP publication in BUFFER.
;; REPORT-OVERRIDES replaces Ebox semantic report fields.  The returned plist
;; contains the isolated candidate root, Ebox node identities, report, and
;; runtime overrides; the surface layer resolves identities to opaque TP objects.
;; When ISOLATED-CANDIDATE-P is non-nil, NEXT-ROOT is an internally copied
;; runtime candidate whose identities already match the published root.
;;
;; Function: ebox-incremental-prepare-viewport-commit (buffer viewport-width viewport-height axes display-signature style-context-stable-p)
;;;###autoload (autoload 'ebox-incremental-prepare-viewport-commit "ebox" nil nil)
;; Prepare BUFFER for VIEWPORT-WIDTH, VIEWPORT-HEIGHT, AXES, and DISPLAY-SIGNATURE.
;;
;; Function: ebox-focus (host-ref &optional buffer-or-name)
;;;###autoload (autoload 'ebox-focus "ebox" nil nil)
;; Focus HOST-REF in BUFFER-OR-NAME, defaulting to the current buffer.
;; Return the current opaque Host reference and move point to its first accessible
;; visible painted character, without selecting a window.  Any enabled visible
;; node may receive explicit focus, including a negative or absent `:tab-index'.
;; Nil HOST-REF clears focus and preserves numeric point, clamped after layout.
;; A changed target publishes :focus queries, computed styles and geometry in
;; the same transaction. The input remains unchanged for pure rendering and
;; other mounts. Styles that make a newly requested target inaccessible signal
;; user-error and preserve the prior focus, text and point.
;; Missing, disabled, hidden or inaccessible targets signal user-error without
;; changing focus or point.
;; If point was manually moved off the focus position, publication preserves
;; its numeric position clamped to the accessible range.
;; Focus follows retained identity through publication.  Removal, hiding and
;; disabling clear it without choosing a replacement; navigation can then restart.
;; Failed publication restores focus.  Unmount and buffer death release it.
;; Changing or clearing focus during an active TP transaction signals error
;; without mutation. Invoke focus after acceptance, including from after-commit
;; callbacks; it cannot join an outer transaction or target provisional state.
;;
;; Function: ebox-focused-host-ref (&optional buffer-or-name)
;;;###autoload (autoload 'ebox-focused-host-ref "ebox" nil nil)
;; Return the logical focus Host reference in BUFFER-OR-NAME, or nil.
;; Default to the current buffer.  Dead or unmounted buffers return nil.
;; Manual point movement does not clear logical focus; it stops publication from
;; following the target until point is moved back to that target's first character.
;;
;; Function: ebox-focus-first (&optional buffer-or-name)
;;;###autoload (autoload 'ebox-focus-first "ebox" nil t)
;; Focus the first eligible navigation stop in BUFFER-OR-NAME and return its ref.
;; Default to the current buffer. Use the tab order and visibility rules of
;; ebox-focus-next, independently of current focus. No stop signals user-error
;; without changing focus or point. No window is selected.
;; Active TP transactions reject focus changes; see ebox-focus.
;;
;; Function: ebox-focus-next (&optional count cycle buffer-or-name)
;;;###autoload (autoload 'ebox-focus-next "ebox" nil t)
;; Move logical focus COUNT stops forward in BUFFER-OR-NAME and return its ref.
;; Defaults are one stop and the current buffer.  Negative COUNT moves backward;
;; zero returns current focus.  CYCLE non-nil wraps at a boundary; otherwise a
;; missing stop signals `user-error' without changing focus or point.
;; Only nodes declaring a nonnegative integer `:tab-index' are navigation stops.
;; Order is ascending tab index, buffer start, then end; exact ties use retained
;; node identity.  Disabled, hidden and inaccessible nodes are skipped.  Navigation
;; starts at the first (or backward last) stop when there is no eligible focus.
;; No window is selected and no key bindings are installed. Nonzero moves
;; during an active TP transaction signal error without mutation. Zero remains
;; a read-only query; see ebox-focus.
;;
;; Function: ebox-focus-previous (&optional count cycle buffer-or-name)
;;;###autoload (autoload 'ebox-focus-previous "ebox" nil t)
;; Move logical focus COUNT stops backward in BUFFER-OR-NAME.
;; COUNT defaults to one; negative COUNT moves forward.  See `ebox-focus-next'
;; for navigation order, CYCLE, visibility and failure semantics.
;;
;; Function: ebox-activate (&optional position noerror)
;;;###autoload (autoload 'ebox-activate "ebox" nil t)
;; Invoke the committed node keymap's RET command at POSITION (default point)
;; in the current buffer. POSITION is an accessible integer or current-buffer
;; marker on visible non-newline text. With nil POSITION, logical focus wins
;; when point remains at that target's first visible character. Resolve its own
;; or inherited map even when a child's map overlaps it. Explicit POSITION
;; always uses the hit position. Inherited keymaps resolve to their owner;
;; explicit nil blocks ancestor activation. Overlay and buffer maps are ignored.
;; Missing surface, target or RET command signals user-error, or returns nil
;; when NOERROR is non-nil. Command errors still propagate. The framework
;; leaves point and window selection unchanged; commands may change them.
;; Commands see RET as last-input-event and their result/errors propagate.
;; No callback is cached between calls: retained updates and unmount take effect
;; immediately. It does not change focus or add event propagation.
;;
;; Function: ebox-call-with-input (host-ref reader &optional buffer-or-name)
;;;###autoload (autoload 'ebox-call-with-input "ebox" nil nil)
;; Run zero-argument native READER for the visible, enabled HOST-REF in the
;; mounted BUFFER-OR-NAME (default current buffer). Return its result only if
;; the same target remains live. Restore its logical focus after success,
;; errors or user quit. Reorder is allowed; replacement, deletion, hiding,
;; disabling, unmount and remount invalidate input. Window selection is unchanged.
;; The reader owns its native editing buffer and input methods; it must not
;; edit Ebox-owned text. Call outside TP transactions. This function applies
;; no application value; normal reader errors and quit propagate.
;;
;; Error: ebox-input-cancelled
;; Native input lost its target before completion; parent condition is quit.
;; Handle as cancelled input without committing the reader's value.
;;
;; Function: ebox-keymap-create (&rest options)
;;;###autoload (autoload 'ebox-keymap-create "ebox" nil nil)
;; Create an ordinary native keymap from OPTIONS.
;; `:activate' is an optional zero-argument callback for RET, return, SPC and
;; the primary mouse button. Mounted primary presses consume motion and release,
;; publish :active while held and clear it before activating once on release
;; over the same retained owner. Releasing elsewhere cancels activation. Point
;; and selection remain unchanged; repeated clicks each activate once. Pure
;; rendered text keeps native release activation without mounted state.
;; Nil omits these activation bindings.  `:bindings' is an alist of string key
;; descriptions or key vectors paired with zero-argument callbacks.  Explicit
;; bindings override the repeated-click, press and drag defaults.
;; Callbacks are not invoked until a generated command runs.  Keyboard commands
;; use the current buffer; mouse commands use the event window's buffer without
;; selecting a window or moving point.  Duplicate or overlapping keys are errors.
;; Generated activation keys use logical focus when point still addresses it,
;; including an overlapping parent. Mouse commands use the clicked binding.
;; Explicit custom bindings and raw native maps retain their native behavior.
;; This helper does not install navigation bindings or event propagation.
;; `:drag' supplies a one-argument callback for a GUI primary-button gesture.
;; It owns press/motion/release; with both options, :activate is keyboard-only.
;; The callback receives a plist: :phase is start, move, end or cancel;
;; :start and :position are (X . Y) pixels in the original window's text area,
;; :delta is displacement from the press, :event preserves the native event,
;; and :window, :buffer and the current :host-ref identify the retained target.
;; Each callback completes and redisplay runs before the next input;
;; end includes the release endpoint. The target has derived :active state
;; during tracking. State and styles publish together, survive retained updates,
;; and clear when tracking ends or its target becomes unavailable. A requested
;; :active style must leave the target visible and enabled; otherwise press fails
;; without changing the surface. Keyboard activation has no held-pointer state.
;; The selected callback owns the gesture through keyed reorders. Cancel has
;; :reason input, quit, error, window-left or target-unavailable. Leaving the
;; original text window, hiding/disabling/removing the target, unmount or window
;; loss ends tracking. Unrelated input is returned to Emacs. End/cancel releases
;; tracking and does not undo already accepted application changes. No second
;; gesture may start during a callback. Cross-window/frame and terminal dragging
;; are not certified. Explicit primary-button bindings override these defaults.
;;
;; Function: ebox-layout-config-for-form (tag properties)
;;;###autoload (autoload 'ebox-layout-config-for-form "ebox" nil nil)
;; Return TAG's typed LayoutConfig from evaluated layout PROPERTIES.
;;
;; Function: ebox-layout-config-property-names (tag)
;;;###autoload (autoload 'ebox-layout-config-property-names "ebox" nil nil)
;; Return canonical property names owned by TAG's LayoutConfig.
;;
;; Error: ebox-layout-context-error
;; Ebox layout context is unavailable
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Variable: ebox-native-buffer-scroll
;; When non-nil, use native-window scrolling for eligible root owners.
;; The native path is admitted only for an interactive buffer with one complete,
;; chrome-free root scroll owner and no nested scroll owner.  Its one-time idle
;; materialization is scheduled for initial display or an explicit visible-window
;; handoff; ordinary incremental updates and resizes use the retained scroll
;; patch and never start a second native publication.  Nested or lazy surfaces
;; keep the transactional retained-window path.
;;
;; Function: ebox-native-build (&optional clean)
;;;###autoload (autoload 'ebox-native-build "ebox" nil t)
;; Build and install Ebox's optional native module asynchronously.
;; With prefix argument CLEAN, clear only Ebox's private Cargo build cache first.
;;
;; Function: ebox-native-reflow-layout-ready-p ()
;;;###autoload (autoload 'ebox-native-reflow-layout-ready-p "ebox" nil nil)
;; Return non-nil when the loaded module implements native layout.
;;
;; Variable: ebox-native-reflow-module-path
;; File or directory where Ebox loads its optional native module.
;; The default is an ABI- and platform-specific directory below
;; `user-emacs-directory'.  A directory value contains the platform module
;; filename; a file value names the module directly.  Ebox never builds the
;; module while loading the package.
;;
;; Function: ebox-native-reflow-runtime-report ()
;;;###autoload (autoload 'ebox-native-reflow-runtime-report "ebox" nil nil)
;; Return exact evidence for the native module active in this Emacs.
;;
;; Function: ebox-native-status ()
;;;###autoload (autoload 'ebox-native-status "ebox" nil t)
;; Display Ebox native toolchain, installation, and runtime status.
;;
;; Function: ebox-next-interaction (&optional count)
;;;###autoload (autoload 'ebox-next-interaction "ebox" nil t)
;; Move point to the next rendered Ebox keymap owner; return its position.
;; With COUNT, move that many stops; a negative count moves backward, zero stays.
;; Each declaring node is one stop, at its first accessible rendered character,
;; even across multiple lines or inherited child content.  Explicit child maps
;; are separate stops; nil and maps without commands are skipped.  From within
;; an owner, skip that owner and seek the next stop after point.
;; Respect narrowing and invisible text.  Use the current committed surface, so
;; updates, removal and scrolling need no navigation refresh.  At a boundary,
;; signal `user-error' without moving; do not wrap or bind keys automatically.
;; Ordinary buffer, overlay and global keymaps do not create stops.  Menu enable
;; forms and filters are not evaluated; a declared command remains a stop even
;; when an application dynamically disables its menu item.
;;
;; Function: ebox-node-kind (node)
;;;###autoload (autoload 'ebox-node-kind "ebox" nil nil)
;; Return canonical NODE kind, or nil for a legacy runtime node.
;;
;; Function: ebox-node-source-handle (node)
;;;###autoload (autoload 'ebox-node-source-handle "ebox" nil nil)
;; Return canonical NODE's opaque source handle.
;;
;; Function: ebox-normal-layout-create ()
;;;###autoload (autoload 'ebox-normal-layout-create "ebox" nil nil)
;; Return the canonical Normal layout config.
;;
;; Error: ebox-patch-plan-error
;; Invalid Ebox patch plan input
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Function: ebox-previous-interaction (&optional count)
;;;###autoload (autoload 'ebox-previous-interaction "ebox" nil t)
;; Move point to the previous rendered Ebox keymap owner; return its position.
;; COUNT defaults to one.  Negative COUNT moves forward.  See
;; `ebox-next-interaction' for ownership, narrowing and boundary behavior.
;;
;; Function: ebox-put (box property value)
;;;###autoload (autoload 'ebox-put "ebox" nil nil)
;; Set private runtime PROPERTY to VALUE in BOX and return BOX.
;; Author declarations are immutable source-index facts and cannot be mutated
;; through this low-level plist helper.
;;
;; Function: ebox-range-ref-present-p (buffer-or-name range-ref)
;;;###autoload (autoload 'ebox-range-ref-present-p "ebox" nil nil)
;; Return non-nil when RANGE-REF is a live mounted address in BUFFER-OR-NAME.
;;
;; This is a read-only boundary query for framework integrations.  It does not
;; create a candidate or expose Ebox's runtime tables; a caller should fall back
;; to its wider owner when a semantic Range has no corresponding published
;; address.
;;
;; Function: ebox-region-ids (node)
;;;###autoload (autoload 'ebox-region-ids "ebox" nil nil)
;; Return NODE's region ids in document order.
;; NODE may be a canonical Ebox input, an internal layout tree, or a rendered
;; string.  Canonical inputs must contain exactly one root.
;; For layout trees, missing ids are assigned to box plists and remain stable
;; for later renders and dynamic updates.
;;
;; Function: ebox-region-resolve (buffer-or-name logical-id)
;;;###autoload (autoload 'ebox-region-resolve "ebox" nil nil)
;; Resolve LOGICAL-ID in BUFFER-OR-NAME to an opaque editable region handle.
;; A retained node keeps its handle across sibling insertion and reordering.
;; Removal, replacement of its logical identity or unmounting invalidates it.
;;
;; Variable: ebox-region-types
;; Mapping from Ebox region roles to rendered text properties.
;;
;; Function: ebox-region-update (handle &rest props)
;;;###autoload (autoload 'ebox-region-update "ebox" nil nil)
;; Update the node identified by HANDLE with PROPS.
;; HANDLE is an opaque handle from `ebox-region-resolve' or an Ebox selector,
;; or a semantic ID (string, non-nil symbol or integer) in the current buffer.
;; PROPS accepts mutable content, style, interaction and scroll keywords plus
;; ECSS custom property symbols named --NAME;
;; `:content' replaces a Text node's string or a Box's sole direct Text child.
;; It does not add children or mutate selector metadata.  The update builds an
;; isolated candidate, runs the Ebox owner planner, and publishes once through the
;; mounted TP surface.  Return nil while queued in an explicit batch; otherwise
;; return the committed update report.
;;
;; Examples:
;;   (ebox-region-update "status" :content "Ready")
;;   (ebox-region-update (ebox-region-resolve buffer "status")
;;                       :content "Ready")
;;   (ebox-region-update handle :padding ='((lh 1) (ch 2))
;;                       :border-color "red")
;;
;; Function: ebox-render (input)
;;;###autoload (autoload 'ebox-render "ebox" nil nil)
;; Render canonical INPUT to a multi-line string through TP.
;; INPUT atomically carries one typed Text/Box root and its source generation.
;; The materialized surface is ephemeral and creates no live buffer state.
;;
;; Function: ebox-render-burst-begin ()
;;;###autoload (autoload 'ebox-render-burst-begin "ebox" nil nil)
;; Begin a framework render burst and return an opaque ownership token.
;;
;; Frameworks may enter this boundary at the start of an input callback so
;; allocation performed before `ebox-commit' shares the same GC budget as Ebox
;; rendering and publication.  Interactive callers reuse Ebox's settling burst:
;; the outermost matching end restores settings after 0.2 seconds.  Batch callers
;; restore the exact settings captured by this call immediately, without running
;; GC at the boundary.
;;
;; Pass the returned token to `ebox-render-burst-end'.  Bursts may be nested, but
;; must be ended in last-in, first-out order.  Prefer
;; `ebox-call-with-render-burst' when the complete operation is available as a
;; function, because it guarantees cleanup across errors and quits.
;;
;; Function: ebox-render-burst-end (token)
;;;###autoload (autoload 'ebox-render-burst-end "ebox" nil nil)
;; End the render burst owned by opaque TOKEN.
;;
;; TOKEN must be the most recently returned active token from
;; `ebox-render-burst-begin'.  Invalid, repeated, or out-of-order ends signal an
;; error without changing GC ownership.  Return nil after a successful end.
;;
;; Variable: ebox-render-gc-cons-percentage
;; Temporary `gc-cons-percentage' used during Ebox render transactions.
;; Set this to nil to leave `gc-cons-percentage' unchanged.
;;
;; Variable: ebox-render-gc-cons-threshold
;; Temporary `gc-cons-threshold' used during Ebox render transactions.
;; Set this to nil to leave `gc-cons-threshold' unchanged.
;;
;; Function: ebox-render-to-buffer (buffer-or-name input &optional options)
;;;###autoload (autoload 'ebox-render-to-buffer "ebox" nil nil)
;; Render canonical INPUT into BUFFER-OR-NAME and return the buffer.
;; INPUT atomically carries one typed Text/Box root and its source generation.
;; OPTIONS accepts only `:observer'.  Its function receives the buffer and flat
;; TP/Ebox reports after accepted initial publication and later commits.
;;
;; Function: ebox-rerender-buffer-with-context (buffer viewport-width &optional viewport-height)
;;;###autoload (autoload 'ebox-rerender-buffer-with-context "ebox" nil nil)
;; Rerender BUFFER's stored runtime tree using VIEWPORT-WIDTH.
;; VIEWPORT-WIDTH is pixels; optional VIEWPORT-HEIGHT is frame lines.
;; Viewport units and composed size expressions resolve against this context.
;; This preserves node and region identity and routes viewport-dependent changes
;; through dirty-set and patch-set execution before falling back to root rerender.
;;
;; Function: ebox-row-layout-create (&rest plist)
;;;###autoload (autoload 'ebox-row-layout-create "ebox" nil nil)
;; Return canonical RowConfig from evaluated PLIST.
;;
;; Variable: ebox-runtime-idle-prewarm
;; When non-nil, prepare shared incremental-update state while Emacs is idle.
;; Prewarming is buffer-runtime scoped and never materializes complete lazy scroll
;; content.  It prepares indexes only for scroll lines that are already cached.
;;
;; Variable: ebox-runtime-idle-reflow-cache-prewarm
;; When non-nil, predict and cache the next steady viewport reflow.
;; Each completed nonzero viewport-width delta predicts one following width.  The
;; predicted render runs after an input-free idle interval and publishes no
;; buffer or runtime state; it populates the same persistent render cache used by
;; viewport and ordinary root-width owner rerenders.  Nonpositive predictions
;; are skipped.
;;
;; Function: ebox-runtime-index-get (key index &optional missing)
;;;###autoload (autoload 'ebox-runtime-index-get "ebox" nil nil)
;; Return KEY's value from INDEX, or MISSING.
;; INDEX may be an immutable runtime index or a legacy hash table.
;;
;; Function: ebox-scroll-down (&optional n)
;;;###autoload (autoload 'ebox-scroll-down "ebox" nil t)
;; Scroll box content down by N lines.
;; When called from Lisp with nil N, use `ebox-scroll-step'.
;;
;; Variable: ebox-scroll-lazy-idle-prefetch-lines
;; Extra lazy scroll lines rendered while Emacs is idle.
;; This warms the same scroll content cache used by wheel/key scrolling, so deep
;; scrolling can replace already-rendered line strings instead of producing
;; hidden rows inside a wheel tick.  Set to 0 to disable idle prefetch.
;;
;; Variable: ebox-buffer-mode-map
;; Shared mounted-buffer bindings for scrolling, cyclic TAB/backtab focus,
;; RET/return activation and quitting. Customize this map after requiring Ebox.
;; Native node keymaps remain effective; their generated activation commands
;; use logical focus when point is still at its first visible character.
;;
;; Function: ebox-scroll-page-down (&optional arg)
;;;###autoload (autoload 'ebox-scroll-page-down "ebox" nil t)
;; Scroll ebox content down by a page.
;; With prefix ARG, scroll by that many content lines.
;;
;; Function: ebox-scroll-page-up (&optional arg)
;;;###autoload (autoload 'ebox-scroll-page-up "ebox" nil t)
;; Scroll ebox content up by a page.
;; With prefix ARG, scroll by that many content lines.
;;
;; Function: ebox-scroll-state (region-id)
;;;###autoload (autoload 'ebox-scroll-state "ebox" nil nil)
;; Return the scroll state plist for REGION-ID, or nil.
;; The plist is read-only API for consumers that need to map visible scroll
;; content back to their own source model.
;;
;; Function: ebox-scroll-up (&optional n)
;;;###autoload (autoload 'ebox-scroll-up "ebox" nil t)
;; Scroll box content up by N lines.
;; When called from Lisp with nil N, use `ebox-scroll-step'.
;;
;; Function: ebox-select-all (buffer selector)
;;;###autoload (autoload 'ebox-select-all "ebox" nil nil)
;; Return document-ordered selector match handles from BUFFER runtime state.
;; Selector lookup reads the stored runtime root, not rendered buffer text
;; properties.  Each returned handle includes `:buffer' in addition to the
;; tree-query handle fields.
;;
;; Function: ebox-selector-match-node-p (node selector)
;;;###autoload (autoload 'ebox-selector-match-node-p "ebox" nil nil)
;; Return non-nil when NODE matches structured ECSS SELECTOR.
;;
;; Function: ebox-selector-parse (selector)
;;;###autoload (autoload 'ebox-selector-parse "ebox" nil nil)
;; Compile CSS-like SELECTOR through the ECSS parser.
;;
;; Function: ebox-selector-query-all (root selector)
;;;###autoload (autoload 'ebox-selector-query-all "ebox" nil nil)
;; Return document-ordered selector match handles under ROOT.
;;
;; Function: ebox-selector-query-buffer (buffer selector)
;;;###autoload (autoload 'ebox-selector-query-buffer "ebox" nil nil)
;; Return document-ordered selector match handles from BUFFER runtime state.
;; Selector lookup reads the stored runtime root, not rendered buffer text
;; properties.  Each returned handle includes `:buffer' in addition to the
;; tree-query handle fields.
;;
;; Function: ebox-selector-update-buffer (buffer selector &rest props)
;;;###autoload (autoload 'ebox-selector-update-buffer "ebox" nil nil)
;; Apply PROPS to editable selector matches in BUFFER.
;; SELECTOR locates runtime nodes, then every editable match is updated through
;; `ebox-region-update'.  Return a summary plist with match counts, structured
;; skips, and update reports.
;;
;; Error: ebox-size-error
;; Invalid Ebox size
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Function: ebox-source-builder-bind (builder &key identity key id class selector-attributes selector-state declarations provenance interactions ecss (ecss-targets t) ecss-scopes ecss-scope-roots)
;;;###autoload (autoload 'ebox-source-builder-bind "ebox" nil nil)
;; Bind normalized source facts in BUILDER and return an opaque handle.
;; The returned handle contains identity only; all facts are owned by BUILDER
;; until `ebox-source-builder-finish' seals them into a source index.
;; Retained sibling matching uses author KEY first, then matching IDENTITY for
;; unkeyed nodes, before positional fallback. A sibling retaining its identity
;; cannot donate that runtime node to a newly inserted sibling.
;; SELECTOR-STATE contains authored tokens. Disabled, focus and active are reserved:
;; use :disabled t in INTERACTIONS, mounted ebox-focus operations and generated
;; primary-button gestures respectively. Authoring these tokens signals an error.
;; Interaction-derived states participate in queries and cascade in each candidate.
;; ECSS-TARGETS is t (default) for all descendants or a proper list of source
;; identities eligible for this source's ECSS rules.  nil selects none.  The
;; identities use equal and are snapshotted.  Non-list input signals
;; wrong-type-argument.  Rendering resolves targets in the candidate input;
;; an absent identity is an error.  Targets outside the source's subtree do
;; not match.  Structural selectors and inheritance retain the canonical tree.
;; ECSS-SCOPES and ECSS-SCOPE-ROOTS are snapshotted proper lists of scope
;; descriptions with distinct identities, declaring this source's membership and
;; mounting roots respectively. Invalid lists are errors. A root need not be
;; a member. Shared scopes follow local :ecss scopes in cascade source order;
;; shared scopes follow the first root's document and declaration-list order.
;;
;; Function: ebox-source-builder-create ()
;;;###autoload (autoload 'ebox-source-builder-create "ebox" nil nil)
;; Return a mutable source builder for one canonical input.
;;
;; Function: ebox-source-builder-finish (builder)
;;;###autoload (autoload 'ebox-source-builder-finish "ebox" nil nil)
;; Seal BUILDER and return its fact-only immutable source index.
;;
;; Function: ebox-source-builder-p (x)
;;;###autoload (autoload 'ebox-source-builder-p "ebox" nil nil)
;;
;;
;; Error: ebox-state-contract-error
;; Invalid Ebox retained-state contract
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Function: ebox-string-lines (string)
;;;###autoload (autoload 'ebox-string-lines "ebox" nil nil)
;; Split STRING into lines, preserving properties; empty input has no lines.
;;
;; Function: ebox-string-pixel-width (string)
;;;###autoload (autoload 'ebox-string-pixel-width "ebox" nil nil)
;; Return the display pixel width of STRING's first line.
;; This is the public, text-scale-aware measurement used by Ebox layout code.
;;
;; Function: ebox-style-canonical-name (name)
;;;###autoload (autoload 'ebox-style-canonical-name "ebox" nil nil)
;; Return canonical CSS-like longhand property name for NAME.
;;
;; Function: ebox-style-compile-declarations (plist &optional strict)
;;;###autoload (autoload 'ebox-style-compile-declarations "ebox" nil nil)
;; Compile Ebox PLIST aliases to ECSS schema declarations.
;; When STRICT is non-nil, reject properties outside the Ebox style domain.
;;
;; Function: ebox-style-scope-create (rules &key (origin 'author))
;;;###autoload (autoload 'ebox-style-scope-create "ebox" nil nil)
;; Snapshot ordered rule data as an immutable shared scope. RULES use the same
;; syntax and schema as ebox-style-compile-rules; ORIGIN follows ECSS origins.
;; Invalid input signals an error without changing other scopes. Scope objects
;; are opaque, have no mutators or runtime resources, and may be shared safely
;; by independent canonical inputs. Source :ecss-scopes lists declare membership;
;; :ecss-scope-roots lists mark independent mounting roots. Each root limits
;; rules to members within its subtree; root matching requires membership too.
;; &/:scope address each marked root; ordinary selectors address descendants.
;; Without a root in the input, the scope contributes no rules. Tree relations
;; and inheritance remain unchanged. See the manual for composition examples.
;;
;; Function: ebox-style-scope-with-rules (scope rules &key (origin 'author))
;;;###autoload (autoload 'ebox-style-scope-with-rules "ebox" nil nil)
;; Return an immutable rule revision retaining SCOPE's membership identity.
;; Rules and origin follow ebox-style-scope-create; invalid input signals an
;; error without mutation. Rebind roots to this revision while retained members
;; keep any revision of the same identity. Each root applies its own snapshot;
;; older canonical inputs remain unchanged. Membership/root lists must contain
;; distinct identities, so two revisions cannot occur in the same list.
;; ORIGIN defaults to author, including when SCOPE used another origin.
;;
;; Function: ebox-style-compile-rules (rules)
;;;###autoload (autoload 'ebox-style-compile-rules "ebox" nil nil)
;; Compile ordered (SELECTOR PROPERTY VALUE ...) RULES through ECSS syntax
;; and strict Ebox property schemas. Return detached selector-AST/declaration
;; pairs for the :ecss field of `ebox-source-builder-bind`. This neither mutates
;; input/stylesheet state nor evaluates values; invalid rules signal an error.
;;
;; Function: ebox-style-compile-form (tag plist)
;;;###autoload (autoload 'ebox-style-compile-form "ebox" nil nil)
;; Compile evaluated author PLIST once and validate it for TAG.
;;
;; Function: ebox-style-declaration-properties (declarations predicate)
;;;###autoload (autoload 'ebox-style-declaration-properties "ebox" nil nil)
;; Return canonical author properties in DECLARATIONS matching PREDICATE.
;;
;; Function: ebox-style-property-accepted-p (tag name)
;;;###autoload (autoload 'ebox-style-property-accepted-p "ebox" nil nil)
;; Return non-nil when author form TAG accepts property NAME.
;;
;; Error: ebox-style-schema-error
;; Invalid Ebox style schema
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Function: ebox-style-schema-id (name)
;;;###autoload (autoload 'ebox-style-schema-id "ebox" nil nil)
;; Return namespaced ECSS schema id for Ebox property NAME.
;;
;; Function: ebox-surface-buffer-mounted-p (buffer)
;;;###autoload (autoload 'ebox-surface-buffer-mounted-p "ebox" nil nil)
;; Return non-nil when BUFFER has a live Ebox TP surface.
;;
;; Function: ebox-surface-buffer-revision (buffer)
;;;###autoload (autoload 'ebox-surface-buffer-revision "ebox" nil nil)
;; Return BUFFER's committed TP surface revision or fail when unmounted.
;;
;; Function: ebox-surface-buffer-snapshot (buffer)
;;;###autoload (autoload 'ebox-surface-buffer-snapshot "ebox" nil nil)
;; Export BUFFER's current committed canonical input on explicit request.
;; Return a plist with :input, :revision and :mount-id.  The integer mount ID
;; distinguishes remounts whose revisions may coincide.  Query is rejected while
;; a TP transaction is active or BUFFER has no live Ebox surface.
;;
;; This explicit operation copies node structure and mutable input data, retaining
;; exact immutable source facts and opaque capabilities such as callbacks and
;; keymaps.  It neither renders nor publishes, and never advances the revision.
;; Cost is linear in exported data plus TP's latest retained diagnostic report.
;; The returned input survives later commits and unmounting; it can be rendered
;; independently.  It does not freeze external capabilities or the display
;; environment, and old Host references gain no authority over another mount.
;;
;; Error: ebox-surface-capability-error
;; Ebox surface capability violation
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Error: ebox-surface-tp-protocol-error
;; Ebox requires TP 2.0.0 or newer with structured transactions
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Function: ebox-surface-update-buffer-viewport (buffer width &optional height)
;;;###autoload (autoload 'ebox-surface-update-buffer-viewport "ebox" nil nil)
;; Publish BUFFER for viewport WIDTH and optional HEIGHT through TP.
;;
;; Function: ebox-text-create (&rest plist)
;;;###autoload (autoload 'ebox-text-create "ebox" nil nil)
;; Create a canonical TextNode from evaluated PLIST.
;;
;; `:value' is required and must be one string.  `:source-handle' is required and
;; is the only author source input.  Direct properties are limited to already
;; computed Text measurement facts.
;;
;; Function: ebox-text-node-p (node)
;;;###autoload (autoload 'ebox-text-node-p "ebox" nil nil)
;; Return non-nil when NODE is a canonical TextNode.
;;
;; Function: ebox-text-node-value (node)
;;;###autoload (autoload 'ebox-text-node-value "ebox" nil nil)
;; Return canonical TextNode NODE's string payload.
;;
;; Function: ebox-tree-for-each-direct-child (node function)
;;;###autoload (autoload 'ebox-tree-for-each-direct-child "ebox" nil nil)
;; Call FUNCTION for each direct child of NODE without materializing Ranges.
;;
;; Function: ebox-tree-source-builder-snapshot (builder roots)
;;;###autoload (autoload 'ebox-tree-source-builder-snapshot "ebox" nil nil)
;; Return a sealed source-index slice for canonical ROOTS in open BUILDER.
;;
;; Function: ebox-unmount-buffer (buffer-or-name)
;;;###autoload (autoload 'ebox-unmount-buffer "ebox" nil nil)
;; Unmount Ebox's retained surface from BUFFER-OR-NAME and return the buffer.
;; The operation releases TP surface authority, observers, retained indexes,
;; scroll/native runtime state, and the buffer-local Ebox surface handle.
;;
;; Function: ebox-update-selector (buffer selector &rest props)
;;;###autoload (autoload 'ebox-update-selector "ebox" nil nil)
;; Apply PROPS to editable selector matches in BUFFER.
;; SELECTOR locates runtime nodes, then every editable match is updated through
;; `ebox-region-update'.  Return a summary plist with match counts, structured
;; skips, and update reports.
;;
;; Variable: ebox-viewport-height
;; Dynamically bound vertical viewport height in lines.
;; The render context converts this value to pixels with the frame line metric.
;; Block-axis DSL sizes use `(vh N)' for N percent of that pixel height.
;;
;; Variable: ebox-viewport-width
;; Dynamically bound horizontal viewport width in pixels.
;; DSL sizes may use `(vw N)' for N percent of this width while a
;; caller, such as the Playground preview, renders against a concrete window.
;;
;; Function: ebox-viewport-window-width (window)
;;;###autoload (autoload 'ebox-viewport-window-width "ebox" nil nil)
;; Return Ebox's display-safe viewport width for live WINDOW.
;;
;; Function: ebox-wheel-scroll-down (event &optional arg)
;;;###autoload (autoload 'ebox-wheel-scroll-down "ebox" nil t)
;; Handle mouse wheel down EVENT in an ebox buffer.
;; Scrollable ebox content under the mouse consumes the event; otherwise delegate
;; to Emacs' normal `mwheel-scroll' so preview buffers keep native wheel speed.
;;
;; Function: ebox-wheel-scroll-up (event &optional arg)
;;;###autoload (autoload 'ebox-wheel-scroll-up "ebox" nil t)
;; Handle mouse wheel up EVENT in an ebox buffer.
;; Scrollable ebox content under the mouse consumes the event; otherwise delegate
;; to Emacs' normal `mwheel-scroll' so preview buffers keep native wheel speed.
;;

;; Function: ebox-dsl-mode ()
;;;###autoload (autoload 'ebox-dsl-mode "ebox" nil t)
;; Enable syntax-aware editing for .ebox files in the current buffer.
;; Use C-c C-c to preview the current .ebox buffer with `ebox-file-preview`.
;;
;; Variable: ebox-dsl-mode-map
;; Keymap for Ebox DSL editing. Use define-key to customize editing bindings.
;;
;; Function: ebox-file-preview (&optional buffer)
;;;###autoload (autoload 'ebox-file-preview "ebox" nil t)
;; Evaluate BUFFER (default: current buffer) as a .ebox document and render it in
;; a dedicated preview buffer. Interactive use: M-x ebox-file-preview, or C-c C-c
;; in ebox-dsl-mode. Evaluation errors are reported without publishing a new view.
;;
;;; Code:

;;;###autoload
(eval-and-compile
  (add-to-list 'load-path
               (expand-file-name "lisp"
                                 (file-name-directory
                                  (or load-file-name
                                      (bound-and-true-p byte-compile-current-file)
                                      buffer-file-name)))))

(require 'ebox-runtime)
(require 'ebox-native-reflow)

(provide 'ebox)
;;; ebox.el ends here
