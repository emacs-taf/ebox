# Ebox repository guidance

This repository is the standalone low-level Ebox package. It owns box nodes, style normalization, measurement, layout, rendering, buffer publication, selectors, incremental updates, Grid, and the optional Rust reflow module. The sibling `etaf` repository owns the higher-level text-application framework; `etaf-playground` and `ebox-playground` are separate example packages.

Keep this repository independent from ETAF. Do not add Components, Runtime state, Data Controllers, UI controls, or application examples here. Public Ebox code may depend on its own modules only; private `ebox--*` functions are implementation details.

Use `apply_patch` for hand-edited changes. Keep each file lexically bound, document public APIs, preserve deterministic rendering, and add a focused regression test for behavior changes. Run `make check EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs` before claiming completion. Run `make native-rust-tests` when changing `native/` and run `make docs-contract-tests` when changing documentation or the active file boundary.

The old `emacs-box` checkout is a historical full-stack source tree. It is intentionally not a dependency of this package and should not be edited as part of Ebox work unless a separate task explicitly targets that legacy repository.
