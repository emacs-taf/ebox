# Ebox incremental update contract

This document defines the low-level publication contract. It is independent of ETAF application state and must remain true for direct Ebox callers and higher-level packages alike.

## Prepared image content

`ebox-image-prepare SOURCE COLUMNS ROWS` is the single capability-selection
entry point. It returns an opaque raster for a positive integer character area.
`SOURCE` is a local file path or an Emacs `(image :type TYPE :file FILE)` /
`(image :type TYPE :data BYTES)` descriptor. Preparation owns file reads,
decoding and external processes. Missing, unreadable or unsupported images use
the fallback; invalid arguments signal before publication. No remote files or
new package dependencies are introduced.

Selection order is graphics → text converters → placeholder. Graphics requires
`display-graphic-p`, usable default-font metrics, an available image type and
successful decoding at the requested size. `:adapter text` skips graphics;
`:adapter placeholder` skips both. `ebox-image-info` reports `:adapter`
(`graphics`, `text`, `placeholder`), `:converter`, `:columns` and `:rows`.

Graphics preparation creates and decodes one image from owned source bytes at
`columns × frame-char-width` by `rows × frame-char-height` pixels, with explicit
scale 1 and no image margin. Every character carries
`((slice X Y CELL-WIDTH LINE-HEIGHT) IMAGE)`. The integer `:ascent` percentage
is rounded upward from the frame's default-font ascent divided by its line
height, because redisplay truncates that percentage back to pixels. Metrics
without an exactly representable ascent decline graphics. There is no minimum
pixel height. All cells share the descriptor. Repeated renders
reuse the exact immutable descriptor and slice values. Display-bearing spaces
are visible content and cannot be collapsed into blank-line filler.

Text preparation tries optional `chafa` first, requesting full RGB colors,
only U+2580, exact stretched dimensions and a still frame with no terminal
probing or cursor movement. ANSI colors become ordinary `face` properties.
If unavailable, failing or malformed, `ffmpeg` scales one frame to `columns`
by `2 × rows` RGB24 pixels; the upper pixel is the foreground and the lower
pixel is the background of each `▀` cell. Both adapters stretch to the full
allocation. Terminal color approximation is left to Emacs. If neither works,
the documented monochrome placeholder is a grid of ASCII `.` characters,
with the same dimensions and no process invocation of its own.

`ebox-image-converters` is an ordered `(NAME . FUNCTION)` protocol, also
accepted as `:converters` by preparation. A function receives source, columns
and rows, and returns nil or an exact grid: rows separated by one newline,
no final newline, columns U+2580 characters per row, and a `face` plist on
each cell with `:foreground` and `:background` in `#RRGGBB` form. Errors and
invalid grids try the next function. Only those color properties are adopted;
converter-owned strings, faces and source descriptors are detached. No `display`,
keymap, ownership or other converter-supplied property crosses the boundary.
The fixture executables in acceptance test both default converters without
requiring either installed tool.

The cache holds at most 64 preparations, keyed by source identity, columns,
rows, requested adapter/converter protocol and graphics metrics. File identity
includes absolute/resolved path, size, modification/status times and inode;
descriptor data participates by value. `ebox-image-cache-clear` refreshes
converter configuration or installed capabilities without changing live content.
Prepare again after a file, frame or font change; render on the prepared frame's
default character grid. Buffer-local text scale and ancestor font-size overrides
are not inputs to preparation. CSS sizing overrides can
change the ordinary Box allocation and therefore require ordinary layout proof.

`ebox-image-create PREPARED BUILDER &rest SOURCE-PROPERTIES` creates a canonical
Box with one owned Text child. Its declarations fix `(ch columns)` / `(lh rows)`,
hidden overflow and no wrapping. It accepts source-builder metadata, including
`:identity`, `:id`, interactions and style scopes; callers cannot supply competing
`:declarations`. This is ordinary content in Row, Column, Flex, Grid, clipping,
source snapshots and rollback, with no second image-specific publication path.

```elisp
(let* ((cover (ebox-image-prepare "/music/cover.png" 24 12)) ; cold I/O
       (builder (ebox-source-builder-create))
       (node (ebox-image-create cover builder :identity 'cover :id "cover")))
  (ebox-render-to-buffer
   buffer
   (ebox-canonical-input-create
    (list node) (ebox-source-builder-finish builder))))

;; Prepare outside the render/commit callback; publish only cached content.
(let ((next (ebox-image-prepare "/music/next.png" 24 12)))
  (ebox-region-update (ebox-region-resolve buffer "cover")
                      :content (ebox-image-content next)))
```

`ebox-image-content` returns an owned string; its nested graphics display values
are immutable and shared. A same-size source change uses ordinary `:content`
updates or canonical replacement plus `ebox-commit`. No-op comparison includes
text properties, so two all-space images or identically shaped half-block grids
with different pixels are different content. Formatted content regenerates its
own properties and recomposes proven enclosing paint rather than transporting
old cell colors/slices. Existing allocation, role, ownership, output and rollback
checks remain in force. The acceptance scenario for a 24×12 cover above a lyric
requires a committed `span-patch`/`owner-scoped` projection, one dirty node, one
patch and no full-root publication, then compares exported/fresh rendering.
Dimension changes use node replacement and the normal layout planner.

For 24×12, graphics preparation builds 288 slices and one decoded descriptor;
text preparation builds 288 half-blocks from 576 RGB samples (1,728 raw bytes);
placeholder preparation builds 288 ASCII cells. Each cached raster has 11
newlines. Commit copies/publishes the prepared block and performs ordinary
retained validation, with zero image creation or conversion. Preparation is a
synchronous cold operation; callers can schedule it ahead of an interaction.

`benchmarks/benchmark-image.el` measures cold preparation, a preparation cache
hit, an owned content copy and a same-size commit separately. Run with the
normal batch load paths and `-f ebox-image-benchmark-batch`. It uses real
installed text converters and labels simulated batch graphics explicitly:
those graphics numbers exclude native decoding and redisplay. Identical
placeholder pixels correctly produce a no-op commit. A native SVG probe on
Emacs 31.1 with 7×16 cells and a 13-pixel font ascent verified `:ascent 82`,
16-pixel slice rows, and 208 pixels for twelve cover rows plus one lyric row.

## Publication runtime

Ebox owns one retained publication runtime. A prepared candidate is shared by
projection, text/property writing and rollback; it is not translated into a
second package's target-entry or outcome graph. The content-only publisher
keeps one baseline for failure recovery and validates the final text/property
result before accepting framework authority. The former generic watcher,
properties-only surface and external variable-signal routes are absent.

The surface context tracks viewport, display and scroll inputs. Style bindings
retain exact dependencies; application refs remain ETAF-owned. Native property
composition and paint slots belong to Ebox, while ECSS owns selector/cascade
semantics. Frameworks integrate only through SPI v3 (`ebox-publication/v1`).

