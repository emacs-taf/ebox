# Ebox

Ebox is a standalone, pixel-precise box and layout engine for Emacs. It provides the low-level rendering substrate used by the sibling [ETAF](../etaf/README.md) text-application framework. Ebox can also be used directly without Components, application state, or ETAF.

## Install and use

Install TP first, then install Ebox through a package manager so its declared dependency is resolved. For sibling source checkouts, place both directories on `load-path`:

```elisp
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

The public model is a tree of Ebox nodes. `ebox-create` builds a leaf or wrapper node; `ebox-column`, `ebox-row`, `ebox-flex`, and `ebox-grid` compose nodes; `ebox-render` materializes propertized text through an ephemeral TP surface; `ebox-render-to-buffer` mounts a retained TP surface; and `ebox-commit` atomically updates that surface from a fresh root tree. Ebox copies declarative input before assigning runtime identity, so one source tree may be mounted in multiple buffers without transferring ownership.

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
| `ebox-style.el`, `ebox-tree.el`, `ebox-measure.el` | Style, tree, and measurement models. |
| `ebox-layout.el`, `ebox-flex.el`, `ebox-grid.el` | Formatting contexts and layout algorithms. |
| `ebox-surface.el` | Ebox candidate projection plus TP surface mount/update and atomic Ebox runtime-state participation. |
| `ebox-buffer-backend.el`, `ebox-incremental.el` | Layout dirty planning, marker indexes, and specialized local update paths. |
| `ebox-dsl.el`, `ebox-selector.el` | Standalone DSL and tree/runtime queries. |
| `ebox-native-reflow.el`, `native/` | Optional native reflow boundary. |
| `examples/`, `tests/` | Ebox-only examples and regression tests. |
| `docs/user/`, `docs/maintainer/` | Long-lived English and Chinese documentation. |

## Verification

```sh
make load EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make compile EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make check EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make native-rust-tests
```

Run the smallest focused target first (`make grid-tests`, `make surface-tests`, `make dsl-tests`, or `make visual-check-tests`), then run `make check` for shared rendering or public API changes. A sibling TP checkout is found at `../tp` by default; override `TP_DIR` when it lives elsewhere.

Read the [Ebox user guide](docs/user/ebox-user-guide.en.md) for public construction examples and the [current implementation reference](docs/maintainer/ebox-current-implementation-reference.en.md) for ownership boundaries and invariants.
