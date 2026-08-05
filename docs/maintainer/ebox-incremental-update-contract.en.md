# Ebox incremental update contract

This document defines the low-level publication contract. It is independent of ETAF application state and must remain true for direct Ebox callers and higher-level packages alike.

## Ownership

1. The caller owns the fresh source tree.
2. `ebox-tree.el` owns identity, keys, traversal, and snapshots.
3. `ebox-style.el`, `ebox-measure.el`, and the layout modules own normalization, measurement, and geometry.
4. `ebox-incremental.el` owns dirty classification, patch planning, candidate publication, and update reports.
5. `ebox-buffer-backend.el` is the only owner of text-property and buffer mutation.

No layer may infer application state from visible buffer text. No public caller may mutate a published tree in place.

## Commit lifecycle

```text
fresh root
  -> validate and normalize
  -> reconcile keys and identity
  -> measure/layout candidate
  -> classify dirty owners
  -> render candidate spans
  -> publish atomically
  -> refresh snapshots and report
```

The candidate is either fully published or discarded. A failed candidate preserves the previous buffer text, properties, runtime identity, scroll state, and last successful report.

## Patch order

The planner prefers `paint-patch`, then `span-patch`, then `owner-rerender`, and finally `root-rerender` when geometry or identity makes a smaller operation unsafe. A patch must not silently widen its scope; the report records the selected strategy, dirty keys, owners, and patch operations.

## Identity and coordinates

Keys are local to a sibling collection. Region and host-ref positions are generation-bound; after a buffer mutation, callers must obtain fresh positions from the public accessor. Buffer markers, display spans, and text properties are backend facts, not source-tree identity.

## Verification

Every update path must prove:

- exact visible text and properties after publication;
- stable keyed identity when siblings reorder;
- no stale candidate data after rollback;
- bounded patch scope when a local update is possible;
- correct fallback behavior when native reflow is unavailable.

Use `tests/ebox-commit-tests.el`, `tests/ebox-core-render-tests.el`, and `tests/ebox-grid-tests.el` for focused coverage, then run `make check`.
