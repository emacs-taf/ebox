# Ebox public API reference

[中文](ebox-api-reference.zh.md)

This reference describes the current public boundary of the standalone Ebox
package. It separates the ordinary author path from the evaluated typed API
used by framework integrations. Names beginning with `ebox--` are private.

Ebox requires Emacs 29.1 or newer, ECSS, and TP:

```elisp
(require 'ebox)
```

## 1. Author grammar

`ebox-build` accepts exactly these author entries:

```text
STRING
(text PROPERTY VALUE ... STRING)
(box PROPERTY VALUE ... CHILD ...)
(row PROPERTY VALUE ... CHILD ...)
(column PROPERTY VALUE ... CHILD ...)
(flex PROPERTY VALUE ... CHILD ...)
(grid PROPERTY VALUE ... CHILD ...)
```

`STRING` is the short form of `(text STRING)`. A Text form requires exactly
one string payload. Every Box form accepts zero or more directly nested Text
or Box children. The form name selects Normal, Row, Column, Flex, or Grid child
layout; authors do not pass a layout selector as a property.

```elisp
(ebox-build
 '(column :padding (1 2)
          (box :id "status" :color "#166534" "Ready")
          (row :item-gap 1
               (box "Left")
               (box "Right"))))
```

The author source fields are `:key`, `:class`, and `:id`. `:outer` is `inline`
or `block` and controls how a Box participates in its parent.

### Layout-owned properties

| Form or relationship | Properties |
| --- | --- |
| `row`, `column` | `:item-gap`, `:cross-align` |
| `flex` | `:flex-direction`, `:flex-wrap`, `:flex-flow`, `:justify-content`, `:align-items`, `:align-content`, `:gap`, `:row-gap`, `:column-gap` |
| Direct child Box of `flex` | `:order`, `:flex`, `:flex-grow`, `:flex-shrink`, `:flex-basis`, `:align-self` |
| `grid` | `:grid-template-columns`, `:grid-template-rows`, `:grid-auto-columns`, `:grid-auto-rows`, `:grid-auto-flow`, `:justify-items`, `:justify-content`, `:align-items`, `:align-content`, `:gap`, `:row-gap`, `:column-gap` |
| Direct child Box of `grid` | `:order`, `:grid-column`, `:grid-row`, `:grid-column-span`, `:grid-row-span`, `:align-self` |

Participation properties are ordinary child Box properties. They do not create
another public node or wrapper.

### Common current properties

| Area | Current inputs |
| --- | --- |
| Size | `:box-sizing`, `:width`, `:min-width`, `:max-width`, `:height`, `:min-height`, `:max-height` |
| Edges | `:padding`, `:margin`, `:border`, side shorthands, and their longhands |
| Paint | `:color`, `:background-color`, exact alias `:bgcolor`, border colors, `:visibility` |
| Text layout | `:text-align`, `:wrap-mode` (`word`, `char`, `kp`, `none`) |
| Overflow | `:overflow` (`visible`, `hidden`, `scroll`) |

Ordinary horizontal numbers are character columns; a one-element horizontal
list is pixels. Vertical numbers are lines. `(viewport)` and
`(viewport-height)` use the current render context. Property validation belongs
to Ebox and invalid context/value combinations signal an error.

## 2. Evaluated typed construction

Frameworks that already own author parsing can construct canonical nodes
directly:

```elisp
(let ((layout (ebox-column-layout-create
               :item-gap 1 :cross-align 'stretch)))
  (ebox-box-create
   :layout layout
   :children (list (ebox-text-create :value "One")
                   (ebox-text-create :value "Two"))))
```

- `ebox-text-create` requires `:value STRING`.
- `ebox-normal-layout-create` creates Normal LayoutConfig.
- `ebox-row-layout-create` and `ebox-column-layout-create` accept
  `:item-gap` and `:cross-align`.
- `ebox-flex-layout-create` creates a validated Flex LayoutConfig.
- `ebox-grid-layout-create` creates a validated Grid LayoutConfig.
- `ebox-box-create` requires one typed `:layout` value and accepts a
  `:children` list of typed nodes.

The last two fields belong only to this evaluated integration contract. They
are not author properties or alternate DSL syntax.

