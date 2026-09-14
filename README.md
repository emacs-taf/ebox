# Ebox

Source layout: add the repository root to `load-path` and use
`(require 'ebox)`. The supported API and usage notes are in
[`ebox.el`](ebox.el); implementation modules live in `lisp/`.

Ebox is a standalone Text/Box layout engine for Emacs. It owns text
measurement, box geometry, row/column/flex/Grid layout, retained rendering,
and incremental buffer publication. Use the sibling ETAF package when an
application also needs Components, reactive state, behaviors, or lifecycle.

## Install

The source repository is [geekinney/ebox](https://gitea.gklazycat.heiyu.space/geekinney/ebox).
The current `3.0.0` changelog is unreleased; a source checkout is not a published
package archive or stable release tag.

| Dependency | Required for |
| --- | --- |
| Emacs 29.1 or newer | All Ebox use. |
| ECSS 0.1.0 or newer | Style computation and selector semantics; required even without a stylesheet. |
| TP 2.0.0 or newer | Retained publication, native property policies, and transactions; required when loading Ebox. |
| [EKP 1.0.0 or newer](https://gitea.gklazycat.heiyu.space/geekinney/ekp) | Optional; required only when using `:wrap-mode kp`. |

ECSS and TP are declared package dependencies. EKP is deliberately optional:
ordinary `word`, `char`, and `none` wrapping does not need it. For sibling source
checkouts, add the required directories to `load-path`, then load Ebox:

```elisp
(add-to-list 'load-path "/path/to/ecss")
(add-to-list 'load-path "/path/to/tp")
(add-to-list 'load-path "/path/to/ebox")
(require 'ebox)
```

Loading Ebox does not create a buffer or build native code.

For Knuth–Plass paragraph layout, also add the EKP source directory to
`load-path`, or install its package, before rendering a Box with `:wrap-mode kp`:

```elisp
(add-to-list 'load-path "/path/to/ekp")
(ebox-render
 (ebox-build '(box :width (ch 40) :wrap-mode kp :overflow hidden
                   "A paragraph laid out with Knuth–Plass line breaking.")))
```

Ebox loads EKP when that wrapping mode is used. A missing or incompatible EKP
signals an installation or update error; install EKP or explicitly choose
another wrapping mode. Ebox does not silently render using `word`.
EKP's optional accelerator is separate
from Ebox's optional Rust module.

### Build and verify an installable archive

From this checkout, run:

```sh
make release-check EMACS=emacs RELEASE_DIR=/tmp/ebox-release-3.0.0
```

This fetches the exact dependency commits in
[`release-dependencies.json`](release-dependencies.json), builds deterministic
`package.el` source archives (preserving the root entry and `lisp/` implementations),
and installs them into a temporary clean profile
to exercise rendering, updates, and selectors. It preserves the archive
directory and `manifest.json`, including checksums and source revision/dirty
status; it does not publish or change your Emacs profile. Choose a new output
directory on each run: existing directories are not overwritten.

To include and test optional KP layout, use a different output directory and
add `RELEASE_OPTIONS=--with-ekp`. Once an archive has passed verification, it can
be used as a local package archive:

```elisp
(require 'package)
(add-to-list 'package-archives '("ebox-local" . "/tmp/ebox-release-3.0.0/"))
(package-refresh-contents)
(package-install 'ebox)
;; Optional, only if the archive was built with --with-ekp:
;; (package-install 'ekp)
```

Use `python3 scripts/ebox-release.py --help` for release-tool options.

## First render

The ordinary author model has seven entries: a string, `text`, `box`, `row`,
`column`, `flex`, and `grid`. Children are nested directly; there is no second
field-based child syntax.

```elisp
(require 'ebox)

(ebox-render-to-buffer
 "*Ebox Example*"
 (ebox-build
  '(column :padding ((lh 1) (ch 2))
           :border ((px 1) solid "#8A93A6")
           (text :color "#263244" "Hello Ebox")
           (row :item-gap (ch 1)
                (box "Left")
                (box "Right")))))
```

Use `ebox-build` for the public author DSL. Framework integrations may instead
assemble typed nodes with one `ebox-source-builder`, then seal the forest and
its source generation as one `CanonicalEboxInput`; that evaluated API is not a
second author grammar.

Typed Box construction containing `ebox-child-range` descriptors passes its
open builder explicitly as `:source-builder`. The builder must own the Box
and its immediate children's source handles; an empty Range still requires
an open builder. It is used only during construction. To compose an existing canonical input,
use `ebox-canonical-input-roots` and `ebox-canonical-input-import-roots`;
frameworks must not access private canonical fields or dynamic context.

## Layout choices

- `box` creates a normal visual box.
- `row` and `column` provide simple one-axis composition.
- `flex` distributes space and supports wrapping.
- `grid` provides two-dimensional tracks and placement.
- A bare string is the short form of `(text "...")`.

Flex and Grid participation properties belong directly to a child `box`. They
do not require a wrapper node.

Box geometry uses `(unit number)`: `px`, `%`, `vw`, `vh`, `ch`, and `lh`.
For example, `:width (ch 80)` and `:height (calc (- (vh 100) (lh 1)))` mean an
80-zero-glyph width and a viewport height minus one line height. `calc`, `min`,
`max`, and `clamp` compose lengths at layout time. Size keywords such as `auto`
and bare `fit-content` stay symbols. Old bare lengths, singleton pixel lists,
and viewport keywords are rejected. Units are checked against the property axis
at construction, including every branch of a size function. See the [shared
unit-constraint table](docs/manual.md#size-unit-constraints)
for the allowed combinations, keyword defaults, percentage references, and
vertical line quantization. An empty Box has zero automatic content height;
use `(box :height (lh 1))` to reserve a blank line.

## Native interaction

Text and every Box form accept four explicit node capabilities: `:help-echo`
for a string or native help function, `:pointer` for a native pointer shape,
`:hover-style` for restricted color and text-decoration paint, and `:keymap`
for a native Emacs keymap. Box help, pointer, and keymap cover its content,
padding, and border; they exclude that Box's margin and structural newlines.
Hover shares the declaring node's paint across text and padding, excluding
physical left/right borders. Nested explicit
values override enclosing capabilities; explicit `nil` clears one capability.

Use `ebox-help-create` to adapt a zero-argument business function to native help
with the hovered buffer as its context. Use `ebox-keymap-create` to bind
ordinary zero-argument callbacks to activation
keys or custom keys; it supplies the clicked window's buffer for mouse commands.
Use `ebox-region-update` with a semantic ID in the current mounted buffer or
an explicit region handle to replace or clear these capabilities.
Native keymaps support independent Ebox interactions. Optional
`ebox-next-interaction` and `ebox-previous-interaction` commands move point
between rendered keymap owners without adding default key bindings.
Application state and command behavior remain the author's responsibility.
See the [interaction guide](docs/manual.md#native-node-interaction)
and the Playground's [interaction lab](https://gitea.gklazycat.heiyu.space/geekinney/ebox-playground/src/branch/main/README.md#native-interaction-lab).

Nodes can declare `:tab-index` and `:disabled`. Ebox owns buffer-local logical
focus, optional cyclic navigation, update retention and rollback through the
`ebox-focus` family. Mounted `ebox-buffer-mode` provides TAB/backtab cycling
and RET/return activation through `ebox-buffer-mode-map`. Generated activation
commands respect focus; mouse commands use the clicked target. See the
interaction guide for point and lifetime rules.

## Render and update

- `ebox-render` returns propertized text without publishing a live buffer.
- `ebox-render-to-buffer` mounts a retained surface.
- `ebox-display-buffer` renders successfully first, then displays the buffer
  using Emacs display rules and an optional action; it returns the buffer.
- `ebox-commit` atomically publishes a newly built canonical input.
- `ebox-buffer-update-report` returns the last successful update report.
- `ebox-rerender-buffer-with-context` applies an explicit viewport change.
- `ebox-surface-buffer-snapshot` explicitly exports the current committed
  `:input`, `:revision`, and `:mount-id` as one plist.

Ebox copies canonical input before assigning runtime identity, so one built
value may be mounted in multiple buffers without sharing live ownership.

Snapshots traverse exported data and TP's latest retained diagnostic report
only when requested; ordinary updates do not create them.
Their canonical input remains usable after later updates or unmounting. Mutable
node data and interaction keymaps are detached, while immutable source facts
and opaque capabilities (callbacks, records) retain identity. The display environment and
external capabilities are not frozen. Querying during a TP transaction or
after unmounting signals an error. Compare both mount ID and revision when
identifying a committed generation; remounting can restart revision numbers.

Ebox registers rollback-capable state only through TP 2.0.0's public structured
participant API and final v2 protocol. Older transition builds do not provide
the native property ownership and hover identity guarantees required by this
release. Missing or malformed structured participant capability stops Ebox
loading instead of selecting a compatibility writer.

## Optional native module

The Rust module accelerates eligible reflow work. It is optional and has an
exact Elisp fallback. Ebox never builds it while loading.

```elisp
(ebox-native-status)
(ebox-native-build)
```

## Display and text boundaries

Each mounted buffer has one viewport layout. Showing the same buffer in two
windows of different widths does not create two independent layouts. Use
separate mounted buffers for independent widths; the same canonical input may
be mounted more than once.

Vertical geometry is materialized in whole lines. Text handling preserves
common combining-mark, variation-selector, emoji-modifier, ZWJ, and flag
sequences; it does not implement complete Unicode grapheme segmentation or a
browser's typography and bidirectional layout. Font availability and native
pointer/help display depend on Emacs and the window system. Terminal output
cannot reproduce every GUI pixel or pointer effect.

`:overflow hidden` limits content to the box's measured width and whole-line
height, preserving its padding and borders. Horizontal clipping keeps whole
supported text clusters and fills unused pixels with space; it does not render
partial glyphs or insert an ellipsis. `scroll` remains vertical scrolling.

The repository includes a structural CI gate. Runtime and native verification
are explicit local Make targets; consult actual results for platform support.

## Verification

```sh
make load EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make compile EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make test EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make check EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make test
```

For incremental-update diagnostics in a sibling source checkout, run:

```sh
EBOX_UPDATE_EFFECTS_OUTPUT=/tmp/ebox-effects.json make update-effects-performance
```

This checks all 15 combinations of content, color, native interaction and width
changes with inline and local scoped styles. Each candidate replaces two adjacent
controls, including an unchanged neighbor. Fresh rendering validates the fixture;
every update checks text, display geometry, color, keymaps and activation outside
the timed interval. The JSON records raw build-through-commit samples, p50/p95/max,
projection counts and source/evaluator identity. `ordinary` means no local projection
kind was reported; it does not prove that a local attempt failed.
Two additional observed updates, excluded from timed samples, produce
`rejection_counts` grouped by projection and reason;
see the [report semantics](docs/manual.md) before interpreting these partial diagnostics.

Defaults are 20 and 100 untouched siblings, three warmups and ten samples per case.
Override `EBOX_UPDATE_EFFECTS_SIZES=20,100`, `EBOX_UPDATE_EFFECTS_WARMUPS=3` and
`EBOX_UPDATE_EFFECTS_SAMPLES=10` as needed. Use a new output path each time.
The evaluator acquires the shared performance host slot, fails if occupied, and
releases its own slot on exit. Correctness failures are recorded per case; the
remaining combinations still run and the command exits nonzero. `completed` means
the checks completed successfully, not that a latency budget or GUI acceptance passed.
Compare equivalent workloads and environments; keep application and GUI acceptance
as separate checks.

See the [user guide](docs/manual.md), the [public API
reference](docs/manual.md), and the sibling
[ebox-playground](https://gitea.gklazycat.heiyu.space/geekinney/ebox-playground/src/branch/main/README.md) examples.

## License

Ebox-owned code is distributed under GPL-3.0-or-later; see [LICENSE](LICENSE).
Third-party files retain their own license notices.
## File organization

Ebox owns the `.ebox` file boundary.  Loading `ebox.el` installs
`ebox-dsl-mode` and its `C-c C-c` command, which evaluates one DSL expression
and displays a preview without requiring `ebox-playground`.  For `name.ebox`,
the core optionally loads `name.el` first for lexical business functions and
then `name.ecss` as rules on the root Box's local ECSS scope.  Nested Box
styles remain inline `:ecss` scopes; all rules use the same ECSS matcher,
cascade, inheritance, and incremental update path.

## Development

After cloning, run `make setup-hooks`. Before submitting a change, run `make check`; `make structure-check` is the fast organization gate.

[docs/manual.md](docs/manual.md) · [docs/architecture.md](docs/architecture.md) · [CHANGELOG.md](CHANGELOG.md)

`make check` runs structure checks, compilation and the public acceptance scenarios listed in [tests/acceptance.json](tests/acceptance.json). `make test` runs the same public API suite. The inventory covers every maintained Lisp test. GUI and performance checks use separate targets.

## Source layout

Add the repository root to `load-path` and require `ebox`. The root entry
loads the implementation in `lisp/` and documents the supported public APIs in
its Commentary. Package archives include both the root entry and `lisp/`.
