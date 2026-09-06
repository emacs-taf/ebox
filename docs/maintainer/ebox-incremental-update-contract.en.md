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

`viewport-reflow` is an explicit retained projection kind for a narrow, proof-driven viewport resize path. The planner may select it only when all of the following hold: the plan is one root-owned geometry `owner-rerender`; the old and candidate roots are the same retained root; no dirty entry changes children; the node-key set, region-id set, and parent table are unchanged; neither the old surface nor the current style environment requires cascade or inline-inheritance recomputation; there is no scroll state; the root has no visible-overflow scope; and the old surface has a non-empty retained node-object table. Width-only, height-only, and both-axis changes use the same proof.

When selected, the candidate keeps the published Ebox topology and reuses the retained TP node-object subtree. The producer still reruns viewport-sensitive layout and materializes the new surface plan, and TP remains responsible for the scoped buffer diff, revision, stable identity, and atomic rollback. `viewport-reflow` must never be reported for a topology, cascade, inheritance, scroll, overflow, or display-signature change merely because the final text patch is small.

If any proof condition fails, the update uses the ordinary safe projection path. That fallback may do broader node projection and TP reconciliation, but it preserves the same output, identity, publication, and rollback contract. Tests in `tests/ebox-surface-tests.el` cover the retained width/height/both-axis path, each unsafe fallback trigger, and publication failure after candidate preparation.

## Retained scroll window

For a chrome-free root scroll owner whose cached rendered lines cover the
current visible window (the lazy prefix may remain incomplete),
the scroll patch joins the staged visible window directly instead of entering
the full candidate layout. It reuses the published cascade, viewport axes,
object maps, and descendant `region-box-table`; it only advances the scroll
offset and installs the root `ebox-scroll-window` property. The proof is
conservative: a cache miss, chrome, active style dependency, topology change,
or incomplete window falls back to the ordinary retained path. Scroll
publication still goes through TP and the Ebox participant, so a failure after
TP client-state publication restores text, offsets, indexes, objects, mounts,
and report together.

## Identity and coordinates

Keys are local to a sibling collection. Declarative source trees never own live TP objects, markers, or buffer coordinates. A live logical `:id` resolves through `ebox-region-resolve` to an opaque handle tied to one TP surface object; mounting the same source in two buffers therefore yields distinct handles. Region and host-ref positions are generation-bound; after a buffer mutation, callers must obtain fresh positions from the public accessor. Buffer markers, display spans, and text properties are publication facts, not source-tree identity.

## Verification

Every update path must prove:

- exact visible text and properties after publication;
- stable keyed identity when siblings reorder;
- no stale candidate data after rollback;
- bounded patch scope when a local update is possible;
- correct fallback behavior when native reflow is unavailable.

Use `tests/ebox-commit-tests.el`, `tests/ebox-core-render-tests.el`, and `tests/ebox-grid-tests.el` for focused update coverage. `tests/ebox-package-tests.el` guards the live-buffer publication boundary; then run `make check`.