Candidate inputs are validated before the publisher installs its private object
and mount indexes. Precommit checks the installed generation by identity; it
does not rebuild sets to revalidate the same private indexes. Public callbacks
and buffer hooks can change text or properties, so the complete expected output
is still checked before lifecycle settlement and again at final acceptance.
An authenticated unchanged subtree retains its objects and live bindings as a
subtree proof rather than copying each identity into a candidate set. New objects
cannot inherit that proof merely by occupying the same path.

## Ownership

1. The caller owns the fresh source tree.
2. `ebox-tree.el` owns identity, keys, traversal, and snapshots.
3. `ebox-style.el`, `ebox-measure.el`, and the layout modules own normalization, measurement, and geometry.
4. `ebox-incremental.el` owns dirty classification, live-fact adaptation, pure declarative commit preparation, and Ebox report semantics; `ebox-patch-plan.el` reduces tentative operations using only immutable parent facts.
5. `ebox-surface.el` projects retained candidates and joins Ebox runtime-state publication to the Ebox publication transaction.
6. Ebox publication owns generic retained-surface reconciliation, mount/index state, all live buffer diff execution, revision changes, and rollback for initial mount, declarative commit, handle update, viewport/theme update, and scroll update.
7. `ebox-buffer-backend.el` only builds and reshapes propertized render strings. It does not own live markers or a buffer mutation executor.

No layer may infer application state from visible buffer text. No public caller may mutate a published tree in place. Every public live-publication route, including `ebox-render-to-buffer`, its `ebox-display-buffer` display wrapper, and commit/update entry points, uses a retained Ebox publication surface; the public facade exposes no erase-and-evaluate-body buffer writer.

Native and Elisp fragment ledgers share one ownership projection. A proven
unchanged node topology retains the published node/object and region/object
indexes and resolves only previously unseen role combinations. Candidate caches
retain only role combinations in the current output; failed candidates cannot
mutate the accepted cache. Structural projection and complete fallback rebuild
the indexes. Equal copied role tags preserve mount identity just like identical
tags; object identity and exact candidate coordinates remain validated.

A native full-line change can still retain the fragment ledger when character
coordinates and ownership are unchanged. Shared atom programs prove fixed-space
width changes without expanding unchanged text: decorations, line breaks and
existing fragment boundaries must match. Any unproved shape, character or paint
change takes the ordinary encoder and its complete validation path.

Empty author scopes carry membership but no cascade rules. They do not disable
selector-free style reuse or require independent style bindings for otherwise
inheriting nodes. Adding or removing real rules still changes the scope signature
and runs the ordinary cascade, ownership and invalidation checks.

Candidate render caches copy their eviction rings and recorded storage costs
with the table. Immutable retained outputs do not need their complete object
graphs recounted after each candidate copy. Ring vectors remain private, and
changed capacity settings still enforce both entry and byte limits.

Fractional-pixel output retains one role/paint ledger for raw allocation and
rounded display coordinates. Pixel quantization changes only display widths;
initial projection therefore parses this ledger once and later local edits
reuse it without reparsing the complete raw frame.

Raw allocation evidence belongs to the retained generation, independently of
whether its current display contains fractional widths. An integral intermediate
result keeps that evidence for the next update. Computed-effect normalization
also preserves already classified selector metadata; normalizing a retained
state twice must not turn a display-neutral interaction into a root update.
Computed render-effect signatures derive their engine fields from the style
registry. Box frame and item effects use their projected node values, container
effects use the computed LayoutConfig, and typography uses the resolved font
fact. Position, stacking, anchoring, and track/alignment changes therefore
remain geometry effects even when a selector change is their only source
delta; unchanged computed values do not become render work.

The style graph is owned by one published node generation. Complete object
projection selects only states whose objects and bindings belong to that
candidate. Removed or omitted bindings are retired after publication; weak
table collection and binding liveness do not establish candidate membership.
This keeps a removed layer or ordinary sibling from invalidating later local
updates elsewhere in the document.

Local content-slot reuse requires a parent allocation independent of the changed
content. Equal parent declarations and retained coordinates alone do not establish
that condition: intrinsic width can shrink or grow and alter sibling alignment
and filler. Such updates promote to the containing layout before publication.

ECSS-tagged declaration values and custom properties remain in source facts
until cascade computation. Provisional canonical nodes materialize only concrete
engine values; tagged dimensions never enter layout directly. Both full rendering
and retained source updates request style computation for these declarations.
Paint-only shortcuts require concrete input, since explicit `var()` or `inherit`
values may depend on a parent even when the child declares the property itself.

Local stylesheet facts can carry explicit source identity targets. Candidate
source indexes resolve these identities to their own selector subjects and pass
membership snapshots to ECSS scopes. Retained source rebinding and canonical
exports preserve target facts. Scope caches share a generation only when ordered
scope definitions, membership and exact selector subject identities are unchanged.
Inline paint updates retain equal immutable subjects; changes to selector facts,
relationships or scope declarations invalidate that generation. Author ownership is therefore independent of physical parentage and live buffer
coordinates. ECSS continues to own structural matching and inheritance.

Selector subjects store immutable local metadata and stable parent/child keys.
Each source generation resolves those keys through its own persistent index and
ECSS subject adapter. Candidate path copying updates affected subjects without
repairing backreferences in unchanged children or mutating the published tree.
Query entries and lookup tables may remain lazy; style evaluation already has
coherent candidate relationships and does not rebuild them merely for a query cache.

Cascade reuse compares mounting source identity, rules, target membership and
inherited values. Each style state keeps the immutable parent style observed by
that generation. Parent bindings may already contain a candidate value when a
child is visited; their mutable last value cannot stand in for the committed
inheritance input. This keeps Theme color shortcuts from retaining stale fonts
when a parent typography change also reaches explicitly colored children.
A parent colour delta requires an actual change in the
computed parent foreground. Unchanged parent styles keep the retained compute
function and dependency graph; explicit child foregrounds retain their immutable
style when only the parent colour changes. For subject-local selectors, each binding retains its own
ordered rule inputs, membership and ancestor identity chain. Adding or removing
another member does not invalidate an unaffected binding. Subject metadata,
scope roots, applicable rule revisions and inherited bindings still participate
in reuse. ECSS classifies selector dependencies; Ebox proves host relationships
and scope facts. Structural selectors retain full invalidation. This reduces
repeated style work during ordinary projection; it does not make every
native-property or mixed update a local projection.

Native structural updates can retain display objects while requiring a complete
style projection. In that case, the candidate rebuilds selector relationships
and applies current styles to every node before native layout consumes it.
Retained object identity alone never certifies style reuse; stable native
updates still require the planner's prepared-style contract.

Canonical selector-metadata changes prepare the complete candidate style tree,
including nodes styled only by rules. Both renderers receive the complete computed
effects before planning, including changed nodes outside the source delta.
The check visits only nodes prepared by the Style Adapter. Native continuation
uses the confirmed frame in the published fragment ledger and its root geometry;
temporary render fields carry only the current unpublished result. A native plan
requires an executable viewport before it can bypass ordinary projection.
Its complete frame must also exclude vertical `stretch`, `min-content`,
`max-content` and `fit-content` sizes, including height bounds on unchanged
descendants. These compiler limitations select Elisp during planning, while
horizontal stretch and supported automatic or definite heights remain native.
Unsupported Grid shapes are also declined before compilation. Admission of an
unchanged node partition can be retained; the candidate validates its exact
changed partition against the accepted node-index identity.

