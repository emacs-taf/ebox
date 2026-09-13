# Changelog

All notable changes to Ebox are documented here.

## 3.0.0 (Unreleased)

### Added

- Explicit native node capabilities `:help-echo`, `:pointer`, `:hover-style`,
  and `:keymap`, including callback adapters `ebox-help-create` and
  `ebox-keymap-create`, nested overrides, explicit-nil blocking, and retained
  updates. These do not require ETAF or an arbitrary text-property escape hatch.
- Optional `ebox-next-interaction` and `ebox-previous-interaction` navigation
  commands for rendered keymap owners; no default navigation bindings or
  application state system are installed.
- Explicit geometry units `px`, `%`, `vw`, `vh`, `ch`, and `lh`, composable
  `calc`/`min`/`max`/`clamp` functions, and construction-time axis validation.
- A repository-level GPL-3.0-or-later license and consistent Ebox/Rust package
  declarations, with third-party notices retained.
- Locked dependency inputs and a reusable source-archive build/install verifier
  (`make release-check`), including optional EKP and explicit native-module
  integration. CI now prepares ECSS as well as TP, tests the minimum supported
  Emacs version, and configures native loading/execution on all three platforms.
- Direct dependencies on the independent ECSS 0.1.0 cascade engine and TP 2.0.0 retained/reactive text runtime.
- ECSS-backed property schemas, selectors, stylesheets, inheritance, cascade layers, custom properties, computed values, and provenance for Box, Flex, and Grid nodes.
- Surface-scoped region handles through `ebox-region-resolve`, retained TP publication through `ebox-render-to-buffer` and `ebox-display-buffer`, and atomic handle/selector/viewport/scroll updates.
- Typography longhands and inherited foreground projection that keep text readable when child boxes override background colors.
- A public, nestable framework render-burst boundary that covers pre-commit allocation, shares interactive deferred GC ownership with Ebox commits, and restores batch GC settings without collecting at the boundary.
- Structured TP participant registration for every retained publication.

### Changed

- `ebox-display-buffer` renders before calling native `display-buffer`, accepts
  its optional action argument, and returns the rendered buffer. Ebox no longer
  deletes other windows or selects the result as part of ordinary display.
- `:overflow hidden` now also enforces horizontal content width, including
  composed child output, while retaining the owner's padding and border.
  Clipping preserves supported text clusters and visible properties, removes
  clipped child interactions, and fills remaining pixels without an ellipsis.
  This adapts the GPL-compatible s-pixel approach without a new dependency;
  partial-glyph masking and stacking are not introduced.
- `:wrap-mode kp` explicitly requires the optional EKP package. Missing or
  incompatible EKP now reports an installation/update error instead of silently
  selecting word wrapping. Other wrapping modes do not require EKP.
- The minimum TP dependency is now 2.0.0 with the final v2 participant protocol.
  Native keymap ownership, callback identity, and shared hover regions require
  its property policies; the former TP 1.0.1 transition baseline is insufficient.
- Incremental updates reuse proven unchanged style, identity, ownership, and
  viewport facts. Content and paint changes keep the smallest safe publication
  scope; geometry or dependency changes still promote to a larger owner when
  required. TP publishes the changed text interval and preserves rollback.
- Hover paint covers the declaring owner's text and padding as one native
  hover region per rendered line, while preserving physical side borders.
  Nested explicit hover declarations remain separate regions.
- Package metadata now distinguishes builds with the public unmount/revision
  boundary and SPI v2 compatibility surface from older 2.x development
  snapshots.
- Early 3.0 development used TP 1.0.1's structured transition protocol. The
  release candidate now requires TP 2.0.0 or newer and always
  uses the public structured participant API.
- SPI initial publication owns widening and an outer editor change group. A
  failed stage or nonlocal rollback exit restores text, markers, overlays,
  point, mark, narrowing, undo history, and modified state before it escapes.
- ECSS is the only selector matcher and cascade winner. Ebox adapts node trees to ECSS subjects, interprets computed values for measurement/layout/paint, and classifies their layout impact.
- TP is the only live buffer writer. Ebox produces retained surface candidates and semantic dirty-owner plans; TP owns diff execution, marker-backed mounts, revisions, transactions, and rollback.
- Flex and Grid container/item declarations enter the same ECSS pipeline as ordinary boxes instead of maintaining a parallel style path.
- Region updates use opaque surface-scoped handles. The same declarative source may be mounted in multiple buffers without sharing live identity.
- A full declarative update that continues a committed native frame now computes
  a complete selector-local style certificate before stable native eligibility.
  Other full/local paths retain their existing O(changed) style work. Native
  updates no longer commit replacement runtime nodes without computed styles,
  and structural full-frame bootstrap remains available.

### Removed

- `ebox-pop-to-buffer`, `ebox-switch-to-buffer`, and the private erase-and-evaluate buffer writer they exposed.
- Ebox's duplicate selector parser/matcher and duplicate cascade winner.
- Bundled playground fixtures. Executable `.ebox` references live in the independent `ebox-playground` package.
- The Ebox transaction route switch, v1 TP participant adapter call, and
  missing-capability fallback.

### Migration

- Replace legacy geometry literals with explicit units: for example,
  `:width 80` becomes `:width (ch 80)`, `:width (240)` becomes
  `:width (px 240)`, and `:height 3` becomes `:height (lh 3)`. Use
  `python3 scripts/migrate-css-sizes.py PATH...` to preview supported literal
  rewrites; review reported dynamic or ambiguous values before adding `--write`.
  Vertical geometry rejects `px`, and `fit-content` is now a bare keyword.
- Callers requiring selected or exclusive display must choose that window
  policy explicitly; ordinary `ebox-display-buffer` follows native display
  rules. Rendering without display remains `ebox-render-to-buffer`.
- Install EKP 1.0.0 or newer only when using `:wrap-mode kp`; its optional native
  accelerator is independent from Ebox's optional Rust reflow module.
- Install ECSS 0.1.0 and TP 2.0.0 or newer, in either order, before Ebox 3.0.0.
- Remove any customization of `ebox-transaction-participant-route`; Ebox 3.0.0
  requires TP's structured participant capability and fails closed when it is
  missing or malformed.
- Replace numeric region-id mutation with `ebox-region-resolve` followed by `ebox-region-update` on the returned handle.
- Replace `ebox-pop-to-buffer` or `ebox-switch-to-buffer` with `ebox-display-buffer`, or call `ebox-render-to-buffer` when display is controlled by the caller.
- Ebox does not scan previously rendered text to reconstruct runtime identity. Remount the declarative source through Ebox 3.0.

### Release status and supported boundaries

- `3.0.0` remains unreleased. These changes prepare source distribution; they
  do not announce an uploaded package archive or published release tag.
- Each mounted buffer owns one viewport layout. Use separate buffers for views
  requiring independent widths. Vertical geometry remains whole-line based.
- Common UI text clusters are preserved, but complete Unicode grapheme
  segmentation, browser-level bidi, stacking, and absolute positioning are
  outside the current contract.
