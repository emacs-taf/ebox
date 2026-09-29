# Changelog

All notable changes to Ebox are documented here.

## 3.0.0 (Unreleased)

### Added

- Replacing children inside one eligible absolute panel reuses the other
  panels and completed root flow while recomposing their overlap. Root portals
  without anchor dependencies use the same path; ordinary ownership and atomic
  publication continue to handle new and removed controls.
- Layer composition uses the optional native module for occlusion and
  visible source intervals, with bounded reusable storage and the same Unicode,
  text-property and rollback behavior in ordinary and prepared updates. Fixed
  display-space boundaries avoid repeated prefix measurement while joining damaged rows. Rebuild the optional
  module for ABI `22:10:13` and restart Emacs; Elisp remains the fallback.
- `ebox-geometry-prepare` and `ebox-update-prepare` compile `:width` and
  `:height` for a normal-layout absolute Box that contains only fixed Text:
  opaque string background, `overflow hidden`, `wrap-mode none`, left/top
  alignment, explicit `(px 0)`/`(lh 0)` minimums and no maximum, padding,
  margins, borders or scrolling. Preparation paints one maximum raster bounded
  by the containing plane; applying a size only changes the visible row and
  column extent, restoring formerly clipped text on expansion, and shares the
  translation program's rollback. Other size changes keep their existing
  boundary re-render or ordinary publication route, and unsupported values are
  declined before mutation. See the `ebox-geometry-apply` record in `ebox.el`.
- Prepared `:width`/`:height` changes of a framed absolute panel, such as a
  desktop window with a centered title and a body, replay the panel's learned
  size response instead of re-rendering it. The response is learned from the
  first ordinary renders, verified at the plane's limits, and checked against
  the retained rows before every replay; any paint, content or font change
  falls back to the ordinary render. Batch desktop window resizing drops from
  about 36 ms to 14 ms per frame horizontally and from 20 ms to 9 ms vertically.

### Fixed

- Prepared geometry reserves sparse border and interaction roles from their own
  raster intervals with a small fixed allowance, reducing cold mount allocation.
  Exhausted pools grow geometrically within the retained bound.
  Shared prepared targets remain usable after a pool expansion is rejected and
  rolled back.
- Metadata-only focus and pressed updates retain the current layer composition
  baseline. Panel replacements requiring complete stylesheet computation verify
  their full computed effects before reusing other layers.
- Prepared moves and resizes keep the mounted geometry synchronized after a
  colour or focus repaint recomputes styles. Repeated updates no longer reuse
  stale coordinates and accumulate displacement; rejected updates restore both
  source values and the previous runtime projection.

- Host bounds and positions exclude leading/trailing structural newlines.
  A Row control following another flow child now resolves to its painted
  character and native keymap instead of the preceding line separator.
- Positioned layers reject ordinary Text/Box descendants whose resolved
  canonical font exceeds their containing plane's row height. Previously only
  positioned nodes were checked, allowing a larger descendant font to stretch
  neighboring panes. Smaller fonts and same-height bold remain supported.
- Prepared class updates can be rebound after scrolling copies runtime nodes.
  Selector bindings follow stable source handles, retain unique query results
  and keep class, geometry and scroll rollback consistent.
- Retained children with their own text color now inherit changes to a parent's
  font size, weight and style. Failed publications preserve the prior inherited
  typography and allow a subsequent update to retry.

- Structural updates retain unchanged computed-style bindings instead of
  treating every explicitly coloured child as a parent-colour transition.
  Actual inherited colour and typography changes still follow the cascade.

- Resizing a positioned panel whose declared height is clamped by min/max
  constraints or expanded by content-box decoration no longer indexes missing
  elastic rows. Such samples keep their ordinary render until declared and
  materialized heights agree, preserving size updates and rollback.
- Prepared movement can be rebuilt after ordinary Text updates expand a
  positioned pane into more rows. Growing its retained mount pool now preserves
  the accepted publication generation and its rollback baseline instead of
  rejecting the new frame with a missing-mount error.
- Publication rejection diagnostics no longer expose live surface, mount or
  callback graphs. Ordinary Emacs error reporting can print these failures
  without expanding cyclic data; the error type and rollback remain unchanged.
- Retained Host property and selector updates preserve position, stacking,
  anchoring and container layout effects during incremental classification.
  These changes now schedule geometry work instead of being treated as
  display-neutral metadata, preserving visible output and interaction targets.