For coordinate-stable retained line changes, native publication expands only the
changed line programs and adjoining guard lines. It proves unchanged line and
character coordinates, fragment boundaries and ownership before reusing the
fragment ledger. Paint deltas replace both property-template and style IDs.
Coordinate changes, changed ownership, active scroll producers and unproved root
metadata use the complete encoder. Both paths feed the same publication batch,
output validation and rollback boundary. Change proofs are transaction-local;
confirmed frames do not retain their predecessor through a proof chain.
Synchronous session forks share immutable confirmed data without starting queue
workers. The first asynchronous submission starts the bounded worker pool.

Local style preparation reads the candidate's mounted scopes and compares them
with the published context before reusing styles. Tree-dependent matching defers
to complete projection. A pending author-style transition selects that boundary
before local geometry probes can render a detached subtree. Every successful
local projection retains the complete stylesheet signature for the next update;
the scope of computation does not reduce the published context. Retaining a style
binding also checks selector facts on paint owners: a change classified as paint
can still change the class or interaction state that selected its rules.

Local owner proofs resolve scope signatures from the candidate source index,
including immutable rule revisions and membership, rather than ambient render
bindings. Retaining enclosing native keymaps uses Ebox publication's property equality policy:
defensive copies with identical bindings remain equivalent, while changed
commands, prefix maps or inherited bindings require publication.

Complete cascade projection starts a new generation of render-signature,
viewport-height and intrinsic-width memos. Source-path invalidation alone cannot
authenticate these derived facts: inherited styles can change a descendant whose
source is unchanged. Rendered output remains cached by its newly computed
signature. Proven local projections retain their prepared cache invalidation.

Canonical producers and the DSL derive provisional LayoutConfig and outer
fields through one Ebox-owned declaration projection. It filters deferred values
and caches concrete configurations without taking ownership of source declarations.
The complete declarations remain inputs to cascade.

Shared author descriptions are immutable stylesheet snapshots. Source records
carry member and root markers; the candidate source index groups those markers
into ECSS mounts. Multiple roots do not require synthetic visual nodes. Membership
is candidate-local, so slot insertion and removal change ownership through ordinary
source deltas. Rule revisions preserve membership identity while each root selects
its immutable stylesheet. Cascade signatures include description identity, stylesheet revision,
mounting source and member identities. Unanchored descriptions remain inert until
composed with a root.

A native Box passes its resolved definite content height, including a parent Flex
allocation and height clamps, to its inner Flex formatting context. The child
evaluation retains that allocation as part of its request. An indefinite auto
height stays content-driven; the ambient viewport height is not an allocation.

Native layout input version 3 encodes each measured cluster as a six-field
vector: text, pixel width, CJK flag, space flag, fixed-pixel-space flag and
nullable source-template id. The compiler's immutable measurement cache is
versioned with that input. Compact tuples avoid repeating field names for every
grapheme; native deserialization and geometry/template validation remain strict.
ABI `24:10:14` separates this input from older installed artifacts.

Within one native frame, completed layout requests are shared by source address
and exact constraints, including both viewport axes, intrinsic mode, size overrides
and scroll-effect mode. Flex measurement phases can reuse the same completed
subtree without repeating its layout. This memo belongs to the immutable frame
transaction and is discarded afterward. Each caller retains its own use edge and
compares changes against its own previous result; final scroll ownership remains
distinct from measurement probes. Cross-frame reuse still uses source invalidation
and the retained evaluation tree. Each evaluation records reads of the CSS
viewport axes through the viewport-unit resolvers, including reads inherited
from reused child evaluations. An unchanged source may reuse its result when
only an unread CSS viewport axis changed; containing-block constraints,
intrinsic mode, size overrides and scroll-effect mode still match exactly.
This lets a capped reading column reuse its content when its outer margins
change, without treating nested `vw` or `vh` values as fixed sizes.

Auto-height single-row Grid layouts have native fixed and fractional tracks.
Cells are automatically placed Text or stretched, clipped Boxes without competing
size constraints or margins. Native track allocation retains text minima,
measures indefinite fractional tracks from content, and rounds cumulative pixel
boundaries. Cells retain their source ownership, chrome, paint and overflow
behavior; changing content or the viewport recomputes their allocation through
the same retained source/evaluation path. Unsupported Grid configurations retain
the complete Elisp implementation.

Native layout contexts retain both original frame viewport axes separately from
containing-block and Flex item allocations. Literal `vw` widths and row bases,
and `vh` heights, bounds and column bases remain relative in the IR and resolve
for every frame, including retained requests. Height `calc` addition and
subtraction preserve signed operands; font metrics convert viewport pixels to
the owning node's line domain. A fractional or out-of-range operand rejects the
native candidate before publication and uses the ordinary layout path. Other
context-dependent expressions retain the complete Elisp implementation.

## Commit lifecycle

Framework candidates distinguish local Host property updates from subtree and
child Range replacements. Property inputs compare two authored generations;
computed layout and inherited style values never serve as the previous input.
The property operation preserves content and child topology, then joins Ebox's
ordinary style, layout, impact classification and publication pipeline. Consumers
do not classify paint-only changes or choose a subtree fallback.

Property updates refine retained owners after structural composition. Removed
owners receive no update, and complete root replacement absorbs all operations.
The source index and final path-copy trace describe the same resulting tree.

```text
fresh root
  -> validate and normalize
  -> copy into surface-owned candidate state
  -> reconcile Ebox publication objects, keys, and Ebox identity
  -> measure/layout candidate
  -> classify dirty owners
  -> produce Ebox publication surface plan plus Ebox report base
  -> Ebox publication prepares and atomically publishes buffer changes
  -> Ebox transaction participant publishes matching runtime indexes/report
  -> retire superseded Ebox timers and warm the committed scroll state after success
```

The candidate is either fully published or discarded. A failed render, Ebox publication write, Ebox participant, or publication callback preserves the previous buffer text, properties, Ebox publication revision, Ebox runtime identity, scroll state, and last successful report. If the target buffer is killed during publication, teardown is authoritative and rollback never resurrects it.

Output audits compare the live buffer against detached patch evidence at precommit
and final acceptance, so participant or hook writes are found even when they change
only text properties. A retained batch that validated every patch as it wrote and
whose buffer tick is unchanged since that write has no later writer to find; any
subsequent write bumps the tick and restores the complete segment comparison.

Publication-generated conditions carry detached diagnostics: retained record IDs,
numeric coordinates, short strings without properties, and bounded collections.
They never expose live surface or callback graphs to Emacs error reporting.
Condition types and rollback order are preserved; caller-generated conditions
keep their original data. Diagnostic payloads are not live-state capabilities.

Projection planning shares numeric Ebox publication mount snapshots across its local proofs.
This read view exists only during one planning pass and is discarded before Ebox publication
publishes coordinates. It neither replaces Ebox publication's authoritative mounts nor changes
the defensive snapshots returned by public Ebox queries.

