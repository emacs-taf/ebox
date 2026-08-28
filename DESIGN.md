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

The owners are `ebox-child-range.el` for immutable child-sequence and key indexes, `ebox-tree.el` for Ebox identity and traversal, `ebox-style.el` for style semantics, `ebox-measure.el` for display-sensitive measurement, `ebox-layout.el`/`ebox-flex.el`/`ebox-grid.el` for geometry, `ebox-fragment.el` for fragment facts, `ebox-surface.el` for pure TP plan projection and retained publication, and `ebox-incremental.el` for dirty-owner planning. `ebox-buffer-backend.el` only builds and reshapes propertized render strings; all public live buffer publication routes through the TP surface boundary.

## Public boundary

Use the functions and properties in `docs/user/ebox-api-reference.en.md`; the facade inventory is `ebox-public-api`. Do not call `ebox--*` names from an application or a sibling package. Higher-level Component, reactive, behavior, data, and control concepts belong to ETAF.

## Layout scope

Ebox supports column- and pixel-based horizontal dimensions, line-based vertical dimensions, padding, margins, pixel borders, colors, overflow, wrapping, row/column/flex formatting, and Grid tracks including fixed, fractional, implicit, gap, placement, span, and alignment behavior. The public typography subset is `:font-family`, CSS-reference-pixel `:font-size`, `:font-weight`, and `:font-style`; `:font-slant` is only an exact parse-time alias of `:font-style`. Emacs faces and text properties belong to the final adapter and are not Ebox author properties. CSS compatibility is intentionally partial: percentages, absolute positioning, z-index, shadows, border radius, full browser typography, and browser-level bidi are outside this package.

## Verification rule

Every behavior change needs a focused ERT test and a fresh `make check`. Changes to native source also require `make native-rust-tests`; changes to docs or the active file set require `make docs-contract-tests`.
