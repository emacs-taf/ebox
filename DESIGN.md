# Ebox design

Ebox is the low-level spatial rendering engine. Its job is to turn a declarative node tree into measured layout fragments and a generic TP surface plan. It is deliberately smaller than an application framework.

## Design principles

- One source tree, one style normalizer, one layout pipeline, one buffer owner.
- A public node is data; rendering and mutation happen only at explicit entry points.
- Stable identity comes from node identity and explicit keys, never from visible text or selector strings.
- Layout changes are measured before publication; a failed candidate preserves the previous buffer state.
- The native module is an optional accelerator with an exact Elisp fallback.
- New abstractions must remove duplication or make an existing public workflow simpler.
- Public property schema, ECSS metadata, and used engine projection are derived from one property definition record.
- Cross-package framework integration is an additive versioned provider; consumer selection and fallback policy remain outside Ebox.

## Pipeline

```text
node tree
  -> normalized style
  -> measured formatting context
  -> layout fragments and snapshot
  -> render context
  -> pure TP surface plan
```

The owners are `ebox-child-range.el` for immutable child-sequence and key indexes, `ebox-tree.el` for Ebox identity and traversal, `ebox-style.el` for style semantics, `ebox-measure.el` for display-sensitive measurement, `ebox-layout.el`/`ebox-flex.el`/`ebox-grid.el` for geometry, `ebox-fragment.el` for fragment facts, `ebox-render-context.el` for the candidate/materialization input port, `ebox-patch-plan.el` for pure operation-antichain artifacts, `ebox-surface.el` for pure TP plan projection and retained publication, and `ebox-incremental.el` for dirty classification and live-fact adaptation. `ebox-layout.el` never loads or calls the surface/TP layer; the facade wires surface operations into its validated render-context port. The patch planner never reads a buffer or surface; its incremental adapter supplies immutable parent facts and tentative operations. `ebox-buffer-backend.el` only builds and reshapes propertized render strings; all public live buffer publication routes through the TP surface boundary.

## Public boundary

Use the functions and properties in `docs/user/ebox-api-reference.en.md`; the facade inventory is `ebox-public-api`. Do not call `ebox--*` names from an application or a sibling package. Higher-level Component, reactive, behavior, data, and control concepts belong to ETAF.

## Layout scope

Ebox supports explicit `px`, `%`, `vw`, `vh`, `ch`, and `lh` dimensions, padding, margins, borders, colors, overflow, wrapping, row/column/flex formatting, and Grid tracks including fixed, fractional, implicit, gap, placement, span, and alignment behavior. The public typography subset is `:font-family`, CSS-reference-pixel `:font-size`, `:font-weight`, and `:font-style`; `:font-slant` is only an exact parse-time alias of `:font-style`. Emacs faces and text properties belong to the final adapter and are not Ebox author properties. CSS compatibility is intentionally partial: absolute positioning, z-index, shadows, border radius, full browser typography, and browser-level bidi are outside this package.

## Size composition

`ebox-size.el` owns pure length validation, dependency discovery, and resolution
to fractional pixels, plus a pure cumulative quantization helper used at the
display boundaries chosen by layout. Its context contains measured viewport axes, the
property's percentage reference, zero-glyph advance, and line height. It does
not read windows or nodes, evaluate arbitrary Lisp, choose property defaults,
or publish buffers. This keeps unit arithmetic reusable across normal, Flex,
Grid, spacing, and border geometry.

The author format is `(unit number)` and the composable functions are `calc`,
`min`, `max`, and `clamp`. Property schemas own allowed units, keywords, and
range rules. The [shared unit-constraint table](docs/user/ebox-user-guide.en.md#size-unit-constraints)
is the author contract: inline geometry, block geometry, and border paint have
distinct unit domains. Validation traverses every function branch and track
operand; Flex basis uses its parent main axis. Invalid unit combinations fail
during construction, before layout or display.

Layout supplies containing-block and font measurements and resolves
intrinsic/automatic sizes. `fit-content` is a bare keyword only. Removed bare
lengths, singleton pixel lists, viewport keywords, and `contain` have no
compatibility execution path.

Missing reference measurements defer resolution rather than becoming zero.
Intermediate arithmetic keeps fractions until the formatting/display boundary.
The buffer backend materializes block geometry in whole lines, matching the
restricted block-unit contract. An empty Box contributes zero automatic
content height; explicit height, padding, or borders supply any reserved extent.

## Verification rule

Every behavior change needs a focused ERT test and a fresh `make check`. Changes to native source also require `make native-rust-tests`; changes to docs or the active file set require `make docs-contract-tests`.