The fragment ledger retains direct role facts and newline counts independently
of derived paint addresses, layout dependencies and ownership ranges. A local
replacement reparses its aligned fragment window; changed role topology requires
fresh target ownership, not a full text/property scan. Ledger completion rebases
offsets, paint occurrence ordinals and cross-window line dependencies from these
facts. Coordinate-only ownership reuse is disabled when the roles change.
Role extraction caches use semantic role keys, never native keymaps, callbacks
or complete text-property plists. Unaligned or unsupported windows still use
ordinary parsing and expose an observed `fragment-ledger` rejection reason.

Metadata and paint-only interaction candidates retain complete mounted state
and therefore do not claim a content-range scope proof. Content and geometry
patches keep scoped publication only when their candidate mount specifications
prove the same ranges.
Publication scope and projection strategy are independent: unscoped publication
and an empty-range fallback still consume the planner's prepared projection and
source ownership. Proven selector-only candidates retain the accepted tree;
new interaction facts reside in their candidate source index.
A flex item with an automatic basis keeps its own slot when its main size is
definite and the published slot equals that size. A slot decided by growth or
shrink still requires a fixed basis with a zero main minimum. Those proofs let
the update publish the item's own slot instead of widening it to the containing
formatting context; the surface still validates the complete replacement
footprint before publication. Because a local render records paint origins, the
render cache signature includes the paint-origin capture mode, so one cached
render cannot authorize the other mode.
Grouped span proofs can include the non-root owner's own paint and typography,
including resolved inherited font facts, alongside descendant paint, content
and surface-property changes. Horizontal border width/style changes additionally
require an unchanged definite or stretched border-box width; changed fonts must
not affect font-relative width, bounds or exterior margins. These proofs retain
a Column slot or content-independent Flex allocation and ordered child identities.
The owner's comparison excludes only the typography and proven horizontal border
inputs being rendered; ancestor and canonical equality retain their strict contracts.
For border restyles, planning absorbs inherited effects into their changed source
owner before ordinary geometry promotion. Independent title/subtitle changes may
share a small fixed-basis Flex owner. Every dirty entry must belong to the disjoint
owner partition, so the batch can publish those slots atomically without promoting
their common ancestor to the root. Root owners and missing allocation certificates
remain ineligible for this proof.
Surface keeps the candidate's computed owner style, renders its complete spans,
and recomposes proven unchanged enclosing paint instead of copying old local
properties. Border changes use the owner reflow renderer to rebuild internal roles;
the exact footprint, parent-slot, overflow and outside-complement checks still
authorize publication. Intrinsic or content-box border growth, unproved enclosing
surface properties and changed allocations retain the ordinary fallback when no
stable enclosing owner can be proved. Typography changes preserve the viewport
dependency index because font sizes contain no viewport expressions.
Owner-scoped output uses the integral local patch directly when the published
generation has no fractional pixel spaces. The raw allocation replay is kept
only for generations whose sibling remainder requires it.
Producer-only paint-origin carriers remain in the local fragment ledger and raw
allocation copy, but are stripped at the Ebox/Ebox publication publication boundary. Ebox publication then
compares only public text properties and can retain unchanged runs.
Interaction candidates retain their source topology proof across the
declarative preparation boundary; source-state overlays are not recomputed by
the subsequent runtime lowering pass.

Overlapping replacements resolve intermediate nodes from the nearest candidate
ancestor before merging descendant writes. Copying an intermediate path from the
committed tree would overwrite that ancestor's sibling changes. The lookup is
limited to affected paths and shares unchanged subtrees; rejection retains the
published generation and focus.

Range writes resolve ancestors before descendants, independent of recording
order. Descendant addresses resolve through the current candidate parent; a
removed descendant is absorbed. Range deltas describe affected payloads; both
owners and payload nodes are indexed from the final path-copy trace because a
descendant update may have copied them again.
Broad index reconstruction also receives the final source preorder, including
insertions and removals. Both preparation paths publish one matching tree and
index generation.

Runtime identity transfer preserves node and region identity, but does not copy
child-sequence coordinates. Those coordinates belong to a particular parent
tree and are resolved or indexed again after keyed insertion and reordering.
Tree and Range replacements share one sibling identity matcher.
Sibling reconciliation matches author keys first, then matching source identity
for unkeyed nodes. Positional fallback excludes identities retained elsewhere in
the new sibling list, preventing inserted content from taking a surviving node's
identity and invalidating nested Host updates.

Surface projection uses these reconciled runtime node identities as Ebox publication keys in
both complete and delta projections. It does not reconcile author keys or sibling
positions a second time. Inserting a status label therefore preserves the Ebox publication
objects, style bindings and editable handles of retained following siblings.

## Patch order

Mounted rendering permits cached responsive subtrees. Their signatures include
the display context, relevant local and CSS viewport dimensions, containing
block height for dependent heights, intrinsic-measurement mode and node input.
A viewport-dependent declaration alone is not a reason to re-layout the branch.
Changed constraints select a different cache entry; unchanged branches retain
their output. Visible root portals still use fresh collection rather than
replaying a cached string without its composition dependencies.

Literal callback and native keymap values contribute opaque identity tokens to
render signatures. Their captured state and recursive prefix graphs are not
layout inputs. Source publication owns keymap snapshots; publishing a replacement
changes its token. A weak identity table keeps this bookkeeping from retaining
retired application callbacks.

Descendant text and dimension changes can reflow inside an unchanged allocated
owner. The owner keeps its identity, child topology, own layout declarations and
ancestor allocation; exact rendered extents, clipping and enclosing effects
still determine whether local publication is admissible. Interior paint roles
may change without invalidating that exterior. Geometry comparisons use exact
numeric equality, including integral floats, without a rounding tolerance.
The allocation certificate measures only the changed owner's published boundary.
Above it, the proof checks unchanged parent edges, layout inputs and ordered
children. Once the final owner output preserves its footprint, substitution
preserves each ancestor's allocation without rereading that ancestor's mounts
or remeasuring its text. Changed inputs still reject local publication.

A single prepared Box child-list replacement can also try that retained slot
when both nonempty child lists have the same cardinality. The owner keeps its
own layout inputs and ancestor allocation; static cascade preparation must
succeed, with no scrolling or layer dependency. Cardinality only selects the
candidate: the ordinary subtree renderer and exact footprint, parent-slot,
overflow, enclosing-property and outside-complement validators still authorize
publication. Changed descendants use their new region identities for local
role validation, while the removed spans retain their old identities. Surface
projects the object delta and publishes the spliced output through ordinary
scoped reconciliation; fixed-object coordinate batches cannot add or retire
these descendants. A changed exterior or missing proof keeps full rendering.

For fractional pixel output, the retained generation also keeps pre-quantization
layout text. An admitted owner patch uses that allocation and then quantizes the
composed physical rows, preserving preceding siblings' fractional remainder.
Raw and displayed text share character coordinates but have separate geometry
snapshots. Fragment roles and paint provenance survive width quantization and
are reused; unchanged ancestor allocation certificates are carried forward.
A paint-only update invalidates this raw output cache. Missing evidence keeps
the ordinary complete-render fallback, including scrolling owners.

