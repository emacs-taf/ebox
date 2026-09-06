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
  '(column :padding (1 2)
           :border (1 solid "#8A93A6")
           (text :color "#263244" "Hello Ebox")
           (row :item-gap 1
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
node data is detached, while immutable source facts and opaque capabilities
(callbacks, keymaps, records) retain identity. The display environment and
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
make c1b-contract-tests EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make check EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make native-rust-tests
```

See the [user guide](docs/user/ebox-user-guide.en.md), the [public API
reference](docs/user/ebox-api-reference.en.md), and the sibling
[ebox-playground](../ebox-playground/README.md) examples.