Node inspection functions are `ebox-node-kind`, `ebox-text-node-p`,
`ebox-box-node-p`, `ebox-node-source-handle`, `ebox-text-node-value`,
`ebox-box-node-layout`, `ebox-box-node-children`, and
`ebox-box-node-range-anchors`. They are public from the typed module even
though the facade inventory below focuses on application entry points.

## 3. Rendering and retained publication

| Function | Contract |
| --- | --- |
| `ebox-render` | Return a propertized string without publishing a live buffer. |
| `ebox-render-to-buffer` | Copy the built root, mount a retained TP surface, enable `ebox-buffer-mode`, and return the buffer. Its optional plist accepts only `:observer FUNCTION`. |
| `ebox-display-buffer` | Render through the retained path, delete other windows, and switch to the result. |
| `ebox-commit` | Atomically publish a newly built root or one-shot logical candidate. |
| `ebox-buffer-set-observer` | Set or remove one function-valued observer on an already mounted buffer. |
| `ebox-buffer-update-report` | Return a defensive copy of the last successful update report. |
| `ebox-rerender-buffer-with-context` | Apply explicit viewport width and optional height while retaining identity. |
| `ebox-viewport-window-width` | Return Ebox's display-safe pixel width for a window. |

`ebox-commit` accepts optional framework publish and rollback callbacks. They
join the existing atomic publication; failures restore the previous buffer,
surface, runtime state, and successful report.

Every public Ebox publication owns its TP transaction. Calling mount, commit,
viewport, region, selector, batch, or TP-backed scroll publication from inside
an already active outer TP transaction is rejected before Ebox mutation.

Observation is an optional read-only boundary, not transaction authority. An
observer has the signature `(OBSERVER BUFFER REPORT)`. After one accepted TP
publication and all Ebox finalization complete, it receives two defensive flat
reports in order: TP first, then Ebox. Both carry the same `:correlation-id`,
derived from the TP transaction id. Ebox stages are `mount`, `commit`,
`viewport`, `region`, `selector`, `batch`, and `scroll`. Nested public calls
reuse the outer operation, so a multi-match selector or explicit batch still
emits one pair. No-op operations and native-window scrolls that publish no TP
surface emit no pair. Observer errors are contained after acceptance and
cannot roll back rendering.

Pass `:observer` to `ebox-render-to-buffer` when the initial mount must be
included. That mount report is transient: observed and unobserved mounts both
leave `ebox-buffer-update-report` nil. Use `ebox-buffer-set-observer` to replace
or remove observation later; passing nil detaches the TP bridge. With no
observer, Ebox creates no observation context, timestamps, GC snapshots, or
report decoration.

`ebox-call-with-render-burst` is the exception-safe allocation/GC boundary for
a framework callback. `ebox-render-burst-begin` and `ebox-render-burst-end`
provide the lower-level token form and must be paired with `unwind-protect`.
They do not publish by themselves.

## 4. Identity, direct updates, and logical candidates

| Function | Contract |
| --- | --- |
| `ebox-region-ids` | Return current low-level region ids in document order. |
| `ebox-region-resolve` | Resolve one logical `:id` in a mounted buffer to an opaque surface-scoped handle. |
| `ebox-region-update` | Apply supported mutable style or scroll properties through one retained transaction. |
| `ebox-child-range` | Build a transparent, addressable child Range descriptor from typed nodes. |
| `ebox-candidate-begin` | Capture the exact current mounted generation in a one-shot candidate. |
| `ebox-candidate-replace` | Replace one candidate node address. |
| `ebox-candidate-replace-range-ref` | Replace one transparent child Range payload. |
| `ebox-candidate-replace-root` | Replace the candidate's private root address. |
| `ebox-candidate-replace-host-ref` | Replace one framework-owned opaque host reference. |
| `ebox-candidate-patch-host-paint` | Record a proven paint-only host patch or return nil when replacement is required. |
| `ebox-host-ref-bounds` | Return current margin-free bounds for an opaque host reference. |
| `ebox-host-ref-position` | Return its first current position. |