- Scroll viewports inside positioned panes no longer disable prepared updates
  for the entire surface. Movement preserves their offsets and input identity;
  pane paint and size changes publish scroll metadata with the visible result,
  including rollback and later scrolling. Scrolling containing planes still
  require ordinary publication.
- A prepared absolute panel resize no longer signals `wrong-type-argument`
  when its rows changed between size changes: the learned size response is
  inherited only while it still describes the current rows, and a row whose
  row number cannot be moved makes the replay fall back to an ordinary render.
- `ebox-update-prepare` binds a `:color`/`:background-color` cell whose value
  is a paint slot by the slot's stable face. Previously, after
  `ebox-paint-slot-apply-updates` changed the slot's specification, the
  mounted engine copy no longer compared `equal` to the source declaration and
  preparation was declined with `source-binding`.
- A property update that changes an inherited property (such as `:color`) on
  a parent now composes with same-candidate Range replacements whose items own
  styled Box children. Ebox used to reset the parent's pending style count to
  one and copy the newly replaced items, which signalled a negative style count
  or an unknown region at commit; candidate-owned items are now updated in
  place and counts follow their final children.
- Native drags merge bounded bursts of pending motion and publish their latest
  position without crossing release, cancellation or unrelated input. Locked
  gestures no longer publish movement after the ending press, and targets lost
  while a native read runs timers cancel before another callback is delivered.

- Modifier-prefixed primary clicks stay on the interactive node's own keymap.
  A lock-modifier drag (shift, control, meta, super or hyper with a click)
  starts the controlled Ebox gesture instead of leaving the press to a global
  command such as Emacs's shift-click region extension.

- A rejected prepared paint or class update restores every restyled node's
  exact plist. Previously the rollback wrote values by position while the
  restyle had moved Flex/Grid item properties to the end of the plist, which
  corrupted `:children` and made the next structural commit signal
  `wrong-type-argument`. Restyles now also keep item properties in place.

### Changed

- Prepared geometry wrappers look up their compiled property transformations
  through a hash that reads every element of a signature. `sxhash-equal`
  hashes only a vector's leading elements, and a signature's leading values
  are mostly nil, so tables with hundreds of entries collapsed into about
  sixty buckets and each dirty row scanned nested property values. A
  four-window Desktop workspace switch drops from about 97 to 35 ms in batch
  and from 87 to 47 ms in the GUI; window drags and resizes save 5–10 ms.

- Preparing a geometry wrapper no longer enumerates every source property
  combination up front. Preparation records the property schema (program
  primitives, the enclosed route, surface properties and paint decorations)
  and compiles one combination when a dirty row first presents it; a row
  whose source or painted properties fall outside that schema still declines
  the prepared operation. Preparing the Desktop window cohort drops from
  about 272 to 137 ms in batch, so the first drag after a structural change
  stalls less and idle preparation completes between mouse moves. Initially
  clipped or exactly full fixed Text slots now accept variable content
  through the prepared route; only an initially empty slot still declines.

- Compiling prepared ownership (`ebox-surface--geometry-mount-prepare`)
  gathers each raster run's role signature in one pass over its property
  list, looks the token up by signature before rebuilding role lists, counts
  layer intervals in identity-keyed tables and fills each owner's mount pool
  with one liveness check. Desktop's four-window cohort ownership compiles in
  about 42 instead of 88 ms in batch, so the whole cohort prepares in about
  90 ms (272 ms before this release).

- A role compiled only as a cold ownership instruction, absent from every
  raster of the prepared surface, reserves one spare interval per movable
  layer instead of its object's full footprint; the pool still grows on
  demand within the fixed bound. Desktop's four-window cohort allocates
  about 18 700 instead of 28 700 mounts, and the scenarios that already
  grew pools grow them the same number of times.

- Structural publications (adding or removing layers, replacing a subtree)
  start from a private copy of the accepted render cache instead of an empty
  one, and cache signatures no longer depend on where rendering placed a
  node's `:region-id`. Unchanged sibling subtrees reuse their rendered output:
  closing a Desktop window renders about 31 instead of 65 ms of layout and
  the whole close drops from about 194 to 158 ms in batch.

- A paint slot keeps its specification and installation state on its face,
  so copies of a slot compare `equal` and `ebox-paint-slot-spec` and
  `ebox-paint-slot-installed-p` report the current state for every copy.
  Previously a copied slot kept the state it had when copied. Code compiled
  against the old slot layout must be recompiled.