The planner prefers `paint-patch`, then `span-patch`, then `owner-rerender`, and finally `root-rerender` when geometry or identity makes a smaller operation unsafe. The incremental adapter derives tentative owners from live generation facts; the pure patch port then receives only those artifacts and the immutable parent table. These names describe Ebox semantic owner scope; Ebox publication alone computes and executes the physical text/property diff. A patch must not silently widen its semantic scope. Reports preserve the Ebox strategy and planned scope while separately recording Ebox publication's actual surface operations and revision.

Selector-only changes can use an exact-coordinate empty Ebox publication batch after the
complete computed style closure proves no rendering changes and identity,
ancestry and display constraints match. They publish selector and interaction
state while retaining mounted objects, fragments, scroll content and layer
pixels. Any computed paint or geometry change follows ordinary planning.

Focus and pressed-state requests carry the already accepted root and source
generation. The interaction owner identifies the old and new targets; immutable
record and selector-view overlays update those local facts without rebuilding
relationships. Subject-local rules with identical computed styles prove that
descendant inheritance is unchanged. This admits a retained metadata commit;
relational rules, reactive style bindings and actual style effects use normal
preparation. Metadata commits reuse viewport dependencies and avoid speculative
layout planning. Their object attachment work never writes node keys into a
published node-id table.

Opt-in observation attributes elapsed time exclusively to source preparation,
style preparation, owner planning, layout, projection and remaining transaction
work. Incremental planning receives the observer callback through its existing
orchestration boundary; it does not own clocks or public report delivery. Normal
unobserved updates do not allocate timing callbacks.

Rebuilding a source index preserves selector subject tokens by source identity.
The topology token is retained only after comparing every identity, parent and
ordered child list. A focus/pressed-state fact alone therefore does not
invalidate the whole scoped cascade. Local style preparation reads the current
source generation, rather than subjects captured by older retained bindings;
equal computed styles retain identity so unchanged inheritance does not spread
the invalidation to descendants. Structural selectors and actual topology or
scope changes keep their full matching requirements. This still validates the
rebuilt tree; it does not claim constant-time interaction preparation.

If span, owner-scoped, formatting-context, or mixed local output declines, the producer rebuilds ordinary candidate state before rendering the complete root. Temporary coordinates, fragments, and paint layers from the declined attempt cannot authorize publication. The report retains the planned strategy and scope; `:projection-kind` is `nil` for this ordinary fallback. A planned mixed strategy therefore does not prove that computation stayed local.

## Strict retained viewport reflow

`viewport-reflow` is an explicit retained projection kind for a narrow, proof-driven viewport resize path. The planner may select it only when all of the following hold: the plan is one root-owned geometry `owner-rerender`; the old and candidate roots are the same retained root; no dirty entry changes children; the node-key set, region-id set, and parent table are unchanged; neither the old surface nor the current style environment requires cascade or inline-inheritance recomputation; there is no scroll state; the root has no visible-overflow scope; and the old surface has a non-empty retained node-object table. Width-only, height-only, and both-axis changes use the same proof. Style stability compares the current global stylesheet and the scopes resolved from the mounted source index against the published signature.

When selected, the candidate keeps the published Ebox topology and reuses the retained Ebox publication node-object subtree. The producer still reruns viewport-sensitive layout and materializes the new surface plan, and Ebox publication remains responsible for the scoped buffer diff, revision, stable identity, and atomic rollback. `viewport-reflow` must never be reported for a topology, cascade, inheritance, scroll, overflow, or display-signature change merely because the final text patch is small.

If any proof condition fails, the update uses the ordinary safe projection path. That fallback may do broader node projection and Ebox publication reconciliation, but it preserves the same output, identity, publication, and rollback contract. Tests in `tests/ebox-surface-tests.el` cover the retained width/height/both-axis path, each unsafe fallback trigger, and publication failure after candidate preparation.

## Layer composition

A declarative replacement wholly inside one retained absolute panel may reuse
the root plane's completed flow and other layer rasters, including an unanchored
root portal. The panel's children may change identity, count and layout; its
raster is rendered in the retained root content context before ordinary root
composition and wrapper rendering. Display context, containing geometry, layer
membership and stacking remain stable, and external anchor dependencies decline
reuse. Prior rasters and records stay immutable. Ordinary object projection,
ownership reconstruction and the publication transaction still establish the
complete candidate, including newly created and removed children. The raster
proof is consumed by its source transition and does not survive signal-driven
producer reevaluation.
Metadata-only publication retains the current composition ledger. Its runtime
revision advances only when the accepted update proves unchanged layout output;
native focus/pressed publication includes that revision in its rollback state.
Later materialization copies a shared ledger's hash spine before writing.
When styles require complete projection, the same computed-effect classifier
checks the full styled closure before admitting raster reuse, including effects
outside the changed source subtree. A missing or stale ledger declines reuse.
Source changes already outside one retained absolute panel reject that deferred
request before complete effect classification. Metadata with unresolved styles
remains undecided until the same full computed closure is checked.

A positioned subtree paints on its containing plane's physical text-row grid.
The existing placement traversal checks every descendant's resolved canonical
font height, including ordinary Text and Box nodes, against the host's height
before producing layer records. Larger fonts reject the candidate before live
publication; smaller fonts and same-height bold do not widen the grid. Flow
outside positioned subtrees retains its independent font layout. This proof
uses canonical font facts and does not certify caller-supplied face properties
or per-glyph fontset fallbacks. Built-in UI marks must also fit the measured
physical row in the user's font configuration.

The public geometry boundary is `ebox-region-update-geometry` and
`ebox-region-geometry`. These functions expose only Box-owned positioning,
size, bounds, and stacking facts through the existing retained candidate and
publication transaction. They do not add a second geometry store: the caller's
property list is validated, copied into one candidate, classified as geometry,
and published with the same scoped planning and rollback rules as an ordinary
`ebox-region-update`. The query returns a detached view of the committed Box
facts and registered style initials.

Ebox does not interpret those facts as a draggable window. Its `:drag` keymap
capability remains an input primitive that reports gesture phases and deltas;
callbacks or ETAF behaviors decide whether a delta changes `:left`, `:top`,
`:width`, or `:height`. Resize handles, constraints, maximize/minimize state,
focus order, and desktop window policy remain above Ebox. Padding, margin,
border, and other style changes continue through the general region-update
route rather than widening this typed position/size/layer boundary.

Layer placements carry original row text and pixel source intervals until the
compositor resolves occlusion. Unchanged row signatures reuse their accepted
output without extracting child strings; changed rows cut only uncovered
intervals from original sources. This avoids clipping every flow child before
the visibility decision and clipping those intermediate strings a second time.
Normal flow, relative offsets, portal placement and z ordering share this path.

