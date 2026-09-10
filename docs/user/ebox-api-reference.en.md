# Ebox public API reference

[中文](ebox-api-reference.zh.md)

This reference describes the current public boundary of the standalone Ebox
package. It separates the ordinary author path from the evaluated typed API
used by framework integrations. Names beginning with `ebox--` are private.

Ebox requires Emacs 29.1 or newer, ECSS 0.1.0 or newer, and TP 2.0.0 or newer.
EKP 1.0.0 or newer is an optional dependency required for `:wrap-mode kp`;
`word`, `char`, and `none` do not load it. Missing or incompatible EKP signals
an actionable error instead of silently changing the wrapping algorithm.
See [installation](../../README.md#install) for source loading and dependency roles.

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

`ebox-build` returns one opaque `CanonicalEboxInput`. It atomically carries the
ordered canonical forest and the source generation that owns its author facts.
Ordinary author code passes that value unchanged to Ebox render/publication
functions; it does not extract a node or construct a source index.

```elisp
(ebox-build
 '(column :padding ((lh 1) (ch 2))
          (box :id "status" :color "#166534" "Ready")
          (row :item-gap (ch 1)
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
| Layer placement | `:position`, `:left`, `:top`, `:z-index`, `:layer`, `:anchor`, `:placement` |

`hidden` enforces the content width after composing children, preserving whole
supported text clusters and excluding the container's own padding and border
from the clipping area. Clipped-away child properties are removed with their
text. Partial display spaces can be shortened; oversized glyphs/images are
omitted, not pixel-masked. Vertical clipping uses whole lines. `visible` allows
overflow, and `scroll` provides vertical scrolling. No ellipsis or horizontal
scrolling is implied.

Geometry values use explicit `(unit number)` lists: `(px 240)`, `(% 50)`,
`(vw 100)`, `(vh 100)`, `(ch 80)`, and `(lh 3)`. Each property accepts only
the units in the [shared unit-constraint table](ebox-user-guide.en.md#size-unit-constraints);
lengths cannot cross from one geometry axis to the other. CSS strings, bare lengths,
singleton pixel lists, and the old viewport/contain keywords are rejected.
Zero lengths also require a permitted unit. Border widths use their independent
paint-thickness rule and reject
percentages: `:border ((px 1) solid "#687386")`. Dimensionless values such as
Flex factors and Grid indices remain numbers.

| Properties | Accepted keywords | Default |
| --- | --- | --- |
| `width`, `height`, `min-width`, `min-height` | `auto`, `min-content`, `max-content`, `fit-content`, `stretch` | `auto` |
| `max-width`, `max-height` | `none`, `min-content`, `max-content`, `fit-content`, `stretch` | `none` |

The composable size functions are `calc`, `min`, `max`, and `clamp`, for example
`(calc (- (vh 100) (lh 1)))` and `(clamp (ch 20) (% 50) (ch 80))`.
`fit-content` is only a bare keyword; it never accepts parameters.
Property validation belongs to Ebox; all function branches, expanded shorthands,
Grid tracks, and Flex bases are checked against their property or parent axis
when the tree is built. Invalid context/value combinations signal errors
immediately. See the [geometry section of the user
guide](ebox-user-guide.en.md#4-use-geometry-and-paint-properties) for percentage
references, font units, arithmetic rules, and whole-line vertical display
quantization. This is a CSS semantic subset, not a browser layout engine.

### Retained layer placement

These non-inherited geometry properties apply to `box`, `row`, `column`,
`flex`, and `grid`; Text does not accept them. Existing author tags are unchanged.

| Property | Accepted value | Default |
| --- | --- | --- |
| `:position` | `static`, `relative`, `absolute` | `static` |
| `:left` | Signed inline length (`px`, `ch`, `vw`, `%`) or size expression | `(px 0)` |
| `:top` | Signed block length (`lh`, `vh`, `%`) or size expression | `(lh 0)` |
| `:z-index` | Integer, including negative values | `0` |
| `:layer` | `local`, `root` | `local` |
| `:anchor` | Semantic `:id` as a symbol or string, or `nil` | `nil` |
| `:placement` | `bottom-start`, `bottom-end`, `top-start`, `top-end` | `bottom-start` |

`static` uses ordinary flow. `relative` keeps its flow slot and shifts its paint
by `:left` and `:top`. `absolute` contributes no normal-flow size or slot and
uses the parent content origin, or the root content canvas for `:layer root`.
Offsets use that paint host's font and containing dimensions; `%` uses width
for `:left` and height for `:top`. Fractions survive length resolution; the
final vertical offset is floored to the host's whole text rows.

Each local host composes its children as one group. Within a group, smaller
`:z-index` values paint first; at equal depth, normal content paints before
positioned content, and positioned siblings follow logical document order.
A nested child's depth does not escape its local group. A painted Box is
opaque across its content, padding, and border, including blank space; its
margin is excluded. Paint is clipped to the host canvas.

`:layer root` changes the paint target while preserving the logical parent,
selectors, inheritance, and retained identity. Both `:layer root` and a non-nil
`:anchor` require `:position absolute`. Anchors resolve a unique semantic ID in
the paint host's logical subtree and use its visible bounds. The panel starts
above/below and at the start/end edge as requested, flips vertically when the
opposite side fits, then shifts inside the canvas. Missing or invisible anchors
produce no panel paint; ambiguous IDs and cyclic placement dependencies signal
an error before publication.

This is an opaque text compositor: horizontal positions are pixels, vertical
positions share the host's row grid. Positioned descendants must share their
host's effective font line height. Whole supported text clusters and display
units survive clipping; partial glyphs/images become neutral space. There is
no alpha blending, partial-glyph masking, or child-frame rendering. Layered
trees use Elisp when the native representation cannot express their placement.
See the [layer guide](ebox-user-guide.en.md#retained-layers) for examples and
retained update behavior.

### Native node capabilities

`text`, `box`, `row`, `column`, `flex`, and `grid` accept these four explicit
node properties. They are separate from CSS declarations and do not participate
in the stylesheet cascade.

| Property | Accepted value | Native surface property |
| --- | --- | --- |
| `:help-echo` | `nil`, a string, or a function called by Emacs with `(WINDOW OBJECT POSITION)` | `help-echo` |
| `:pointer` | `nil`, `text`, `arrow`, `vdrag`, `modeline`, `hand`, `hdrag`, `nhdrag`, or `hourglass` | `pointer` |
| `:hover-style` | `nil` or an Ebox paint plist containing only `:color`, `:background-color`, `:text-decoration-line`, `:text-decoration-color`, and `:text-decoration-style` | Compiled `mouse-face` |
| `:keymap` | `nil` or a native Emacs keymap whose bindings use ordinary interactive commands | `keymap` |

Hover colors use color strings; `:text-decoration-color` also accepts
`currentColor`. `:text-decoration-line` accepts `none`, `underline`, `overline`,
`line-through`, or a nonempty list of distinct decoration lines without `none`.
`:text-decoration-style` accepts `solid`, `double`, `dotted`, `dashed`, or `wavy`.
Hover styles cannot change font metrics, geometry, spacing, or layout. Ebox compiles
the restricted paint plist; a raw face or arbitrary native property plist is
not an author input. There is no `:tps`, `:local-map`, or raw `:mouse-face` input.

Within a rendered line, text and padding covered by the same hover owner
(the node declaring `:hover-style`) share one native `mouse-face`. Unspecified
hover attributes use that owner's base style. Child text under that hover
therefore uses the owner's unspecified attributes even if its normal text color
differs. An explicit child hover style creates its own hover region; `nil`
blocks the enclosing hover. Physical left/right borders are excluded from
hover highlighting, and horizontal border strokes keep their own paint.

A Box's help, pointer, and keymap surface includes rendered content, padding,
and border, excluding its own margin and structural newlines; hover follows
the coverage above. Text capabilities apply to its rendered
text. At each nested position, an explicit child value takes precedence for
that capability. An explicit `nil` blocks the enclosing value; an omitted
property leaves enclosing surface coverage in place.

`ebox-help-create` adapts a zero-argument business function into a native
`(WINDOW OBJECT POSITION)` help callback. The business function returns a string
or `nil` and runs in the hovered buffer's context. Point and the selected window
are unchanged. It is not called until Emacs requests help. For example:

```elisp
(ebox-help-create (lambda () (format "Help for %s" (buffer-name))))
```

Raw native help functions are also supported. Help functions are retained as
functions and called by Emacs when help is requested, rather than evaluated
while building the DSL. Use backquote and
comma to insert a computed function or keymap value. Pointer and help display
follow the user's Emacs settings and window system. A pointer shape supplies
no command binding by itself.

`ebox-keymap-create` is the recommended callback-to-keymap helper:

```elisp
(ebox-keymap-create
 :activate (lambda () (message "Activated"))
 :bindings (list (cons "?" (lambda () (message "Action help")))))
```

`:activate` accepts a zero-argument function and binds it to `RET`, `[return]`,
`SPC`, and `[mouse-1]`. Double and triple primary-button releases also activate
once per click. Primary-button press and drag events, including their double
and triple variants, do nothing by default, avoiding native text selection.
`:bindings` accepts an alist from key-description strings
or event vectors to zero-argument functions. Both options are optional; `nil`
omits their bindings. Duplicate keys and overlapping key prefixes are errors,
including overlaps with the four primary activation keys. Explicit bindings
can override the repeated-click, press and drag defaults. The helper returns a native Emacs
keymap; callbacks remain literal until their command is invoked. For mouse
events, the helper obtains the event window and runs the callback in its buffer.
It does not select that window or move point. Keyboard callbacks run in the
current buffer, using native dispatch at point.

Raw native keymaps remain supported. Their mouse commands must obtain the
target window from the event and operate in that window's buffer themselves.
`ebox-next-interaction` and `ebox-previous-interaction` are optional navigation
commands, each accepting an optional integer count (default one). Negative
counts reverse direction and zero leaves point unchanged. Each declaring node
with a command-bearing keymap contributes one stop at its first accessible
rendered character, including inherited coverage; explicit child maps form
separate stops. From inside an owner, navigation skips that owner. It respects
narrowing and invisibility, ignores ordinary buffer/overlay/global maps, and
uses the current committed output after updates or scrolling. A missing target
signals `user-error` without moving point; commands do not wrap or bind keys.
Menu enable forms and filters are not evaluated, so a declared command can
remain a stop when its application dynamically disables a menu item.
Navigation moves point only; Ebox provides no separate application state or
focus-management system.
See the [interaction guide](ebox-user-guide.en.md#native-node-interaction) for
a runnable example.

## 2. Evaluated typed construction

Frameworks that already own author parsing can use the evaluated integration
API. This API is not a second author grammar. One `ebox-source-builder` owns
the complete source generation; every typed node carries a handle from that
builder and node-owned facts projected from the same normalized declarations.
The final `CanonicalEboxInput` transports the forest and sealed source index as
one value:

```elisp
(let* ((builder (ebox-source-builder-create))
       (root-declarations nil)
       (left-declarations nil)
       (right-declarations nil)
       (root-handle
        (ebox-source-builder-bind
         builder :declarations root-declarations))
       (left-handle
        (ebox-source-builder-bind
         builder :declarations left-declarations))
       (right-handle
        (ebox-source-builder-bind
         builder :declarations right-declarations))
       (left
        (ebox-text-create
         :value "Left"
         :source-handle left-handle
         :owned-facts
         (ebox-canonical-facts-from-declarations
          'text left-declarations)))
       (right
        (ebox-text-create
         :value "Right"
         :source-handle right-handle
         :owned-facts
         (ebox-canonical-facts-from-declarations
          'text right-declarations)))
       (root
        (ebox-box-create
         :layout (ebox-row-layout-create
                  :item-gap '(ch 1) :cross-align 'center)
         :children (list left right)
         :source-handle root-handle
         :owned-facts
         (ebox-canonical-facts-from-declarations
          'row root-declarations))))
  (ebox-canonical-input-create
   (list root)
   (ebox-source-builder-finish builder)))
```

- `ebox-source-builder-create` begins exactly one mutable source assembly.
- `ebox-source-builder-bind` stores normalized source facts and returns an
  identity-only opaque handle.
- `ebox-source-builder-finish` detaches and seals the builder's immutable fact
  index. A sealed builder rejects further mutation.
- `ebox-canonical-facts-from-declarations` projects the node-owned facts from
  the same normalized declarations passed to the source builder.
- `ebox-text-create` requires `:value`, `:source-handle`, and `:owned-facts`.
- `ebox-normal-layout-create` creates Normal LayoutConfig.
- `ebox-row-layout-create` and `ebox-column-layout-create` accept
  `:item-gap` and `:cross-align`.
- `ebox-flex-layout-create` creates a validated Flex LayoutConfig.
- `ebox-grid-layout-create` creates a validated Grid LayoutConfig.
- `ebox-box-create` requires `:layout`, `:source-handle`, and `:owned-facts`;
  it accepts a `:children` list of typed nodes.
- `ebox-canonical-input-create` combines an ordered node forest with the one
  source index that owns every referenced handle; this boundary validates the
  exact set and seals source order from the forest's final preorder, independent
  of bottom-up construction order.
- `ebox-canonical-input-root-host-ref` returns the detached publication address
  of a validated single-root input without exposing its source handle.
- `ebox-canonical-input-roots` returns a shallow, read-only copy of the exact
  top-level roots. It does not import source facts into another candidate.
- `ebox-canonical-input-import-roots` accepts only exact, unique top-level roots
  from that input and an open source builder. It imports facts only for the
  selected subtrees, preserves their node, source-handle, and immutable-record
  identities, and never adopts facts from unselected roots.
- `ebox-canonical-input-equal-p` compares the complete canonical forest, Range
  anchors, source identities, and immutable source facts for no-op proofs.

These source builders, fact/input constructors, and typed node/layout
constructors belong only to the evaluated integration contract. Their fields
are not author properties or alternate DSL syntax.

Node inspection functions are `ebox-node-kind`, `ebox-text-node-p`,
`ebox-box-node-p`, `ebox-node-source-handle`, `ebox-text-node-value`,
`ebox-box-node-layout`, `ebox-box-node-children`, and
`ebox-box-node-range-anchors`. They are public from the typed module even
though the facade inventory below focuses on application entry points.

## 3. Rendering and retained publication

| Function | Contract |
| --- | --- |
| `ebox-render` | Accept a single-root `CanonicalEboxInput` and return a propertized string without publishing a live buffer. |
| `ebox-render-to-buffer` | Accept a single-root `CanonicalEboxInput`, mount a retained TP surface, enable `ebox-buffer-mode`, and return the buffer. Its optional plist accepts only `:observer FUNCTION`. |
| `ebox-unmount-buffer` | Release a mounted Ebox/TP surface, observers, retained indexes, and runtime authority from a live buffer. |
| `ebox-display-buffer` | `(BUFFER-OR-NAME INPUT &optional ACTION)` renders a single-root `CanonicalEboxInput`, then calls native `display-buffer` with `ACTION` and returns the buffer. Ebox does not delete other windows or select the result. |
| `ebox-commit` | Atomically publish a single-root `CanonicalEboxInput` or a one-shot logical candidate returned by `ebox-candidate-begin`. |
| `ebox-buffer-set-observer` | Set or remove one function-valued observer on an already mounted buffer. |
| `ebox-buffer-update-report` | Return a defensive copy of the last successful update report. |
| `ebox-rerender-buffer-with-context` | Apply explicit viewport width and optional height while retaining identity. |
| `ebox-viewport-window-width` | Return Ebox's display-safe pixel width for a window. |

`ebox-display-buffer` respects `display-buffer-alist` and native action
precedence. Rendering failure occurs before any display call. Window placement
belongs to the selected Emacs display action; Ebox does not roll back a
successfully published buffer if a caller-supplied display action fails.

Each mounted buffer has one viewport layout, shared by all windows showing it.
Independent window widths require separate mounted buffers. Explicit viewport
updates change that buffer's shared layout.

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
| `ebox-region-update` | Apply supported mutable style, scroll, or native node capability properties through one retained transaction. Accept an opaque region handle or a semantic `:id` in the current mounted buffer. |
| `ebox-call-with-update-batch` | `(CALLBACK &optional BUFFER)` runs a zero-argument callback in the target buffer and groups its queued region updates; return the callback's value. |
| `ebox-child-range` | Framework integration only: build a nonvisual, addressable child Range descriptor while assembling a typed canonical input. |
| `ebox-candidate-begin` | Capture the exact current mounted generation in a one-shot candidate. |
| `ebox-candidate-replace` | Replace one candidate node address from a single-root `CanonicalEboxInput`. |
| `ebox-candidate-replace-range-ref` | Replace one transparent child Range payload from a forest-valued `CanonicalEboxInput`. |
| `ebox-candidate-replace-root` | Replace the candidate's private root address from a single-root `CanonicalEboxInput`. |
| `ebox-candidate-replace-host-ref` | Replace one framework-owned opaque host reference from a single-root `CanonicalEboxInput`. |
| `ebox-candidate-patch-host-paint` | Compare previous and next single-root canonical inputs; record a proven paint-only host patch or return nil when replacement is required. |
| `ebox-host-ref-bounds` | Return current margin-free bounds for an opaque host reference. |
| `ebox-host-ref-position` | Return its first current position. |

Handles and reported positions belong to one live publication generation.
Resolve them again after their object is removed. A candidate is sealed by
commit and cannot be reused.

Within a callback for the target mounted buffer, a direct update can use the
semantic ID: `(ebox-region-update "action" :help-echo "Updated help")`.
Semantic IDs accept strings, non-`nil` symbols, and integers; an integer author
`:id` is distinct from Ebox's diagnostic numeric region metadata.
Use `ebox-region-resolve` with an explicit buffer when addressing another
mounted buffer, then pass that handle to `ebox-region-update`.

`ebox-region-update` accepts `:help-echo`, `:pointer`, `:hover-style`, and
`:keymap` on Text and Box regions, with the same validation as construction.
Passing a new value replaces that capability; passing `nil` clears it and
blocks an enclosing value. Omitted properties are unchanged. Replace the
`:keymap` property when publishing new bindings: Ebox snapshots keymaps, so
later caller-side mutations do not update a mounted surface. Clearing it removes that
node's keymap; ordinary Emacs buffer and global bindings still apply.

### Grouping region updates

`ebox-call-with-update-batch` defaults `BUFFER` to the current buffer and runs
`CALLBACK` there. If it starts the batch, it flushes once after a normal return
when changes are pending. An empty or unchanged callback publishes nothing and
preserves the last successful update report. The helper returns the callback's
value unchanged after a successful flush.

If a batch is already active in that buffer, the helper joins it without
flushing; the outer owner decides when to publish. On an error, quit, or other
nonlocal exit, the helper discards its own queued changes and restores the
outer batch's pending state as it was on entry. A failed flush of a batch owned
by this helper discards its unpublished changes; the existing TP transaction
restores the previously committed buffer, runtime, revision, and report.

The rollback scope is the queued `ebox-region-update` work in `BUFFER`.
Assignments to application variables, file writes, and other business side
effects in the callback are not reverted. Keep explicit
`ebox-incremental-begin-batch` / `ebox-incremental-flush` lifecycle calls outside
the callback; those lower-level calls retain their own retry semantics.

The author DSL has no Range form. Ordinary authors compose direct Text/Box
children and never call `ebox-child-range`; Range addresses exist only for
frameworks that already own semantic child ranges and candidate updates.

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
  `ebox-grid-layout-create`, `ebox-box-create`.
- Interaction: `ebox-help-create`, `ebox-keymap-create`,
  `ebox-next-interaction`, `ebox-previous-interaction`.
- Render/publication: `ebox-render`, `ebox-render-to-buffer`,
  `ebox-unmount-buffer`, `ebox-display-buffer`, `ebox-commit`,
  `ebox-buffer-set-observer`,
  `ebox-buffer-update-report`,
  `ebox-rerender-buffer-with-context`, `ebox-viewport-window-width`,
  `ebox-call-with-render-burst`, `ebox-render-burst-begin`,
  `ebox-render-burst-end`.
- Candidate/identity: `ebox-candidate-begin`, `ebox-candidate-replace`,
  `ebox-candidate-replace-range-ref`, `ebox-candidate-replace-root`,
  `ebox-candidate-replace-host-ref`, `ebox-candidate-patch-host-paint`,
  `ebox-child-range`,
  `ebox-region-ids`, `ebox-region-resolve`, `ebox-region-update`,
  `ebox-call-with-update-batch`,
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
make interaction-tests EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make dsl-tests EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make check EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
```