- Prepared-geometry interaction setup resolves each native keymap's declaring
  node once per map and region set instead of once per text run, and
  `ebox-surface-region-bounds` (used by `ebox-host-ref-bounds`) reads mount
  extents without copying their tags. A four-window Desktop cohort
  preparation drops from about 278 to 256 ms.

- `ebox-update-prepare` may be abandoned by a quit or `while-no-input`. The
  accepted output and revision are unchanged, the report's `:reason` is
  `interrupted`, earlier prepared operations become invalid and the next
  preparation starts cold, so callers can compile cohorts without blocking
  input.

- Prepared geometry and cohort updates size each owner's interval pool from
  its intervals in the current layer pixels instead of reserving the full
  row bound for every owner, reducing a four-window Desktop preparation from
  about 107,000 to 26,000 spare mounts (about 440 to 285 ms in batch, and
  Desktop close from about 600 to 370 ms in the GUI). A later frame that needs
  more intervals, such as a maximized window, grows only the exhausted pools
  to the previous bound once and continues on the prepared route.

- Grid column sizing no longer renders cells for their natural width when
  every track is fixed, `fr`, or a `minmax` with a fixed minimum and a fixed
  or `fr` maximum, since such tracks never read cell content. Flex base-size
  measurement likewise skips the natural render of an item with a numeric
  `:flex-basis` whose main-axis minimum is declared or is zero because of
  non-visible overflow. The final sized render is then the only render, which
  roughly halves the cost of re-rendering a nested window chrome.
- `ebox-update-apply` re-renders a Host's composition boundary only when a
  changed member supplies a raster value (`:content`, `:hover-content`,
  `:color`, `:background-color`, `:border`, `:font-weight`, `:visibility` or
  an uncropped size) that differs from the displayed one. A mixed cohort
  whose members restack, translate or crop while repeating their paint now
  costs only the retained geometry program. `ebox-buffer-update-report`'s
  `:dirty-kinds` for a prepared update lists the work actually performed
  (`geometry`, `selector`, `paint`, `span`) instead of a fixed set.
- `:visibility` no longer inherits. A hidden box already suppresses its whole
  subtree's ink and focus checks every ancestor, so descendants never consumed
  the inherited value. Prepared paint publication recomputes a descendant's
  cascade only while an ancestor's inherited value or projected font changed;
  hiding, showing or recoloring the background of a Host with a large subtree
  now restyles that Host alone. Stylesheets that relied on `:visibility`
  cascading to a descendant's own computed value must hide the ancestor.
- Prepared geometry and property publication settles a recomposited row whose
  pixels equal the accepted output before wrapper rendering and buffer
  writes. Restacking or moving a panel that occludes nothing no longer
  rewrites every row it occupies.
- Resizing positioned Hosts whose composition owner is the root (for example
  stacked tiling panes under a root-wide Host) publishes through the local
  span patch instead of rendering the whole surface twice. The root owner has
  no enclosing content owners, so its retained owner suffix is accepted as
  provably empty.
- Text-property equality during commit compares only `keymap` and `local-map`
  as keymaps. Sticky property-name lists such as `rear-nonsticky (keymap)` are
  no longer treated as keymaps, and one candidate publication reuses a single
  region mount snapshot across its source and plan phases. Tiled pane resizes
  spend roughly a quarter less time in publication validation.

- Prepared cohort restyles run only for members whose paint or class values
  changed. A geometry-only publish of a Host that also declares `:visibility`
  or a color no longer recomputes its cascade.

- Prepared cohorts can publish coordinated selection classes, unchanged-thickness
  border colors, normal/bold font variants and nil color resets with geometry,
  Text and hover updates. Absolute Hosts in a cohort can also resize, change
  their content rows and toggle `:visibility`, releasing their footprint while
  hidden. A panel mounted hidden stays a prepared member: its rows compile
  ownership without painting, so a later `visible` publishes through the same
  retained route. Class values retain Ebox's canonical token grammar. Native
  focus/active metadata reuses the same publication authority when style
  dependencies are proven unchanged.
- Prepared cohort preparation no longer precomputes rasters, so frameworks can
  prepare again quickly after ordinary publications. Each apply renders only the
  changed retained primitive with the ordinary renderer.

