# Ebox

Ebox is a standalone Text/Box layout engine for Emacs. It owns text
measurement, box geometry, row/column/flex/Grid layout, retained rendering,
and incremental buffer publication. Use the sibling ETAF package when an
application also needs Components, reactive state, behaviors, or lifecycle.

## Install

Ebox requires Emacs 29.1 or newer, ECSS 0.1.0 or newer, and TP 1.0.1 or newer.
A package manager should
install the declared dependencies. For sibling source checkouts, add the three
directories to `load-path`, then load Ebox:

```elisp
(add-to-list 'load-path "/path/to/ecss")
(add-to-list 'load-path "/path/to/tp")
(add-to-list 'load-path "/path/to/ebox")
(require 'ebox)
```

Loading Ebox does not create a buffer or build native code.

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
unit-constraint table](docs/user/ebox-user-guide.en.md#size-unit-constraints)
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
Native keymaps support independent Ebox interactions; application state,
focus navigation, and command behavior remain the author's responsibility.
See the [interaction guide](docs/user/ebox-user-guide.en.md#native-node-interaction)
and the Playground's [interaction lab](../ebox-playground/README.md#native-interaction-lab).

## Render and update

- `ebox-render` returns propertized text without publishing a live buffer.
- `ebox-render-to-buffer` mounts a retained surface.
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

Ebox registers rollback-capable state only through TP's public structured
participant API. TP 1.0.1 supports the consumer-first migration protocol;
TP 2.0.0 publishes the final v2-only protocol. Missing or malformed structured
participant capability stops Ebox loading instead of selecting a compatibility
writer.

## Optional native module

The Rust module accelerates eligible reflow work. It is optional and has an
exact Elisp fallback. Ebox never builds it while loading.

```elisp
(ebox-native-status)
(ebox-native-build)
```

## Verification

```sh
make load EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make compile EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make docs-contract-tests EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make interaction-tests EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make c1b-contract-tests EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make check EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make native-rust-tests
```

See the [user guide](docs/user/ebox-user-guide.en.md), the [public API
reference](docs/user/ebox-api-reference.en.md), and the sibling
[ebox-playground](../ebox-playground/README.md) examples.
