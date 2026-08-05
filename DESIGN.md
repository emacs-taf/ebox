# Ebox design

Ebox is the low-level spatial rendering engine. Its job is to turn a declarative node tree into measured layout fragments and a generic TP surface plan. It is deliberately smaller than an application framework.

## Design principles

- One source tree, one style normalizer, one layout pipeline, one buffer owner.
- A public node is data; rendering and mutation happen only at explicit entry points.
- Stable identity comes from node identity and explicit keys, never from visible text or selector strings.
- Layout changes are measured before publication; a failed candidate preserves the previous buffer state.
- The native module is an optional accelerator with an exact Elisp fallback.
- New abstractions must remove duplication or make an existing public workflow simpler.

## Pipeline

```text
node tree
  -> normalized style
  -> measured formatting context
  -> layout fragments and snapshot
  -> render context
  -> pure TP surface plan
```

The owners are `ebox-tree.el` for Ebox identity and traversal, `ebox-style.el` for style semantics, `ebox-measure.el` for display-sensitive measurement, `ebox-layout.el`/`ebox-flex.el`/`ebox-grid.el` for geometry, `ebox-fragment.el` for fragment facts, `ebox-surface.el` for pure TP plan projection, and `ebox-incremental.el` for dirty-owner planning. During the staged cutover, the existing Ebox buffer backend still publishes live public entry points; it is not used by the pure projector and will be removed when those entry points move to TP surfaces.

## Public boundary

Use `ebox-create`, `ebox-column`, `ebox-row`, `ebox-flex`, `ebox-grid`, `ebox-build`, `ebox-render`, `ebox-render-to-buffer`, `ebox-commit`, and selector entry points. Do not call `ebox--*` names from an application or a sibling package. Higher-level Component, reactive, behavior, data, and control concepts belong to ETAF.

## Layout scope

Ebox supports character and pixel dimensions, padding, margins, borders, colors, faces, overflow, wrapping, row/column/flex formatting, and Grid tracks including fixed, fractional, implicit, gap, placement, span, and alignment behavior. CSS compatibility is intentionally partial: browser cascade, percentages, absolute positioning, z-index, shadows, full typography, and browser-level bidi are outside this package.

## Verification rule

Every behavior change needs a focused ERT test and a fresh `make check`. Changes to native source also require `make native-rust-tests`; changes to docs or the active file set require `make docs-contract-tests`.