- Framework integrations can prepare retained geometry operations for repeated
  absolute moves and stacking changes. Accepted operations preserve source
  snapshots and pair caller state with the existing publication rollback;
  unsupported dependencies continue through ordinary updates.
- Local updates retain ownership indexes when node relationships are unchanged.
  Native and Elisp output use the same role mapping, avoiding repeated ancestor
  resolution and temporary per-node hash tables during publication.
- Candidate caches preserve eviction accounting, and publication validates its
  installed generation without rebuilding private mount indexes. Complete
  buffer-output checks still reject unexpected callback or hook writes.
- Retained publication is now owned by Ebox. Update Ebox and ETAF together;
  the integration uses SPI v3 and `ebox-publication/v1`. Publication reports
  use `:publication-*` fields and the `ebox-publication` provider.
- Publication and rollback share the prepared candidate and journal; generic
  target-entry/outcome translation and postcommit shadow graphs are removed.


### Fixed

- Removing styled content now retires its style state from the published node
  generation. Closing a layer or removing an ordinary sibling no longer makes
  later focus, background paint and local content updates lose incremental reuse.
- Repeated percentage updates retain their raw allocation evidence when an
  intermediate result has integral pixels. Returning from a full progress bar
  to a partial value no longer discards an otherwise valid local projection.
- Focus and pressed-state changes after retained content updates preserve their
  selector metadata classification instead of unnecessarily rendering the root.
- Prepared metadata and paint projections survive unscoped publication and
  empty-range fallback. Focus and pressed-state updates no longer lose their
  incremental strategy and rebuild the complete surface during mouse input.
- Owner-scoped updates with integral published pixels skip the raw-layout
  buffer copy; the raw allocation path remains available when fractional pixel
  remainders require it.
- Local owner patches strip producer-only paint-origin carriers before
  publication, so unchanged property runs are no longer rewritten as if their
  public properties had changed.
- Retained interaction candidates carry their topology proof through
  declarative preparation instead of rebuilding the source interaction index a
  second time.
- Ebox owns text-property snapshots, mutable property graph copies, paint slots,
  computed style values and native keymap/property equality.

- Local rich-text updates reuse unaffected fragment parsing even when the
  changed interval gains or loses property runs. Paint addresses and target
  ownership are rebuilt from exact semantic facts; callback/keymap graphs no
  longer participate in role-cache hashing.

- Metadata and paint-only interaction candidates no longer use content-range
  scope proofs without candidate mount specs; they retain the complete mounted
  state while content geometry keeps its scoped proof.

- Local allocation proofs measure the changed owner's boundary and verify
  unchanged ancestor inputs, avoiding repeated mount snapshots and text
  measurements of unaffected ancestors. Final output checks remain required.

- Layer composition retains original row intervals until occlusion and row
  reuse are resolved. Hidden and reused content avoids eager slicing; visible
  glyphs are clipped once from their original shaping context.
  Overlays above unmoved normal flow compose directly over its completed rows,
  avoiding full flow disassembly and an unnecessary anchor prepass.

- Visually unchanged focus and pressed-state updates retain their source tree,
  selector relationships and viewport dependencies instead of revalidating and
  preparing a complete author tree. Actual style effects retain normal planning.

- Simultaneous text and descendant size changes can retain a stable Flex owner
  allocation, including fractional pixel layouts. Unchanged siblings preserve
  their geometry and paint while the owner rebuilds its interior output.

- Mounted responsive subtrees reuse rendered output under their exact viewport
  and containing-size constraints. Unrelated interactions no longer disable
  caches merely because a branch uses percentage or viewport-relative sizes;
  percentage heights include the containing block height in the cache key.
- Render cache keys preserve callback and keymap identity without traversing
  captured environments or recursive native bindings. Replacing a keymap still
  invalidates the affected output.

- Focus and pressed-state changes preserve proven selector relationships during
  source rebuilding. Unchanged scoped styles are reused, equal parent styles do
  not invalidate descendants, and subsequent updates read current selector facts.

- Focus and pressed-state transitions with unchanged computed styles reuse
  retained output, including scroll and layer content. Selector state still
  publishes normally and remains available to subsequent updates.

- Selector-only publications now use an exact-coordinate empty TP batch. The
  retained object set and rendered text are promoted as runtime state without a
  full surface reconciliation, including scroll surfaces.

- Primary-button presses preserve existing keyboard focus when publishing
  pressed state, including when focus belongs to another control.

### Changed

