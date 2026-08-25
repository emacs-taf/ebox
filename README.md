# Ebox

Ebox is a standalone, pixel-precise box and layout engine for Emacs. It provides the low-level rendering substrate used by the sibling [ETAF](../etaf/README.md) text-application framework. Ebox can also be used directly without Components, application state, or ETAF.

## Install and use

ECSS and TP are independent packages and may be installed in either order. Install both before Ebox, or let a package manager resolve Ebox's two declared dependencies. For sibling source checkouts, place all three directories on `load-path`:

```elisp
(add-to-list 'load-path "/path/to/github/ecss")
(add-to-list 'load-path "/path/to/github/tp")
(add-to-list 'load-path "/path/to/github/ebox")
(require 'ebox)

(ebox-render-to-buffer
 "*Ebox Example*"
 (ebox-column
  (ebox-create :content "Hello Ebox"
               :padding '(1 2)
               :border '((1) solid "#8A93A6")
               :color "#263244"
               :bgcolor "#F4F6FB")))
```

The public model is a tree of Ebox nodes. `ebox-create` builds a leaf or wrapper node; `ebox-column`, `ebox-row`, `ebox-flex`, and `ebox-grid` compose nodes; `ebox-render` materializes propertized text without publishing buffer state (using isolated pure materialization when no cascade/inheritance dependency requires a TP object tree); `ebox-render-to-buffer` mounts a retained TP surface; `ebox-display-buffer` displays that same retained-surface path; and `ebox-commit` atomically updates the mount from a fresh root tree. Ebox copies declarative input before assigning runtime identity, so one source tree may be mounted in multiple buffers without transferring ownership. It exposes no separate public macro that erases a live buffer and evaluates arbitrary body forms.

Framework integrations may wrap an entire input callback with `ebox-call-with-render-burst`, or pair `ebox-render-burst-begin` and `ebox-render-burst-end` under `unwind-protect`, so pre-commit view allocation and Ebox publication share one nested GC boundary.

Material child lists may contain `ebox-child-range` descriptors, and logical candidates update their base-bound addresses with `ebox-candidate-replace-range-ref`. Candidates may also replace the private mounted root with `ebox-candidate-replace-root`; the last root replacement absorbs descendant operations and never shares an address with `:host-ref`. Reports expose `:range-metrics`, framework participant diagnostics, and scroll finalization diagnostics as read-only snapshots.

CSS-like selector strings are compiled to ECSS's structured selector AST. Ebox supplies logical node relations and indexed candidates; ECSS is the only selector matcher and cascade engine for tree queries, rendered-buffer queries, and style rules.

## What belongs here

- box creation, padding, margins, borders, colors, faces, overflow, and text measurement;
- row, column, flex, and two-dimensional Grid layout;
- selectors, stable node identity, keyed reconciliation, buffer rendering, and incremental publication;
- optional Rust native reflow with an exact Elisp fallback;
- low-level Ebox DSL files and renderer-focused tests.

ETAF belongs in the sibling package. Install it separately when you need the unified View grammar, Components, reactive state, behaviors, Context, Data Controllers, or application lifecycle. The independent example packages are [ebox-playground](../ebox-playground/README.md) and [etaf-playground](../etaf-playground/README.md).

## Repository map

| Path | Responsibility |
| --- | --- |
| `ebox.el` | Public facade and package entry point. |
| `ebox-cache.el`, `ebox-style.el`, `ebox-tree.el`, `ebox-child-range.el`, `ebox-measure.el` | Cache, style, tree, persistent child-sequence, and measurement models. |
| `ebox-fragment.el`, `ebox-render-context.el` | Layout facts and render-local context. |
| `ebox-layout.el`, `ebox-flex.el`, `ebox-grid.el` | Formatting contexts and layout algorithms. |
| `ebox-surface.el` | Ebox candidate projection plus TP surface mount/update and atomic Ebox runtime-state participation. |
| `ebox-buffer-backend.el`, `ebox-incremental.el` | Layout dirty planning, marker indexes, and specialized local update paths. |
| `ebox-dsl.el`, `ebox-selector.el` | Standalone DSL and ECSS-backed tree/runtime queries. |
| `ebox-native-reflow.el`, `native/` | Optional native reflow boundary. |
| `tests/` | Ebox-only regression and contract tests. |
| `docs/user/`, `docs/maintainer/` | Long-lived English and Chinese documentation. |

## Verification

```sh
make load EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make compile EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make check EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make native-rust-tests
```

Run the smallest focused target first (`make grid-tests`, `make surface-tests`, `make dsl-tests`, or `make visual-check-tests`), then run `make check` for shared rendering or public API changes. Sibling ECSS and TP checkouts are found at `../new-architecture/ecss` and `../tp` by default; override `ECSS_DIR` or `TP_DIR` when they live elsewhere.

Read the [Ebox user guide](docs/user/ebox-user-guide.en.md) for a guided start, the [public API reference](docs/user/ebox-api-reference.en.md) for the complete function/property/configuration inventory, and the [current implementation reference](docs/maintainer/ebox-current-implementation-reference.en.md) for ownership boundaries and invariants.
