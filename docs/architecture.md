# Ebox incremental update contract

This document defines the low-level publication contract. It is independent of ETAF application state and must remain true for direct Ebox callers and higher-level packages alike.

## Ownership

1. The caller owns the fresh source tree.
2. `ebox-tree.el` owns identity, keys, traversal, and snapshots.
3. `ebox-style.el`, `ebox-measure.el`, and the layout modules own normalization, measurement, and geometry.
4. `ebox-incremental.el` owns dirty classification, live-fact adaptation, pure declarative commit preparation, and Ebox report semantics; `ebox-patch-plan.el` reduces tentative operations using only immutable parent facts.
5. `ebox-surface.el` projects retained candidates and joins Ebox runtime-state publication to the TP transaction.
6. TP owns generic retained-surface reconciliation, mount/index state, all live buffer diff execution, revision changes, and rollback for initial mount, declarative commit, handle update, viewport/theme update, and scroll update.
7. `ebox-buffer-backend.el` only builds and reshapes propertized render strings. It does not own live markers or a buffer mutation executor.

No layer may infer application state from visible buffer text. No public caller may mutate a published tree in place. Every public live-publication route, including `ebox-render-to-buffer`, its `ebox-display-buffer` display wrapper, and commit/update entry points, uses a retained TP surface; the public facade exposes no erase-and-evaluate-body buffer writer.

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
exports preserve target facts; scope caches are keyed by candidate source index.
Author ownership is therefore independent of physical parentage and live buffer
coordinates. ECSS continues to own structural matching and inheritance.

Selector subjects store immutable local metadata and stable parent/child keys.
Each source generation resolves those keys through its own persistent index and
ECSS subject adapter. Candidate path copying updates affected subjects without
repairing backreferences in unchanged children or mutating the published tree.
Query entries and lookup tables may remain lazy; style evaluation already has
coherent candidate relationships and does not rebuild them merely for a query cache.

Cascade reuse compares mounting source identity, rules, target membership and
inherited values. For subject-local selectors, each binding retains its own
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
bindings. Retaining enclosing native keymaps uses TP's property equality policy:
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

Within one native frame, completed layout requests are shared by source address
and exact constraints, including both viewport axes, intrinsic mode, size overrides
and scroll-effect mode. Flex measurement phases can reuse the same completed
subtree without repeating its layout. This memo belongs to the immutable frame
transaction and is discarded afterward. Each caller retains its own use edge and
compares changes against its own previous result; final scroll ownership remains
distinct from measurement probes. Cross-frame reuse still uses source invalidation
and the retained evaluation tree.

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

```text
fresh root
  -> validate and normalize
  -> copy into surface-owned candidate state
  -> reconcile TP objects, keys, and Ebox identity
  -> measure/layout candidate
  -> classify dirty owners
  -> produce TP surface plan plus Ebox report base
  -> TP prepares and atomically publishes buffer changes
  -> Ebox transaction participant publishes matching runtime indexes/report
  -> retire superseded Ebox timers and warm the committed scroll state after success
```

The candidate is either fully published or discarded. A failed render, TP write, Ebox participant, or publication callback preserves the previous buffer text, properties, TP revision, Ebox runtime identity, scroll state, and last successful report. If the target buffer is killed during publication, teardown is authoritative and rollback never resurrects it.

Projection planning shares numeric TP mount snapshots across its local proofs.
This read view exists only during one planning pass and is discarded before TP
publishes coordinates. It neither replaces TP's authoritative mounts nor changes
the defensive snapshots returned by public Ebox queries.

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
Sibling reconciliation matches author keys first, then matching source identity
for unkeyed nodes. Positional fallback excludes identities retained elsewhere in
the new sibling list, preventing inserted content from taking a surviving node's
identity and invalidating nested Host updates.

Surface projection uses these reconciled runtime node identities as TP keys in
both complete and delta projections. It does not reconcile author keys or sibling
positions a second time. Inserting a status label therefore preserves the TP
objects, style bindings and editable handles of retained following siblings.

## Patch order

The planner prefers `paint-patch`, then `span-patch`, then `owner-rerender`, and finally `root-rerender` when geometry or identity makes a smaller operation unsafe. The incremental adapter derives tentative owners from live generation facts; the pure patch port then receives only those artifacts and the immutable parent table. These names describe Ebox semantic owner scope; TP alone computes and executes the physical text/property diff. A patch must not silently widen its semantic scope. Reports preserve the Ebox strategy and planned scope while separately recording TP's actual surface operations and revision.

If span, owner-scoped, formatting-context, or mixed local output declines, the producer rebuilds ordinary candidate state before rendering the complete root. Temporary coordinates, fragments, and paint layers from the declined attempt cannot authorize publication. The report retains the planned strategy and scope; `:projection-kind` is `nil` for this ordinary fallback. A planned mixed strategy therefore does not prove that computation stayed local.

## Strict retained viewport reflow

`viewport-reflow` is an explicit retained projection kind for a narrow, proof-driven viewport resize path. The planner may select it only when all of the following hold: the plan is one root-owned geometry `owner-rerender`; the old and candidate roots are the same retained root; no dirty entry changes children; the node-key set, region-id set, and parent table are unchanged; neither the old surface nor the current style environment requires cascade or inline-inheritance recomputation; there is no scroll state; the root has no visible-overflow scope; and the old surface has a non-empty retained node-object table. Width-only, height-only, and both-axis changes use the same proof. Style stability compares the current global stylesheet and the scopes resolved from the mounted source index against the published signature.

