# Ebox current implementation reference

This is the maintainer entry point for the standalone Ebox repository. It describes the package boundary, active files, runtime model, invariants, and verification commands. The historical `emacs-box` checkout is a separate legacy source tree; it is not a dependency of this package. ETAF is the sibling higher-level package.

## Reading order

1. Read `AGENTS.md` for repository rules.
2. Read `README.md` for installation and the public boundary.
3. Read `docs/user/ebox-user-guide.en.md` for public construction patterns.
4. Read this document for ownership and verification.
5. Read `docs/maintainer/ebox-incremental-update-contract.en.md` before changing publication or patch planning.

## Active source map

| File | Owns |
| --- | --- |
| `ebox.el` | Public facade, construction helpers, rendering, buffer entry points, scrolling, commit, and byte compilation. |
| `ebox-cache.el` | Measurement/render cache records, invalidation, and cache reports. |
| `ebox-style.el` | Property registration, aliases, shorthand expansion, computed style, colors, borders, and dirty effects. |
| `ebox-tree.el` | Node traversal, child access, identity, parent paths, keys, and tree snapshots. |
| `ebox-measure.el` | Display-sensitive character/face/pixel measurement and measurement caches. |
| `ebox-fragment.el` | Layout fragments, signatures, snapshots, spans, and dirty-kind facts. |
| `ebox-render-context.el` | Render-local context and publication inputs. |
| `ebox-layout.el` | Box, row, column, stack, concatenation, spacer, wrapping, and common formatting context. |
| `ebox-flex.el` | Flex normalization, lines, free-space distribution, and flex rendering. |
| `ebox-grid.el` | Tracks, implicit tracks, fractions, minmax/repeat, gap, placement, span, and alignment. |
| `ebox-surface.el` | Candidate identity, projection to TP surface plans, retained mount/update, and the rollback-capable Ebox runtime-state participant. |
| `ebox-buffer-backend.el` | Propertized render-string construction, display spaces/borders, and existing-slot shaping. |
| `ebox-incremental.el` | Runtime state, snapshots, dirty planning, owner escalation, pure commit preparation, and reports. |
| `ebox-dsl.el` | Data-oriented `.ebox` forms and lowering to public nodes. |
| `ebox-selector.el` | CSS-like queries over trees and runtime handles. |
| `ebox-native-reflow.el` | Optional native module loading/build commands, ABI checks, bounded sessions, and Elisp fallback. |

The package intentionally does not include application Components, UI controls, reactive data, or a playground implementation. Those are sibling-package responsibilities.

The active contract also covers `Makefile`, `.github/workflows/ci.yml`, `tests/ebox-core-render-tests.el`, `tests/ebox-grid-tests.el`, `tests/ebox-commit-tests.el`, `tests/ebox-surface-tests.el`, `tests/ebox-dsl-tests.el`, `tests/ebox-flex-tests.el`, `tests/ebox-selector-tests.el`, `tests/ebox-package-tests.el`, `tests/ebox-visual-check-tests.el`, `tests/ebox-docs-contract-tests.el`, `tests/ebox-ci-contract-tests.el`, `native/Cargo.toml`, `native/Cargo.lock`, `native/build.rs`, `native/vendor/emacs-30/emacs-module.h`, `native/src/lib.rs`, `native/src/layout.rs`, `native/c/ebox_module.c`, `scripts/ebox-package-lint.el`, and `scripts/ebox-visual-check.el`.

## Runtime model

The normal data flow is:

```text
Caller-owned Source Tree
  -> Surface-owned Runtime Copy
  -> TP Candidate Objects
  -> Element Tree
  -> Computed Style
  -> Box/Formatting Context
  -> Measurement + Render Context
  -> Layout Fragment/Snapshot
  -> Ebox Dirty/Patch Plan
  -> TP Surface Plan
  -> TP Atomic Publication
  -> Ebox Runtime-State Participant
```

