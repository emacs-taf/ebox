# Changelog

All notable changes to Ebox are documented here.

## Unreleased

### Changed

- **BREAKING:** Ebox now exposes a mutable retained-node engine.  Build roots
  with `ebox-build`, `ebox-node-create` or `ebox-text-create`; mount them with
  `ebox-mount`; then update the existing tree with node mutation functions.
  Flushes restyle, relayout and repaint dirty paths, and rewrite only changed
  buffer lines/parts.
- `ebox-file-load-companion` loads a compiled `.ebox` companion when its
  bytecode is newer than the `.el` source; edited sources still load directly.

### Removed

- **BREAKING:** Removed the previous engine's canonical inputs, source builders,
  surfaces, publications, transactions, prepared update/geometry APIs,
  generation/candidate model, layer module, native Rust layout module, framework
  SPI and render-burst interfaces.  Migrate high-level callers by keeping Ebox
  node references instead of external handles: old full input replacement maps to
  building or copying a retained root and mounting it; old source-builder child
  updates map to `ebox-node-insert`, `ebox-node-remove`, `ebox-node-move` or
  `ebox-node-replace-children`; old content/property/selector updates map to
  `ebox-node-set-text`, `ebox-node-set-image`, `ebox-node-set-props`,
  `ebox-node-put`, `ebox-node-set-states` or `ebox-node-restyle`; old explicit
  update grouping maps to `ebox-with-batch`.