When selected, the candidate keeps the published Ebox topology and reuses the retained TP node-object subtree. The producer still reruns viewport-sensitive layout and materializes the new surface plan, and TP remains responsible for the scoped buffer diff, revision, stable identity, and atomic rollback. `viewport-reflow` must never be reported for a topology, cascade, inheritance, scroll, overflow, or display-signature change merely because the final text patch is small.

If any proof condition fails, the update uses the ordinary safe projection path. That fallback may do broader node projection and TP reconciliation, but it preserves the same output, identity, publication, and rollback contract. Tests in `tests/ebox-surface-tests.el` cover the retained width/height/both-axis path, each unsafe fallback trigger, and publication failure after candidate preparation.

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
returns an authenticated TP commit batch with complete target mount specs;
it does not build a surface plan. Equal text lengths never authorize reuse of
old mounts: newly visible rows may have different owners and interaction tags.
Owner resolution can reuse a private cache while its topology and TP object
indexes remain valid. Attribute updates and layout reflow retain their own
preparation paths; only terminal publication and rollback are shared.

A nested owner can replace its viewport within a proven unchanged allocation,
without rendering unrelated siblings. With one unchanged root scroll ancestor,
the update must also patch that ancestor's retained content, ownership membership
and line indexes, and rebind its producer to the candidate tree. Cached-content
coordinates and mounted-buffer coordinates require separate proofs. Unsupported
ancestor chains, partial visibility and failed footprint or wrapper proofs retain
the ordinary fallback.

Classify cache hits before staging. A true prefix miss owns a copied target
subtree and ancestor path, private indexes and registries, copied cache lines and
freshly rebound producers. A producer must not mutate a published continuation
before TP commits. This isolation can rebuild the target prefix on a miss;
cached-hit timings do not describe that cost.

The prepared viewport batch is consumed once inside the existing scoped TP
transaction. Subsequent signal-driven evaluation uses the current committed
source and ordinary projection. A proof miss chooses the ordinary path before
publication; a publication error propagates through rollback without retrying
through another renderer. General preparation and surface-plan counters in the
shared evaluator verify the bypass separately from TP bookkeeping and buffer
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

Scroll publication still goes through TP and the Ebox participant. Rejection
preserves the old text, properties, offsets, raw and rendered caches, source
nodes, indexes, objects, mounts and report. `make test` covers independent nested
owners, rejected removal, offset clamping after content shrinks and unmount
cleanup. The playground scroll evaluator checks fresh-render parity and
distinguishes cached motion from actual prefix extension.

## Identity and coordinates

Keys are local to a sibling collection. Declarative source trees never own live TP objects, markers, or buffer coordinates. A live logical `:id` resolves through `ebox-region-resolve` to an opaque handle tied to one TP surface object; mounting the same source in two buffers therefore yields distinct handles. Region and host-ref positions are generation-bound; after a buffer mutation, callers must obtain fresh positions from the public accessor. Buffer markers, display spans, and text properties are publication facts, not source-tree identity.

Native activation and optional interaction navigation resolve declaring keymap
owners from the committed surface and paint ancestry. Explicit nil stops inherited
activation. They keep no activation target registry; inaccessible, invisible
and structural text cannot become activation targets. Commands run only after
ownership validation, and callback errors remain observable.

Logical focus has one buffer-local retained node owner. Public focus changes
reject active TP transactions; only publication's internal participant may
reconcile provisional focus and restore it on rollback. Accepted callbacks may
start a new focus operation, while read-only queries remain available.

Published source interaction facts supply tab order and disabled status. Source
records keep authored states separate; subject construction derives `disabled` from the interaction fact.
Queries, cascade and incremental invalidation consume that same derived view;
rebinding retains raw authored states and invalidates subjects when disabled changes.
Mounted focus adds an immutable candidate projection to the source record;
callers cannot author that token. Focus requests are tied to their committed
base generation, so observer commits cannot replay an earlier request.
Candidate validation uses ECSS to check focused ancestry. Final rendering also
checks painted ownership; clipping clears retained focus and recomputes styles
using the same TP objects before a single accepted publication. Newly requested
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
and restores it on rejection. TP restores native view markers at final accept,
so Ebox reapplies the chosen point in its contained after-commit callback only
if that candidate is still current. Manual point movement preserves a clamped
numeric position. Unmount clears focus and the derived index. This state does
not own application values or select windows.

The mounted buffer mode owns the shared navigation and activation bindings.
Native generated activation commands consult the live focus owner at point;
explicit position activation and mouse callbacks retain physical targeting.
Effective maps resolve through source ownership and ancestor nil barriers.
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
as focus when publication moves it. The native tracking loop delivers one
start, changed motion positions, and one terminal end/cancel callback. It has
no application position state, target registry or publication path of its own.
Each consumer callback updates through ordinary public rendering operations.
The native reader periodically checks target and window lifetime while idle;
unrelated input returns to Emacs's command loop.

## Verification

Every update path must prove:

- exact visible text and properties after publication;
- stable keyed identity when siblings reorder;
- no stale candidate data after rollback;
- bounded patch scope when a local update is possible;
- correct fallback behavior when native reflow is unavailable.

Use `tests/ebox-commit-tests.el`, `tests/ebox-core-render-tests.el`, and `tests/ebox-grid-tests.el` for focused update coverage. `tests/ebox-package-tests.el` guards the live-buffer publication boundary; then run `make check`.
