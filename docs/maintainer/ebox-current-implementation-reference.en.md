# Ebox current implementation reference

This is the maintainer entry point for the standalone Ebox repository. It describes the package boundary, active files, runtime model, invariants, and verification commands. The historical Ebox checkout is a separate legacy source tree; it is not a dependency of this package. ETAF is the sibling higher-level package.

## Reading order

1. Read `AGENTS.md` for repository rules.
2. Read `README.md` for installation and the public boundary.
3. Read `docs/user/ebox-user-guide.en.md` for public construction patterns.
4. Read `docs/user/ebox-api-reference.en.md` for the complete public function/property/configuration inventory.
5. Read this document for ownership and verification.
6. Read `docs/maintainer/ebox-incremental-update-contract.en.md` before changing publication or patch planning.
7. Read `docs/maintainer/ebox-performance-architecture-analysis.en.md` before changing performance, retained surfaces, or incremental data flow.

## Active source map

| File | Owns |
| --- | --- |
| `ebox.el` | Public facade, construction helpers, rendering, TP-backed buffer entry points, scrolling, commit, and byte compilation. |
| `ebox-cache.el` | Measurement/render cache records, invalidation, and cache reports. |
| `ebox-source.el` | Opaque source handles, immutable author source records, and candidate source indexes. |
| `ebox-runtime-index.el` | Compressed persistent radix maps and legacy hash-table adapters. |
| `ebox-state-contract.el` | Closed retained-state ownership inventory and read-only compatibility-mirror rebuild probes. |
| `ebox-style.el` | ECSS property schemas, declarations and cascade, shorthand expansion, computed style, colors, borders, and dirty effects. |
| `ebox-tree.el` | Node traversal, logical child access, ECSS subject adaptation, identity, parent paths, keys, and tree snapshots. |
| `ebox-child-range.el` | Immutable weighted segment trie, sparse persistent key trie, Range replacement, and Gate A metrics. |
| `ebox-measure.el` | Display-sensitive character/face/pixel measurement and measurement caches. |
| `ebox-fragment.el` | Layout fragments, signatures, snapshots, spans, and dirty-kind facts. |
| `ebox-render-context.el` | Render-local values and the injected candidate/materialization input port. |
| `ebox-layout.el` | Box, row, column, stack, concatenation, spacer, wrapping, and common formatting context. |
| `ebox-flex.el` | Flex normalization, lines, free-space distribution, and flex rendering. |
| `ebox-grid.el` | Tracks, implicit tracks, fractions, minmax/repeat, gap, placement, span, and alignment. |
| `ebox-surface.el` | Candidate identity, projection to TP surface plans, retained mount/update, and the rollback-capable Ebox runtime-state participant. |
| `ebox-buffer-backend.el` | Propertized render-string construction, display spaces/borders, and existing-slot shaping. |
| `ebox-patch-plan.el` | Pure tentative-operation antichain planning from immutable parent facts. |
| `ebox-incremental.el` | Runtime state, snapshots, dirty planning, owner escalation, pure commit preparation, and reports. |
| `ebox-dsl.el` | Data-oriented `.ebox` forms and lowering to public nodes. |
| `ebox-selector.el` | CSS-like string parsing to ECSS structured selector ASTs, indexed candidate lookup, and tree/runtime query handles. |
| `ebox-spi.el` | Additive immutable framework SPI v2 provider and initial/update operation descriptors. |
| `ebox-native-reflow.el` | Optional native module loading/build commands, ABI checks, bounded sessions, and Elisp fallback. |

The package intentionally does not include application Components, UI controls, reactive data, or a playground implementation. Those are sibling-package responsibilities.

The active contract also covers `Makefile`, `.github/workflows/ci.yml`, `tests/ebox-core-render-tests.el`, `tests/ebox-state-contract-tests.el`, `tests/ebox-layout-boundary-tests.el`, `tests/ebox-patch-plan-tests.el`, `tests/ebox-style-schema-tests.el`, `tests/ebox-spi-tests.el`, `tests/ebox-child-range-tests.el`, `tests/ebox-grid-tests.el`, `tests/ebox-commit-tests.el`, `tests/ebox-surface-tests.el`, `tests/ebox-dsl-tests.el`, `tests/ebox-flex-tests.el`, `tests/ebox-selector-tests.el`, `tests/ebox-package-tests.el`, `tests/ebox-visual-check-tests.el`, `tests/ebox-docs-contract-tests.el`, `tests/ebox-ci-contract-tests.el`, `native/Cargo.toml`, `native/Cargo.lock`, `native/build.rs`, `native/vendor/emacs-30/emacs-module.h`, `native/src/lib.rs`, `native/src/layout.rs`, `native/c/ebox_module.c`, `scripts/ebox-package-lint.el`, `scripts/ebox-visual-check.el`, and `scripts/ebox-performance-evaluator.el`.

