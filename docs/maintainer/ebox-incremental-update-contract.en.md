# Ebox incremental update contract

This document defines the low-level publication contract. It is independent of ETAF application state and must remain true for direct Ebox callers and higher-level packages alike.

## Ownership

1. The caller owns the fresh source tree.
2. `ebox-tree.el` owns identity, keys, traversal, and snapshots.
3. `ebox-style.el`, `ebox-measure.el`, and the layout modules own normalization, measurement, and geometry.
4. `ebox-incremental.el` owns dirty classification, patch planning, pure declarative commit preparation, and Ebox report semantics.
5. `ebox-surface.el` projects retained candidates and joins Ebox runtime-state publication to the TP transaction.
6. TP owns generic retained-surface reconciliation, buffer diff execution, revision changes, and rollback for initial mount and declarative full-root commit.
7. `ebox-buffer-backend.el` owns Ebox marker/index primitives and the specialized local numeric region, viewport, and scroll publishers that have not yet crossed the local-update cutover.

No layer may infer application state from visible buffer text. No public caller may mutate a published tree in place.

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
  -> retire superseded markers and timers after success
```

The candidate is either fully published or discarded. A failed render, TP write, Ebox participant, or publication callback preserves the previous buffer text, properties, TP revision, Ebox runtime identity, scroll state, and last successful report. If the target buffer is killed during publication, teardown is authoritative and rollback never resurrects it.

## Patch order

The planner prefers `paint-patch`, then `span-patch`, then `owner-rerender`, and finally `root-rerender` when geometry or identity makes a smaller operation unsafe. A patch must not silently widen its semantic scope. Declarative full-root reports preserve that Ebox strategy and planned scope while separately recording TP's actual surface operations and revision.

## Identity and coordinates

Keys are local to a sibling collection. Declarative source trees never own live TP objects, markers, or buffer coordinates. A live logical `:id` resolves through `ebox-region-resolve` to an opaque handle tied to one TP surface object; mounting the same source in two buffers therefore yields distinct handles. Region and host-ref positions are generation-bound; after a buffer mutation, callers must obtain fresh positions from the public accessor. Buffer markers, display spans, and text properties are publication facts, not source-tree identity.

## Verification

Every update path must prove:

- exact visible text and properties after publication;
- stable keyed identity when siblings reorder;
- no stale candidate data after rollback;
- bounded patch scope when a local update is possible;
- correct fallback behavior when native reflow is unavailable.

Use `tests/ebox-commit-tests.el`, `tests/ebox-core-render-tests.el`, and `tests/ebox-grid-tests.el` for focused coverage, then run `make check`.
