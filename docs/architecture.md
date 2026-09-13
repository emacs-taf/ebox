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

Cascade reuse compares mounting source identity, rules, and target membership.
Metadata-only publication can retain lazy selector views; tree queries rebuild
stale views from current source facts before matching.

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

Native frame publication currently installs one complete scroll producer owned
by the actual root. Active nested scroll owners use the Elisp fallback before
TP publication: visible fragment spans alone cannot supply their full content,
effective offsets and independent scroll state. A loaded module therefore does
not imply native publication for every scroll topology.

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
Hover and pressed state integration into the cascade remains pending.
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

## Verification

Every update path must prove:

- exact visible text and properties after publication;
- stable keyed identity when siblings reorder;
- no stale candidate data after rollback;
- bounded patch scope when a local update is possible;
- correct fallback behavior when native reflow is unavailable.

Use `tests/ebox-commit-tests.el`, `tests/ebox-core-render-tests.el`, and `tests/ebox-grid-tests.el` for focused update coverage. `tests/ebox-package-tests.el` guards the live-buffer publication boundary; then run `make check`.