- Mounted primary-button activation in the selected window now focuses its
  target before invoking the callback. Consumers should use that focus as the
  return target for opened panels; events for other windows still preserve point.

- Replace `ebox-candidate-patch-host-paint` with
  `ebox-candidate-update-host-properties`. Frameworks can submit geometry,
  selector, style and interaction changes while retaining content and children.
  Keep the previous/next canonical arguments; previous input describes the
  captured base. The operation returns the candidate and no longer requests a
  subtree fallback. Use subtree replacement for node type or structure changes.

### Added

- Public observer reports expose exclusive source, style, planning, layout,
  projection and transaction timings for the shared workspace performance tool.

- `ebox-focus-within` navigates inside a committed subtree using the existing
  focus order, painted visibility and retained identities. Menus and dialogs
  can cycle within their panel without maintaining a separate target index.

- Generated primary-button gestures publish `:active` through the ordinary
  cascade while held. Pressed state follows retained updates and clears before
  activation or when tracking ends. Release outside the retained target cancels.
  `active` is now reserved alongside `focus` and `disabled`; replace authored
  `:states active` with a custom token. Mounted activation maps consume the
  release during their down command; input drivers must supply the complete
  native sequence instead of separately replaying release activation.

- `ebox-keymap-create :drag` delivers shared primary-button gesture phases and
  window-relative pixel deltas while retaining the published target. Consumers
  no longer need their own mouse-reading loop. With `:drag`, `:activate` remains
  available for keyboard activation.

- Native scrolling composes across ordinary wrappers, sibling containers and
  nested containers. Each region retains its own complete content and offset.
  Rebuild the optional module and restart Emacs.

- Native viewport heights support `vh` and height `calc` addition/subtraction,
  including nested Box constraints and column Flex bases. Window resize keeps
  the original viewport reference independently of parent allocations.

- Native single-row Grid supports fixed and fractional (`fr`) columns with
  automatic Text placement and stretched, clipped Box cells. Text minima,
  intrinsic sizing, cell paint and viewport changes follow ordinary Grid
  behavior.

- Add a native input boundary that guards mounted target ownership and restores logical focus after acceptance, cancellation or reader failure.

- Observed update reports expose recorded local projection refusals, including mixed
  native-property composition and retained style closure boundaries. The
  update-effect evaluator collects these reasons in two additional updates,
  separate from its unobserved latency samples, with the same correctness checks.

### Fixed

- Unkeyed Range items preserve source identity through reordering, insertion
  and removal. Subsequent nested updates reach the retained node and keep
  focus. Range and subtree publication now share sibling matching rules;
  frameworks need not add duplicate author keys to make local updates work.

- Native incremental publication reuses the confirmed frame across consecutive
  commits and viewport changes. Selector-only updates prepare rule-based and
  inherited styles before choosing their publication path.

- Native nested Flex layout reuses identical completed measurements within a
  frame, reducing repeated subtree work during rendering and resize. Rebuild
  the optional native module and restart Emacs to use the optimization.

- Scoped style bindings retain their own rule, membership and ancestry context.
  Inserting or removing another scope member no longer recomputes unaffected
  subject-local styles. Rule changes, inheritance and structural selectors keep
  their existing semantics.

- Resizing an unused viewport axis after a scroll owner shrinks no longer
  unexpectedly republishes the surface. Returning to native layout after an
  ordinary update preserves independently scrolled regions.

- Native structural updates retain current scoped colors and inherited styles
  when nodes move or change ownership. Reused display objects no longer bypass
  the candidate's required style computation.

- Text updates in content-sized layouts recompute affected sibling geometry.
  Shrinking content after a retained-node update no longer rejects a valid
  publication because sibling filler fell outside a local content span.

- Retained nodes keep their editable handles and rendering objects when siblings
  are inserted or reordered. Surface publication now follows Ebox's reconciled
  node identity, including unkeyed nodes and child ranges.

- Complete style projection refreshes inherited text paint and font geometry
  without reusing stale render signatures. Later scoped updates no longer reject
  valid input because an earlier update left old descendant rendering visible.

- Unkeyed children with stable source identities remain targetable when
  conditional siblings appear or disappear, including nested Host updates.

- Overlapping Range writes resolve the final candidate payload in either
  recording order. Keyed children no longer inherit stale sequence positions
  when sibling insertion or removal accompanies a nested Host update.

