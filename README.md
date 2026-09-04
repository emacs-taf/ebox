# Ebox

Ebox is a standalone Text/Box layout engine for Emacs. It owns text
measurement, box geometry, row/column/flex/Grid layout, retained rendering,
and incremental buffer publication. Use the sibling ETAF package when an
application also needs Components, reactive state, behaviors, or lifecycle.

## Install

Ebox requires Emacs 29.1 or newer, ECSS, and TP. A package manager should
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

Ebox copies canonical input before assigning runtime identity, so one built
value may be mounted in multiple buffers without sharing live ownership.

Ebox registers its rollback-capable TP state through the public structured v2
participant API by default.  Set `ebox-transaction-participant-route` to `v1`
before the next operation for an immediate old-route rollback.  If the loaded TP
manifest predates the structured API, the default v2 policy selects the same
complete v1 adapter automatically; the two registrations are never run together.

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
make check EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make native-rust-tests
```

See the [user guide](docs/user/ebox-user-guide.en.md), the [public API
reference](docs/user/ebox-api-reference.en.md), and the sibling
[ebox-playground](../ebox-playground/README.md) examples.