Handles and reported positions belong to one live publication generation.
Resolve them again after their object is removed. A candidate is sealed by
commit and cannot be reused.

## 5. Selectors

ECSS is the sole selector parser and matcher. Ebox supplies logical tree
relations and mounted indexes.

| Function | Contract |
| --- | --- |
| `ebox-selector-parse` | Compile a CSS-like selector to the ECSS AST. |
| `ebox-selector-match-node-p` | Match one built node against a selector or AST. |
| `ebox-selector-query-all` | Query an unmounted built tree in document order. |
| `ebox-selector-query-buffer` | Query one mounted runtime. |
| `ebox-selector-update-buffer` | Update all editable mounted matches and return a structured report. |
| `ebox-select-all` | Alias of `ebox-selector-query-buffer`. |
| `ebox-update-selector` | Alias of `ebox-selector-update-buffer`. |

## 6. Scrolling

`ebox-buffer-mode` installs `ebox-scroll-map`. The map routes line, page, and
wheel intent through the innermost semantic scroll owner before ordinary Emacs
scrolling.

The public commands are `ebox-scroll-down`, `ebox-scroll-up`,
`ebox-scroll-page-down`, `ebox-scroll-page-up`, `ebox-wheel-scroll-down`, and
`ebox-wheel-scroll-up`. `ebox-scroll-state` returns a read-only snapshot for a
numeric region id.

## 7. Measurement, cache, and build tools

| Function | Contract |
| --- | --- |
| `ebox-string-pixel-width` | Measure the first-line display width of a string. |
| `ebox-display-signature` | Return display inputs used for measurement-cache invalidation. |
| `ebox-clear-cache` | Clear Ebox measurement/render caches. |
| `ebox-byte-compile` | Compile active Ebox Elisp sources; restart Emacs to load the new bytecode. |
| `ebox-native-status` | Report native toolchain, module, ABI, and load status. |
| `ebox-native-build` | Build and install the optional native module asynchronously. |

The native module is an accelerator, never a correctness requirement. Ebox
does not build it during package load.

## 8. Facade inventory

`ebox-public-api` contains the stable facade entries. The following grouping
names every entry:

- Construction: `ebox-build`, `ebox-text-create`,
  `ebox-normal-layout-create`, `ebox-row-layout-create`,
  `ebox-column-layout-create`, `ebox-flex-layout-create`,
  `ebox-grid-layout-create`, `ebox-box-create`, `ebox-child-range`.
- Render/publication: `ebox-render`, `ebox-render-to-buffer`,
  `ebox-display-buffer`, `ebox-commit`, `ebox-buffer-set-observer`,
  `ebox-buffer-update-report`,
  `ebox-rerender-buffer-with-context`, `ebox-viewport-window-width`,
  `ebox-call-with-render-burst`, `ebox-render-burst-begin`,
  `ebox-render-burst-end`.
- Candidate/identity: `ebox-candidate-begin`, `ebox-candidate-replace`,
  `ebox-candidate-replace-range-ref`, `ebox-candidate-replace-root`,
  `ebox-candidate-replace-host-ref`, `ebox-candidate-patch-host-paint`,
  `ebox-region-ids`, `ebox-region-resolve`, `ebox-region-update`,
  `ebox-host-ref-bounds`, `ebox-host-ref-position`.
- Selectors: `ebox-selector-parse`, `ebox-selector-match-node-p`,
  `ebox-selector-query-all`, `ebox-selector-query-buffer`,
  `ebox-selector-update-buffer`, `ebox-select-all`, `ebox-update-selector`.
- Scroll: `ebox-buffer-mode`, `ebox-scroll-map`, `ebox-scroll-down`,
  `ebox-scroll-up`, `ebox-scroll-page-down`, `ebox-scroll-page-up`,
  `ebox-wheel-scroll-down`, `ebox-wheel-scroll-up`, `ebox-scroll-state`.
- Measurement/build: `ebox-string-pixel-width`, `ebox-display-signature`,
  `ebox-clear-cache`, `ebox-byte-compile`, `ebox-native-status`,
  `ebox-native-build`.

## 9. Verification

```sh
make load EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make compile EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make docs-contract-tests EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make dsl-tests EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make check EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
```