- Nested Range updates keep runtime indexes attached to the final candidate tree, so later Host updates remain valid. Large subtree replacements preserve source order when records are added or removed, including rejected publications.

- A candidate replacing an ancestor and then a deeper child preserves the
  ancestor's changes to siblings along the intervening path. Nested input forms
  no longer restore old captions while updating save/cancel controls.

- Combining inherited parent paint with child content replacements now keeps
  subsequent edits and exported snapshots consistent. Later updates no longer
  restore text from an earlier publication through stale descendant indexes.

- Incremental updates avoid repeatedly copying unchanged mounted ranges while
  planning local projection candidates.

- Repeated candidate subtree updates evaluate structural selectors against the
  complete candidate context. Added children, affected siblings and rejected
  publications retain the same styles as a fresh render. Local publications
  preserve scope evidence for subsequent updates instead of discarding it.

- Local content updates under scoped styles preserve eligible local publication.
  Candidate scope checks include mounted rules and membership, and unchanged
  keymap snapshots no longer force complete rendering. Changed bindings still
  publish through the ordinary transaction path.

- Viewport updates of visible-overflow Flex layouts no longer consult an absent
  measurement cache during uncached geometry probes.

- Native Boxes pass definite content height to their inner Flex layout, including
  main-axis and cross-axis allocations from a parent Flex. Stretched nested cells
  keep their full background coverage; auto heights remain content-driven.

- Native Box formatting preserves composed Flex, row and column lines instead
  of wrapping adjacent items again. Ordinary text still follows its wrap mode.

- Native frames resolve font-relative root widths in the root font context
  instead of substituting the viewport width. Retained frames keep their exact
  accepted root width as the base for subsequent publication.

- Native Flex layout accepts supported explicit main-axis minima, including
  zero, and follows the same overflow-dependent automatic minimum and size
  caps as Elisp. Rebuild the optional module for the current ABI and restart Emacs; older modules
  cannot supply the corrected semantics. Unsupported scene features still use
  ordinary rendering.

- Viewport updates compare the mounted local and shared scopes when proving
  style stability, preserving retained reflow for unchanged scoped styles.

- Retained intrinsic-size measurements preserve already computed scoped styles.
  Updating a scoped application no longer attempts to remount an ancestor scope
  on a detached subtree, which could fail during pagination.

### Changed

- Mounted focus now drives `:focus` selectors, paint and layout in the same
  publication. Clearing focus can shrink layout and clamps numeric point.
  Invalid focus styles reject the selection; hiding or clipping a retained
  target clears its state before publication. Focus changes notify observers.
  Replace authored `:states focus` or typed `:selector-state '(focus)` with
  mounted focus operations; authored focus tokens now signal an error.

- Focus setting, clearing and navigation reject active TP transactions before
  mutation. Move such calls to accepted `after-commit` callbacks; outer rollback
  no longer risks leaving an uncommitted focus change. Queries remain available.

- `:disabled` now supplies both interaction protection and the `:disabled`
  selector state, including retained cascade updates and rejected publication.
  Move authored `:states disabled` or `:selector-state '(disabled)` to the
  `:disabled t` interaction input; authored disabled states now signal an error.

- Mounted `ebox-buffer-mode` now owns cyclic TAB/backtab navigation and
  RET/return activation. Rename customizations of `ebox-scroll-map` to
  `ebox-buffer-mode-map`; the old map is removed.
- Default `ebox-activate` and generated keyboard activation commands prefer
  logical focus while point remains at its first visible character. Explicit
  position activation and mouse clicks still select their physical target.

- Focus prefers a surviving source identity over a reused layout node. When a
  generated source reference expires, only a matching retained sibling key can
  preserve focus; an unkeyed replacement cannot acquire the removed focus.
- Interaction-only updates publish source facts even when rendered properties
  are unchanged, including tab order and replacement keymaps on disabled nodes.

- `ebox-style-scope-with-rules` updates root rules while retaining scope
  membership across imported fragments. Old canonical snapshots stay unchanged.

- Shared immutable style scopes can mark multiple canonical roots and explicit
  source memberships, preserving projected content ownership without visual
  wrappers. Rules support ECSS origins and follow retained source publication.

- `ebox-canonical-box-configuration` shares provisional layout and outer
  projection between canonical producers and the DSL, deferring ECSS-tagged
  values until cascade computation.

- Tree selector queries refresh stale subject views after canonical metadata
  commits. Changing only a local stylesheet's target identities now invalidates
  its computed output as well.