| Model | Owner | Must not own |
| --- | --- | --- |
| Source/Element Tree | `ebox-tree.el`, `ebox-dsl.el` | Published buffer mutation. |
| Computed Style | `ebox-style.el` | Layout identity or patch execution. |
| Measurement | `ebox-measure.el` | Application state or dirty policy. |
| Formatting Context | `ebox-layout.el`, `ebox-flex.el`, `ebox-grid.el` | Buffer edits. |
| Fragment/Snapshot | `ebox-fragment.el`, `ebox-incremental.el` | Source parsing or identity allocation. |
| Surface Projection and Runtime Publication | `ebox-surface.el` plus public TP surface APIs | Ebox layout decisions or generic diff execution. |
| Dirty/Patch Semantics | `ebox-incremental.el` | Raw measurement or TP buffer writes. |
| Generic Surface Diff/Commit | TP | Ebox geometry, dirty policy, or application state. |
| Render-String Backend | `ebox-buffer-backend.el` | Live buffer writes, retained markers, style semantics, or application state. |

## Invariants

- Public Ebox nodes are data; `ebox--*` names are private.
- A one-element horizontal list such as `'(420)` denotes pixels; ordinary horizontal numbers denote character columns.
- `ebox-render` uses an ephemeral TP surface and does not publish to a buffer; `ebox-render-to-buffer` mounts a retained TP surface; `ebox-commit` prepares Ebox semantics and updates that surface through TP.
- Declarative input remains caller-owned. Live mount/commit assigns identity only on a surface-owned copy, so the same source can back multiple buffers.
- Logical `:id` values resolve through `ebox-region-resolve` to opaque surface-scoped handles. Handles, not source-tree numeric ids, distinguish the same logical region mounted in different buffers.
- A failed candidate leaves the previous buffer, runtime identity, and report intact.
- Keys are local to siblings; visible strings are never used as identity.
- `owner-rerender` is broader than `span-patch`, which is broader than `paint-patch`.
- Buffer coordinates belong to the generation that produced them and must be refreshed after mutation.
- Grid uses the normal measurement and rendering pipeline. Native reflow may reject an ineligible tree and must fall back to Elisp without changing correctness.
- Loading Ebox never builds or installs the optional Rust module.
- Phase 9 is active: first mount, declarative commit, handle/selector update, viewport/theme update, batch flush, and scroll update all publish through TP surfaces. Ebox computes dirty/layout ownership and joins its opaque runtime state to the same rollback-capable transaction; it has no second live buffer executor.
- Successful reports preserve the Ebox semantic strategy and planned publication scope, then add `:publication-scope tp-surface`, TP physical operation counts, surface revision, scoped/full-root facts, and retained-object reconciliation counts.

## Grid contract

Grid currently covers fixed and pixel tracks, `auto`, fractional tracks, `minmax`, `repeat`, implicit rows and columns, row/column gap, auto-flow, one-based placement, positive spans, item/content alignment, and ordinary buffer rendering and updates. CSS cascade, percentages, absolute positioning, z-index, border radius, shadows, full typography, and browser-level bidi are outside the contract.

## Active examples and tests

The standalone package has no bundled playground fixtures. The migrated `.ebox` references and their file runner live in the sibling `ebox-playground` package; this repository tests the DSL and layout primitives directly. The regression boundary is the ERT files under `tests/` listed in the repository's documentation contract. No test in this package should load the historical full-stack source tree or an application framework.

## Verification matrix

```sh
make load
make compile
make check
make core-tests
make grid-tests
make ebox-commit-tests
make surface-tests
make visual-check-tests
make package-tests
make selector-tests
make dsl-tests
make flex-tests
make docs-contract-tests
make ci-contract-tests
make visual-check
make native-rust-tests
make native-build
make package-lint
make diff-check
```

Run focused tests first, then `make check` after changes to shared rendering, Grid, public constructors, or documentation. Native changes require the Rust checks and a native build.