Prepared planes may delegate their numeric occlusion sweep to the optional
native module. Each plane owns bounded scratch storage; sparse placement
changes refresh a numeric cache and the module returns visible source intervals
for damaged rows into a reusable vector. It owns no Lisp values, source strings,
buffer state or publication baseline. Rejection refreshes that cache from the
restored source records before reuse. Capacity or exact-coordinate limits select
the ordinary compositor. Glyph clipping and property materialization retain the
same Emacs implementation. Fixed display-space boundaries allow one string join;
unproved shaping boundaries retain the ordinary measured join, including its
zero-pixel separators for equal replacement runs.
Ordinary layer rendering uses the same kernel for changed rows with
candidate-owned scratch storage, released at the end of that evaluation rather
than deferred to GC; it never mutates the published composition ledger.
Unchanged rows retain their existing signature-based reuse.

When flow children have no relative movement and every positioned record is
above the flow's z order, completed flow rows form the bottom composition plane.
They supply anchor geometry directly and remain intact outside overlay coverage.
Relative movement and interleaved z orders use the ordinary per-owner composition.

Prepared geometry compiles stable containing-plane routes into retained raster
pieces, numeric placement slots, document order and reusable damage-row storage.
A translation updates only the target primitives and propagates changed rows
through prepared enclosing wrappers. Cold compilation resolves fixed chrome and
finite property transformations, including clipping and inherited wrapper paint.
The warm path decorates only damaged rows with those instructions and retains
all other accepted rows. Panel raster preparation is independent of position and
stacking; ordinary candidates also reuse that raster's split rows, measured width
and ownership pieces when its rendered text is unchanged.

The prepared publisher remains inside the existing surface authority. It reuses
two mount/index banks, callback bindings, reports and rollback storage. Cold
ownership tokens map raster slices directly to retained objects and ancestors;
changed rows refresh visible intervals in a fixed mount pool while unchanged row
intervals shift by their retained character offsets. Each measured owner/tag
combination initially reserves twice its known raster intervals plus one;
sparse chrome does not inherit another role's footprint or a per-layer allowance.
Owners without raster evidence retain their conservative cold reservation.
Exhausted pools double up to the common bound while retaining every existing
mount; each fill retries only after capacity has increased.
Publication receives known old/new damage ranges, edits them from the end, and
updates only their property
runs. Private ownership tokens are stripped before publication. Source preparation owns separate private declaration and runtime numeric
cells, which each stage synchronizes explicitly. Snapshot export freezes these
cells; a subsequent general publication reads the latest declarations and
rebuilds invalidated fragment proofs. External buffer hooks still run, and their
unexpected writes reject the publication.

When an ordinary update retains topology but replaces authoritative mount
records, frame refresh adopts that accepted generation. An expanded interval
pool replaces only a current frame and must contain its complete previous pool.
That replacement belongs to the shared scene, so every prepared target uses the
same frame after either acceptance or rollback.
The ordinary publisher's accepted mounts remain the rollback baseline even
when they differ from the compiled pool. Initial preparation still requires
every authoritative mount; topology or generation failure cannot authorize
pool reuse.

Eligible targets in one containing plane share one prepared canvas: its mounted
scene, mount pool, publication frame and interaction capability. Preparing
another target in that plane binds only its scalar source cells, value storage
and callbacks; another prepared target does not restart the composition. A
mounted surface keeps the canvases of several planes at once in a per-buffer
cache, newest first. A member set reuses only the canvas compiled for its own
containing plane, because another canvas could bind a shared ancestor as the
boundary and then fail to replay its pixels; members that need another plane
are left for their own cohort. Validity is cache membership plus the shared
state, style and display checks, and the most recently used canvas serves
interaction publishing and native focus. Source-handle changes refresh that
capability in the cold plane. An ordinary publication invalidates operation bindings, while a
publication-owned topology token can preserve compiled resources. The token is
retained only for an explicit nonstructural dirty classification with no created,
removed or moved publication objects. A later preparation refreshes raster rows
and bindings without comparing the complete node tree. Matching fixed wrapper
configuration reuses its property transforms. Preparation records only the
property schema a wrapper can encounter (program primitives, the enclosed
route, surface properties and paint decorations); a primitive property
combination compiles when a dirty row first presents it, and a combination
outside the schema declines the prepared operation. Exact role instructions include initially occluded
rasters, so exposing those pixels can reuse the mount pool. The frame adopts the
accepted revision and client state while generic mounts remain authoritative
until the next atomic prepared publication. Structural or unsupported changes
use fresh preparation.

Cold compilation reads the state's layer composition ledger, and a prepared
publication clears it.  A canvas can therefore be compiled only while every
containing plane between its anchor and the root still has a recorded
composition, and one publication has one writer, so alternate writes to two
canvases in the same generation are not supported.  Hang anchors directly on
the root plane, or on a plane the ledger records, and publish one region at a
time.

This path compiles translation and stacking for fixed planes. A scroll viewport
inside a retained raster moves with its owner without changing its content-relative
offset or producer. An active scroll viewport on the containing-plane route still
declines because its offset and clipping do not have compiled wrapper instructions.
Anchors and portals retain their separate admission requirements. Primitive clipping
and native text writes still allocate output-related artifacts; prepared execution
alone does not establish allocation or latency acceptance.

Root portals admit a narrower content-only cohort when the mounted root's final
composition retains every visible portal and no anchor dependency exists.
Cold admission protects each portal, its descendants and logical ancestors;
both the member and its nearest retained raster owner must lie outside that
set. The root program retains portal records as fixed occlusion and input
owners while independent content updates propagate their changed rows.
Unsupported member specifications retain their member index, so a framework
can remove them and prepare the independent content. This proof is cached only
under the current binding capability; ordinary publication invalidates it and
all operations. Public geometry preparation does not admit or reuse this
content-only scene for placement changes.

The mixed prepared-update cohort cold-binds source cells and the retained
primitive owning each member's pixels; preparation renders nothing. Sparse
changed-member indices feed one retained frame. Admission proves every member
against the chosen routes and crop before a cold scene binds
source cells or allocates interaction, mount and publication-frame storage.
The same member proofs run when reusing a scene; a rejection retains its
member/property diagnostic without installing a partial session. Duplicate Host
specifications share one source-record binding; stage snapshots caller values before hooks, and
a rejected frame restores every source and caller cell. After staging, apply
recomputes the complete cascade of changed style members and their descendants,
snapshotting each rewritten node so rollback restores its previous projection.
Prepared numeric units have separate source and runtime storage. Each stage
explicitly writes both, because cascade application may replace a node's unit
value; rollback restores the source number, previous projected value and reusable
runtime unit together. It then renders each changed member's nearest record owner
with the ordinary renderer in its host content context, so incremental and full
output share one box implementation. Render-signature and viewport memo tables
belong to the shared scene, while cohorts own their invocation storage. Every
cohort invalidates changed and restyled nodes and their ancestor paths before
rendering and after rejection. Direct prepared geometry also invalidates its
changed path on acceptance. Unrelated nodes retain their memoized facts, and
operations sharing a raster see the same current source signatures. A flow owner replaces only rows whose pixels changed and
must keep its rows and pixel intervals. An absolute owner does not participate
in flow, so a resize or row change reuses its record slots, appends records and
hides surplus ones. A fixed sparse batch saves each record once, so paint, Text,
resize and multiple placements share complete pixel rollback.