- Canonical source bindings accept `:ecss-targets` to preserve author ownership
  across nested component content. Targets are resolved per candidate; invalid
  target identities fail without replacing committed output.

- Programmatic ECSS importance, CSS-wide longhand values and variable
  references reach paint and layout through cascade computation. Inline custom
  properties and retained updates now propagate to paint and geometry consumers.

- Local file and DSL styles share the ECSS rule-list reader and strict Ebox
  schema. Remove the outer quote in `.ecss` files. Canonical producers can use
  `ebox-style-compile-rules` for the same validation and compilation.

- Expose the package entry at the repository root, document supported APIs in
  its Commentary and retain implementations under `lisp/`. Source consumers add
  the repository root to `load-path` and require the package entry; internal
  feature imports are unsupported. Archives retain this same directory layout.


### Added

- Native Box widths, minimum/maximum widths and row Flex bases accept `vw`
  lengths against the original frame viewport. Resize resolves them again;
  nonintegral results fall back. Composed viewport expressions, gaps and other
  relative units continue through ordinary rendering.

- Fixed single-row Grids with stretched clipped cells can publish native frames.
  Cell chrome and box sizing participate in track allocation; updates that leave
  this subset use the ordinary Grid renderer.

- `ebox-focus-first` selects the first eligible tab stop independently of current
  focus, leaving focus and point unchanged when no stop is available.

- Buffer-local logical focus with explicit setting, querying, ordered navigation
  and optional cycling. Retained updates preserve focus and point, while rejected
  publication restores them; removal, hiding, disabling and unmount clear focus.
  Nodes accept local `:tab-index` and `:disabled` capabilities. Disabled nodes
  suppress their declared or inherited keymap until reenabled.

- `ebox-activate` invokes the current committed node's RET binding, with optional
  explicit position and quiet handling of missing targets. It respects native
  keymap ownership, nil barriers, visibility, retained updates and unmount.

- Explicit native node capabilities `:help-echo`, `:pointer`, `:hover-style`,
  and `:keymap`, including callback adapters `ebox-help-create` and
  `ebox-keymap-create`, nested overrides, explicit-nil blocking, and retained
  updates. These do not require ETAF or an arbitrary text-property escape hatch.
- Optional `ebox-next-interaction` and `ebox-previous-interaction` navigation
  commands for rendered keymap owners, independent of the declared tab stops
  used by the mounted buffer mode; no application state system is installed.
- Explicit geometry units `px`, `%`, `vw`, `vh`, `ch`, and `lh`, composable
  `calc`/`min`/`max`/`clamp` functions, and construction-time axis validation.
- A repository-level GPL-3.0-or-later license and consistent Ebox/Rust package
  declarations, with third-party notices retained.
- Locked dependency inputs and a reusable source-archive build/install verifier
  (`make release-check`), including optional EKP and explicit native-module
  integration. CI now prepares ECSS as well as TP, tests the minimum supported
  Emacs version, and configures native loading/execution on all three platforms.
- Direct dependencies on the independent ECSS 0.1.0 cascade engine and TP 2.0.0 retained/reactive text runtime.
- ECSS-backed property schemas, selectors, stylesheets, inheritance, cascade layers, custom properties, computed values, and provenance for Box, Flex, and Grid nodes.
- Surface-scoped region handles through `ebox-region-resolve`, retained TP publication through `ebox-render-to-buffer` and `ebox-display-buffer`, and atomic handle/selector/viewport/scroll updates.
- Typography longhands and inherited foreground projection that keep text readable when child boxes override background colors.
- A public, nestable framework render-burst boundary that covers pre-commit allocation, shares interactive deferred GC ownership with Ebox commits, and restores batch GC settings without collecting at the boundary.
- Structured TP participant registration for every retained publication.

### Changed

- `ebox-display-buffer` renders before calling native `display-buffer`, accepts
  its optional action argument, and returns the rendered buffer. Ebox no longer
  deletes other windows or selects the result as part of ordinary display.
- `:overflow hidden` now also enforces horizontal content width, including
  composed child output, while retaining the owner's padding and border.
  Clipping preserves supported text clusters and visible properties, removes
  clipped child interactions, and fills remaining pixels without an ellipsis.
  This adapts the GPL-compatible s-pixel approach without a new dependency;
  partial-glyph masking and stacking are not introduced.