Runtime index behavior is covered by `tests/ebox-runtime-index-tests.el`.

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
| Source/Element Tree | `ebox-child-range.el`, `ebox-tree.el`, `ebox-dsl.el` | Published buffer mutation. |
| State Ownership Contract | `ebox-state-contract.el` | Live publication or mutable authority. |
| Computed Style | `ebox-style.el` | Layout identity or patch execution. |
| Measurement | `ebox-measure.el` | Application state or dirty policy. |
| Formatting Context | `ebox-layout.el`, `ebox-flex.el`, `ebox-grid.el` | Buffer edits. |
| Fragment/Snapshot | `ebox-fragment.el`, `ebox-incremental.el` | Source parsing or identity allocation. |
| Surface Projection and Runtime Publication | `ebox-surface.el` plus public TP surface APIs | Ebox layout decisions or generic diff execution. |
| Dirty/Patch Semantics | `ebox-incremental.el` | Raw measurement or TP buffer writes. |
| Pure Patch Artifact Plan | `ebox-patch-plan.el` | Buffer/surface reads or publication. |
| Generic Surface Diff/Commit | TP | Ebox geometry, dirty policy, or application state. |
| Render-String Backend | `ebox-buffer-backend.el` | Live buffer writes, retained markers, style semantics, or application state. |

## Invariants

- Public Ebox nodes are data; `ebox--*` names are private.
- A one-element horizontal list such as `'(420)` denotes pixels; ordinary horizontal numbers denote character columns.
- `ebox-render` uses an ephemeral TP surface and does not publish to a buffer; `ebox-render-to-buffer` mounts a retained TP surface; `ebox-display-buffer` displays that same retained-surface path; and `ebox-commit` prepares Ebox semantics and updates the mount through TP. Ebox exposes no parallel public macro that erases a live buffer and evaluates arbitrary body forms.
- Declarative input remains caller-owned. Live mount/commit assigns identity only on a surface-owned copy, so the same source can back multiple buffers.
- Logical `:id` values resolve through `ebox-region-resolve` to opaque surface-scoped handles. Handles, not source-tree numeric ids, distinguish the same logical region mounted in different buffers.
- A failed candidate leaves the previous buffer, runtime identity, and report intact.
- Keys are local to siblings; visible strings are never used as identity.
- Ebox owns logical node-to-subject adaptation and id/class/type candidate indexes; ECSS's public structured matcher is the only selector truth source. Subjects expose built-in id/key plus explicit `:selector-attributes`, never visible content, layout state, or runtime containers.
- `ebox-style--property-definitions` is the single Ebox author-property source. Load time derives Ebox's read-only lookup index and one immutable ECSS package schema from it; the surface schema is composed once, and node construction or updates never re-register or copy the whole schema domain.
- E1 freezes the closed M2a target classification for retained state: immutable generation facts; generation-bound scroll/native authority; opaque TP client-state custody; one-way compatibility mirrors; and disposable caches. Every inventory row separately records the M2a-era storage shape plus its target owner, mutation API, generation binding, rollback, rebuild proof, and cleanup. TP client state holds the whole Ebox state plist. The E1 mirror probes only rebuild and compare projections; they never mutate live state.
- `ebox-layout.el` has no load or call edge to `ebox-surface.el` or TP. Candidate isolation, inherited-cascade detection, and one-shot materialization enter layout only through the validated port owned by `ebox-render-context.el`; `ebox.el` wires the surface implementation after both sides load.
- `ebox-incremental.el` likewise contains no `ebox-surface` symbol or publication call. `ebox-surface.el` installs one immutable read-only context port for live client state, region mounts, cascade proof, and inline-style preparation; batch observation remains in the higher `ebox.el` orchestrator.
- `ebox-patch-plan.el` consumes only tentative operation plists plus the immutable generation parent table and returns a deterministic plan artifact. The incremental adapter owns all live-fact preparation. E3 defaults to the pure route while retaining explicit `legacy` and equality-checking `shadow` routes; none of the three routes publishes.
- `ebox-style--property-definitions` is also the single used-value projection truth. Non-default engine lowering lives in each property's `:engine-projection`; ECSS metadata exposes the derived `:engine-targets`, and only non-public engine fields may use the small internal exception table.
- `ebox-framework-spi-capabilities` returns a fresh immutable SPI v2 provider record declaring paired initial/update stage+rollback, combined participant ordering, same-object reports, initial observation replay, and the actual accepted TP protocol. `ebox-framework-spi-required-tp-version` exposes the minimum TP 1.0.1 dependency, while `ebox-framework-spi-supported-tp-protocols` lists the consumer-first and final v2 protocol identities. Initial TP/Ebox timing is measured during publication, stored as defensive snapshots in the completed report, and replayed without mutation authority; no synthetic zero-duration timing is emitted. Ebox provides no selected port or consumer bootstrap.
- Ebox registers every rollback-capable runtime mirror through TP's public
  `tp-transaction-participate-v2` API. The loaded manifest must advertise that
  callable API with an accepted structured protocol; missing or malformed
  capability fails closed during load.