A boundary re-render uses a private scroll-state bank. Its initial metadata includes
completed idle prefix work, and render-time prefetch changes stay isolated. The
existing prepared publication stages that bank, the buffer's scroll-region inventory
and matching global entries together with its pixels; rejection restores all three
and any scroll offsets clamped during rendering. Accepted frames reuse the retired
bank and refresh prefetch scheduling after publication. Thus paint or size changes
can replace scroll viewport metadata and producers while unrelated panes keep their
offsets. Placement-only frames leave scroll metadata untouched. Boundaries with
active scroll state use ordinary raster rendering for resize: pixel-only elastic
synthesis does not establish a matching viewport or producer. An underfilled
boundary may learn an elastic response only while every size-validation render
also remains without scroll state. Trial renders use isolated scroll metadata and
restore any clamped node offsets; a remembered pixel model from another binding
does not serve as this proof.

A pure size change of an absolute owner may skip that render. `ebox-elastic`
learns the owner's size response from two ordinary renders: a width change
whose rows differ only by one fixed pixel space per row, or two equal halves
around a centered child, and a height change that inserts copies of one
filler row between a fixed prefix and suffix while renumbering the rows of
the affected content cell. The learned model is verified by trial renders at
the containing plane's limits and the node's declared minimum and maximum
sizes, and each replay first checks that the retained rows still have the
learned shape: property-free text, every other `display` value and the pixel
widths of the fixed segments, so font, paint and content changes fall back to
the ordinary render, which teaches the model again. Replays produce the same
rows as the renderer, including the odd pixel of a centered title, so
`tests/ebox-prepared-resize-tests.el` compares each result with a fresh render.
Flow owners, clipped or non-integral sizes and changes that combine size
with another raster value keep the ordinary render.

Both learning samples must materialize exactly their declared row heights.
Min/max clamping or content-box decoration can break that correspondence;
those samples keep the ordinary renderer's result and do not create a model
whose row indices would refer to absent shapes.

Class variants compile to the existing source token grammar and a private
selector view. Bindings resolve canonical query entries by opaque source handle,
so a scroll projection's copied runtime node retains the same source/subject
identity. Reusing that canonical entry also avoids duplicate class candidates.
Candidate indexes contain the finite class superset; ECSS always
matches the current subject. Any rule/scope that observes a changing token is
rejected, so several Hosts cannot jointly activate an unproved relational rule.
Native focus/active uses the same private source/subject cells and fixed state
journals. With no dependent state selectors or dynamic style evaluators, press,
focus and release publish metadata through the retained frame without replacing
pixels or mount indexes. The report and mount banks advance independently, so
metadata between geometry updates cannot overwrite the live rollback index.

Prepared source records preserve exact opaque handles while an immutable index
overlay selects the new private record. Operation validity compares record
identity. This keeps retained tree/index pairs and previously exported snapshots
resolvable through focus/active metadata and later ordinary candidate creation.
Prepared paint changes defer general computed-style rebuilding: a stale flag
blocks ordinary metadata, native, scoped, viewport-no-op and retained-scroll shortcuts;
the next private candidate recomputes inherited styles, retaining binding keys
and clearing the flag only in that candidate's accepted state.

## Retained scroll window

Cached scroll intents reuse the published cascade, viewport axes and unchanged
runtime indexes when the visible window and display context are proven stable.
Chrome-free roots join cached rendered lines directly; layered or chrome-bearing
roots may reuse their complete composed content and render only the wrapper.
Pure root offset changes preserve already composed portal and anchor content.
Style, placement, content and display-context changes must invalidate that proof.

Proved scroll-only changes build a complete candidate from the published state
and a local immutable index delta, bypassing general declarative preparation.
Surface stages rich replacement text and exact old/new character ranges, then
returns an authenticated Ebox publication commit batch with complete target mount specs;
it does not build a surface plan. Equal text lengths never authorize reuse of
old mounts: newly visible rows may have different owners and interaction tags.
Owner resolution can reuse a private cache while its topology and Ebox publication object
indexes remain valid. Attribute updates and layout reflow retain their own
preparation paths; only terminal publication and rollback are shared.

A nested owner can replace its viewport within a proven unchanged allocation,
without rendering unrelated siblings. With one unchanged root scroll ancestor,
the update must also patch that ancestor's retained content, ownership membership
and line indexes, and rebind its producer to the candidate tree. Cached-content
coordinates and mounted-buffer coordinates require separate proofs. Unsupported
ancestor chains, partial visibility and failed footprint or wrapper proofs retain
the ordinary fallback.

An ordinary owner batch can combine grouped owners outside scroll boxes with
content owners inside retained scroll windows. Each cached owner uses the
ordinary span/grouped proof in cache coordinates, after proving its scroll
identity, unchanged window and disjoint scroll dependencies in both trees.
Cache planning may narrow the mounted owner partition, but cannot widen it.
When hidden content lifts a provisional plan to the root, dirty entries can
instead form proven scroll partitions and disjoint grouped row owners. An
unresolved outside owner retains the ordinary root fallback.
Cached owners rebuild their own properties and recompose proved unchanged
enclosing paint; caches do not supply the mounted paint baseline required for
property transport. The owner proof retains the changed keys needed to verify
its Flex allocation.
Surface validates and composes disjoint replacements per cache, regenerates
the changed rendered content lines and their indexes, then validates every
visible replacement together in mounted coordinates. Fully hidden owners
change only the proven cache. Cache and buffer changes commit or roll back
together; missing identities, incomplete owner evidence and nested cache
chains retain the complete fallback. Complete layout binds scroll metadata
and lazy producers back to its canonical runtime after rendering slot-sized
copies, so the following update can prove their identity exactly.

Classify cache hits before staging. A true prefix miss owns a copied target
subtree and ancestor path, private indexes and registries, copied cache lines and
freshly rebound producers. A producer must not mutate a published continuation
before Ebox publication commits. This isolation can rebuild the target prefix on a miss;
cached-hit timings do not describe that cost.

The prepared viewport batch is consumed once inside the existing scoped Ebox publication
transaction. Subsequent signal-driven evaluation uses the current committed
source and ordinary projection. A proof miss chooses the ordinary path before
publication; a publication error propagates through rollback without retrying
through another renderer. General preparation and surface-plan counters in the
shared evaluator verify the bypass separately from Ebox publication bookkeeping and buffer
write time; this path does not establish constant cost in total object count.

Native frame publication carries complete scroll producers keyed by their owning
regions, including sibling and nested containers. The retained evaluation tree
collects final layout uses, excluding intrinsic and Flex/Grid measurement probes.
Each producer retains its full content, visible height and effective offset;
unchanged content plans can be reused independently. Ebox installs the collection
into its ordinary scroll state and normalizes offsets through candidate path copies.
Switching back from an ordinary publication rebuilds the native source baseline.
Native producers currently require top alignment and no container chrome or surface
template; unsupported geometry uses Elisp before publication.