- `:wrap-mode kp` explicitly requires the optional EKP package. Missing or
  incompatible EKP now reports an installation/update error instead of silently
  selecting word wrapping. Other wrapping modes do not require EKP.
- The minimum TP dependency is now 2.0.0 with the final v2 participant protocol.
  Native keymap ownership, callback identity, and shared hover regions require
  its property policies; the former TP 1.0.1 transition baseline is insufficient.
- Incremental updates reuse proven unchanged style, identity, ownership, and
  viewport facts. Content and paint changes keep the smallest safe publication
  scope; geometry or dependency changes still promote to a larger owner when
  required. TP publishes the changed text interval and preserves rollback.
- Hover paint covers the declaring owner's text and padding as one native
  hover region per rendered line, while preserving physical side borders.
  Nested explicit hover declarations remain separate regions.
- Package metadata now distinguishes builds with the public unmount/revision
  boundary and SPI v2 compatibility surface from older 2.x development
  snapshots.
- Early 3.0 development used TP 1.0.1's structured transition protocol. The
  release candidate now requires TP 2.0.0 or newer and always
  uses the public structured participant API.
- SPI initial publication owns widening and an outer editor change group. A
  failed stage or nonlocal rollback exit restores text, markers, overlays,
  point, mark, narrowing, undo history, and modified state before it escapes.
- ECSS is the only selector matcher and cascade winner. Ebox adapts node trees to ECSS subjects, interprets computed values for measurement/layout/paint, and classifies their layout impact.
- TP is the only live buffer writer. Ebox produces retained surface candidates and semantic dirty-owner plans; TP owns diff execution, marker-backed mounts, revisions, transactions, and rollback.
- Flex and Grid container/item declarations enter the same ECSS pipeline as ordinary boxes instead of maintaining a parallel style path.
- Region updates use opaque surface-scoped handles. The same declarative source may be mounted in multiple buffers without sharing live identity.
- A full declarative update that continues a committed native frame now computes
  a complete selector-local style certificate before stable native eligibility.
  Other full/local paths retain their existing O(changed) style work. Native
  updates no longer commit replacement runtime nodes without computed styles,
  and structural full-frame bootstrap remains available.

### Removed

- `ebox-pop-to-buffer`, `ebox-switch-to-buffer`, and the private erase-and-evaluate buffer writer they exposed.
- Ebox's duplicate selector parser/matcher and duplicate cascade winner.
- Bundled playground fixtures. Executable `.ebox` references live in the independent `ebox-playground` package.
- The Ebox transaction route switch, v1 TP participant adapter call, and
  missing-capability fallback.

### Migration

- Replace legacy geometry literals with explicit units: for example,
  `:width 80` becomes `:width (ch 80)`, `:width (240)` becomes
  `:width (px 240)`, and `:height 3` becomes `:height (lh 3)`.
  Choose units for dynamic values explicitly at their producer.
  Vertical geometry rejects `px`, and `fit-content` is now a bare keyword.
- Callers requiring selected or exclusive display must choose that window
  policy explicitly; ordinary `ebox-display-buffer` follows native display
  rules. Rendering without display remains `ebox-render-to-buffer`.
- Install EKP 1.0.0 or newer only when using `:wrap-mode kp`; its optional native
  accelerator is independent from Ebox's optional Rust reflow module.
- Install ECSS 0.1.0 and TP 2.0.0 or newer, in either order, before Ebox 3.0.0.
- Remove any customization of `ebox-transaction-participant-route`; Ebox 3.0.0
  requires TP's structured participant capability and fails closed when it is
  missing or malformed.
- Replace numeric region-id mutation with `ebox-region-resolve` followed by `ebox-region-update` on the returned handle.
- Replace `ebox-pop-to-buffer` or `ebox-switch-to-buffer` with `ebox-display-buffer`, or call `ebox-render-to-buffer` when display is controlled by the caller.
- Ebox does not scan previously rendered text to reconstruct runtime identity. Remount the declarative source through Ebox 3.0.

### Release status and supported boundaries

- `3.0.0` remains unreleased. These changes prepare source distribution; they
  do not announce an uploaded package archive or published release tag.
- Each mounted buffer owns one viewport layout. Use separate buffers for views
  requiring independent widths. Vertical geometry remains whole-line based.
- Common UI text clusters are preserved, but complete Unicode grapheme
  segmentation, browser-level bidi, stacking, and absolute positioning are
  outside the current contract.