- SPI initial publication widens under provider ownership and wraps the TP
  transaction in an editor change group. On any unsuccessful or nonlocal exit,
  it restores original overlay identities and bounds together with buffer text,
  marker identities, point, mark, narrowing, undo history, and modified state.
- Framework report finalization is postaccept and no-throw. Initial, full-update, and scoped-update completion faults are retained in the same legacy report as `framework-report-finalization` diagnostics; they cannot invoke framework rollback or escape into an ETAF semantic rollback window.
- `owner-rerender` is broader than `span-patch`, which is broader than `paint-patch`.
- Buffer coordinates belong to the generation that produced them and must be refreshed after mutation.
- Grid uses the normal measurement and rendering pipeline. Native reflow may reject an ineligible tree and must fall back to Elisp without changing correctness.
- A confirmed retained-native frame owns an immutable layout document together
  with its exact document revision. Candidate-session forks share that document.
  A synchronous frame may omit the document only when its base and target
  document revisions are equal and match the confirmed document, and its TP
  runtime revision matches the confirmed frame. A changed IR sends a complete
  replacement document with the next document revision; confirmation promotes
  the candidate document atomically, while failure or cancellation leaves the
  parent session unchanged.
- A full declarative update continuing a committed native frame computes
  selector-local styles for every candidate node before stable native
  eligibility. The `:styles-prepared-p` certificate prevents replacement
  runtime nodes from losing computed styles while ordinary full/local updates
  retain O(changed) style work. Topology-changing full-frame bootstrap remains
  eligible.
- Loading Ebox never builds or installs the optional Rust module.
- Phase 9 is complete: first mount, declarative commit, handle/selector update, viewport/theme update, batch flush, and scroll update all publish through TP surfaces. Phase 10 has unified selector parsing, matching, and cascade under ECSS; Ebox computes dirty/layout ownership and joins its opaque runtime state to the TP rollback-capable transaction, with no second live buffer executor.
- Successful reports preserve the Ebox semantic strategy and planned publication scope, then add `:publication-scope tp-surface`, TP physical operation counts, surface revision, scoped/full-root facts, and retained-object reconciliation counts.

## Grid contract

Grid currently covers fixed and pixel tracks, `auto`, fractional tracks, `minmax`, `repeat`, implicit rows and columns, row/column gap, auto-flow, one-based placement, positive spans, item/content alignment, and ordinary buffer rendering and updates. Ebox supports canonical font inputs (`:font-family`, `:font-size`, `:font-weight`, and `:font-style`) plus text-decoration paint; full browser typography is outside the contract. Percentages, absolute positioning, z-index, border radius, shadows, and browser-level bidi are also outside the contract.

## Active examples and tests

The standalone package has no bundled playground fixtures. The migrated `.ebox` references and their file runner live in the sibling `ebox-playground` package; this repository tests the DSL and layout primitives directly. The regression boundary is the ERT files under `tests/` listed in the repository's documentation contract. No test in this package should load the historical full-stack source tree or an application framework.

## Verification matrix

```sh
make load
make compile
make check
make core-tests
make runtime-index-tests
make child-range-tests
make grid-tests
make ebox-commit-tests
make surface-tests
make visual-check-tests
make package-tests
make selector-tests
make dsl-tests
make flex-tests
make state-contract-tests
make layout-boundary-tests
make layout-boundary-performance
make patch-plan-tests
make patch-plan-performance
make style-schema-tests
make style-schema-performance
make spi-tests
make spi-performance
make c1b-contract-tests
make docs-contract-tests
make ci-contract-tests
make performance-evaluator
make visual-check
make native-rust-tests
make native-build
make package-lint
make diff-check
```

Run focused tests first, then `make check` after changes to shared rendering, Grid, public constructors, or documentation. Native changes require the Rust checks and a native build.