Scroll publication still goes through Ebox publication and the Ebox participant. Rejection
preserves the old text, properties, offsets, raw and rendered caches, source
nodes, indexes, objects, mounts and report. `make test` covers independent nested
owners, rejected removal, offset clamping after content shrinks and unmount
cleanup. The playground scroll evaluator checks fresh-render parity and
distinguishes cached motion from actual prefix extension.

## Identity and coordinates

Public Host bounds trim structural line separators from the publication mount
extent. Those separators remain publisher bookkeeping, but do not become the
first Host position used by focus or native input callers. Interior gaps still
belong to the enclosing numeric span; no consumer reconstructs mount ownership.

Keys are local to a sibling collection. Declarative source trees never own live Ebox publication objects, markers, or buffer coordinates. A live logical `:id` resolves through `ebox-region-resolve` to an opaque handle tied to one Ebox publication surface object; mounting the same source in two buffers therefore yields distinct handles. Region and host-ref positions are generation-bound; after a buffer mutation, callers must obtain fresh positions from the public accessor. Buffer markers, display spans, and text properties are publication facts, not source-tree identity.

Explicit region-update batches keep a sparse composition ledger keyed by retained node identity. Each write copies and mutates only its owner subtree; one final composition pass copies each affected ancestor once and overlays nested replacements onto the latest staged descendants. Proven local content and size batches keep untouched published branches shared through preparation. Other inputs isolate the composed root once before rendering, while proof misses and publication failures retain the ordinary safe fallback and rollback.

Native activation and optional interaction navigation resolve declaring keymap
owners from the committed surface and paint ancestry. Explicit nil stops inherited
activation. They keep no activation target registry; inaccessible, invisible
and structural text cannot become activation targets. Commands run only after
ownership validation, and callback errors remain observable.

Logical focus has one buffer-local retained node owner. Public focus changes
reject active Ebox publication transactions; only publication's internal participant may
reconcile provisional focus and restore it on rollback. Accepted callbacks may
start a new focus operation, while read-only queries remain available.

Published source interaction facts supply tab order and disabled status. Source
indexes also maintain an exact hover-content declaration count with each record
delta; a buffer with none skips hover registration scans. Source
records keep authored states separate; subject construction derives `disabled` from the interaction fact.
Queries, cascade and incremental invalidation consume that same derived view;
rebinding retains raw authored states and invalidates subjects when disabled changes.
Mounted focus adds an immutable candidate projection to the source record;
callers cannot author that token. Focus requests are tied to their committed
base generation, so observer commits cannot replay an earlier request.
Candidate validation uses ECSS to check focused ancestry. Final rendering also
checks painted ownership; clipping clears retained focus and recomputes styles
using the same Ebox publication objects before a single accepted publication. Newly requested
inaccessible targets reject atomically. Pure inputs retain no mounted focus.
Pressed ownership uses the same immutable source interaction-state projection
and publication participant. Generated primary-button tracking sets `active`
before callbacks and clears it on completion; ordinary updates reconcile the
retained source identity and visibility. Selector queries and ECSS see the same
state as rendered paint, without a consumer state mirror. Activation consumes
the release and resolves its accepted native binding after clearing the state.
Hover state integration into the cascade remains pending.
A lazily built navigation vector and rank index are derived
once per publication, with visibility checked at use. Navigation does not
rescan and sort every Host on each key. New publication invalidates the derived
index. Source identity takes precedence over reused layout nodes; retained
node identity plus a matching non-nil sibling key bridges fresh DSL handles.
Region updates compare source interaction facts as well as native projection,
so tab order or a disabled node's replacement keymap cannot become a false no-op.

The rollback-capable Ebox participant promotes focus together with the candidate
and restores it on rejection. Ebox publication restores native view markers at final accept,
so Ebox reapplies the chosen point in its contained after-commit callback only
if that candidate is still current. Manual point movement preserves a clamped
numeric position. Unmount clears focus and the derived index. This state does
not own application values or select windows.

The mounted buffer mode owns the shared navigation and activation bindings.
Native generated activation commands consult the live focus owner at point;
explicit position activation and mouse callbacks retain physical targeting.
Effective maps resolve through source ownership and ancestor nil barriers.
When the pressed cell's paint chain reaches no declaration, published keymap
ownership falls back to the node that published its snapshot, which covers
layout filler cells such as flex gaps, padding and clipped trailing cells.
A dynamic dispatch guard prevents a generated command from reentering target
selection after `ebox-activate` has already chosen the committed command.
Custom native bindings remain native commands. No consumer focus or input
mode is needed to activate overlapping controls correctly.

The native input boundary holds only the current surface and retained target
identity for the duration of a reader call. It reuses the committed ownership
index and focus visibility checks before accepting a result and restoring focus.
It adds no target registry, editing state or text writer. Native Emacs owns the
input session; consumers apply accepted values after the boundary returns.

Primary-button drag tracking also lives in Ebox. Generated keymaps retain the
declaring node at press time and reuse the same source identity/key resolution
as focus when publication moves it. A press whose published keymap names no
live owner is not an Ebox gesture: tracking leaves it and its release to
Emacs' ordinary mouse handling instead of failing the command. The native tracking loop delivers one
start, changed motion positions, and one terminal end/cancel callback. It has
no application position state, target registry or publication path of its own.
Each consumer callback updates through ordinary public rendering operations.
The native reader periodically checks target and window lifetime while idle
and rechecks after reads that may run timers. One input round drains at most
64 already pending same-window motions without waiting, then publishes only
the latest position. A release, press, cancel, unrelated event or window exit
ends that drain; its event stays ahead of later input. A gesture-local check
reuses the resolved owner while the surface revision and client-state identity
are unchanged; buffer accessibility and native visibility are checked separately.
Terminal delivery happens once, including locked gestures whose final release
still needs consuming. Unrelated input returns to Emacs's command loop.

Prepared geometry compiles only declared interaction dependencies. Current
focus and pressed owners and all hover-content targets bind directly to
publication objects during preparation, including occluded hover targets.
Each publication resolves those bindings from its output mount intervals;
it does not rebuild navigation or walk the Box tree. Logical focus follows
its first painted position while manual point remains independent, and
occlusion clears focus/pressed selector facts as well as buffer ownership.
Four cold selector variants retain the geometry provider's private numeric
cells without mutating exported source records. Style comparison admits a
variant only when clearing an interaction state needs no new painted output;
other occluding updates decline before publication. Hover bounds and rollback
storage are retained, and final focus placement runs after native view restoration.

## Verification

Every update path must prove:

- exact visible text and properties after publication;
- stable keyed identity when siblings reorder;
- no stale candidate data after rollback;
- bounded patch scope when a local update is possible;
- correct fallback behavior when native reflow is unavailable.

Use `tests/ebox-commit-tests.el`, `tests/ebox-core-render-tests.el`, and `tests/ebox-grid-tests.el` for focused update coverage. `tests/ebox-package-tests.el` guards the live-buffer publication boundary; then run `make check`.
