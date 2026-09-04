# Changelog

All notable changes to Ebox are documented here.

## 2.0.1 (Unreleased)

### Added

- Direct dependencies on the independent ECSS 0.1.0 cascade engine and TP 1.0.1 retained/reactive text runtime.
- ECSS-backed property schemas, selectors, stylesheets, inheritance, cascade layers, custom properties, computed values, and provenance for Box, Flex, and Grid nodes.
- Surface-scoped region handles through `ebox-region-resolve`, retained TP publication through `ebox-render-to-buffer` and `ebox-display-buffer`, and atomic handle/selector/viewport/scroll updates.
- Typography longhands and inherited foreground projection that keep text readable when child boxes override background colors.
- A public, nestable framework render-burst boundary that covers pre-commit allocation, shares interactive deferred GC ownership with Ebox commits, and restores batch GC settings without collecting at the boundary.
- A supported `ebox-transaction-participant-route` switch: v2 structured TP
  registration is the default, while the complete v1 adapter remains available
  explicitly and as the compatibility fallback for older TP manifests.

### Changed

- Package metadata now distinguishes builds with the public unmount/revision
  boundary and SPI v2 compatibility surface from older 2.0.0 development
  snapshots.
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

### Migration

- Install ECSS 0.1.0 and TP 1.0.1, in either order, before Ebox 2.0.1.
- Replace numeric region-id mutation with `ebox-region-resolve` followed by `ebox-region-update` on the returned handle.
- Replace `ebox-pop-to-buffer` or `ebox-switch-to-buffer` with `ebox-display-buffer`, or call `ebox-render-to-buffer` when display is controlled by the caller.
- Ebox does not scan previously rendered text to reconstruct runtime identity. Remount the declarative source through Ebox 2.0.
