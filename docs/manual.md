# ebox Manual

[中文](manual.zh-CN.md)

Ebox is the low-level Text/Box layout and buffer-rendering package. This guide
uses one public author grammar and keeps framework-integration details separate.
See the [API reference](manual.md) for the complete function
inventory.

## 1. Load Ebox

```elisp
(require 'ebox)
```

Loading Ebox does not create a buffer, enable a mode in the current buffer, or
build Rust.

## 2. Learn one author model

An Ebox document contains Text and Box nodes. The author grammar has exactly
seven entries:

| Entry | Meaning |
| --- | --- |
| `"text"` | Short form for one Text node. |
| `(text ... "text")` | Text with explicit text properties. |
| `(box ... CHILD...)` | A normal visual Box. |
| `(row ... CHILD...)` | A Box with simple horizontal child layout. |
| `(column ... CHILD...)` | A Box with simple vertical child layout. |
| `(flex ... CHILD...)` | A Box with Flex child layout. |
| `(grid ... CHILD...)` | A Box with Grid child layout. |

Children are always nested directly. A layout form is a Box with a selected
child-layout algorithm, not a different kind of visual object.

```elisp
(defvar ebox-guide-input
  (ebox-build
   '(column :padding ((lh 1) (ch 2))
            :border ((px 1) solid "#8A93A6")
            (text :color "#263244" "Research notes")
            (row :item-gap (ch 1)
                 (box :id "status" :background-color "#F4F6FB" "Inbox")
                 (box :background-color "#EEF2FF" "Archive")))))
```

`ebox-build` returns an opaque `CanonicalEboxInput`. It keeps the canonical
forest and its source generation together. Pass that value unchanged to the
render and publication functions; ordinary author code does not extract or
reassemble its internal nodes.

Use `box` with geometry but no child when an empty rectangular area is needed.
No extra node type is necessary.

### Prefer defaults and inheritance

Write only what changes the intended result. Omit redundant default values,
place shared text styles on an existing common parent, and keep only child
overrides. Reference panels still spell out the property they teach, even
when its value is the default.

Ebox inherits `:color`, `:font-family`, `:font-size`, `:font-weight`,
`:font-style`, `:text-align`, `:wrap-mode`, and `:visibility`. Geometry and
background colors do not inherit; an unpainted child can show its parent's
background. For example:

```elisp
(ebox-build
 '(column :width (ch 40) :color "#1F2328" :bgcolor "#FAF7F0"
          (box "Shared text color")
          (box :color "#B45309" "Local accent")
          (box :height (lh 1))))
```

Inheritance does not expand where a property may be authored. For example,
`:text-align` is declared on `box`; it cannot be moved onto a `row`, `column`,
`flex`, or `grid` merely because its value can inherit.

In this ordinary Column, the separator fills the available width and explicitly
reserves one line with `:height (lh 1)`. No width or repeated background is needed.
An otherwise empty Box with `auto` height has zero content height; use
`:height (lh 1)` when one blank line is intended. Padding and borders can still
add their own outer extent.
This is context-dependent: an auto-width child in a Row uses intrinsic width,
and Flex/Grid have their own item sizing rules. Do not replace `stretch` with
`auto` everywhere, or remove a default-looking value that overrides inherited
styles, a stylesheet, or another shorthand. Zero sides can often be omitted
with `:padding-inline` or `:padding-block` when no other declaration sets them.

## 3. Choose the layout that states the intent

Use `box` for ordinary content, `row` or `column` for direct one-axis
composition, `flex` when free space or wrapping matters, and `grid` for
two-dimensional tracks or explicit placement.

### Row and column

`row` and `column` accept `:item-gap` and `:cross-align`. Their children remain
ordinary Text or Box nodes.

```elisp
(ebox-build
 '(row :item-gap (ch 2) :cross-align center
       (box :width (ch 12) "Left")
       (box :width (ch 12) "Right")))
```

### Flex

Flex container properties belong to `flex`. Participation properties belong
directly to a child `box` because they describe the parent-child relationship.

```elisp
(ebox-build
 '(flex :width (px 480)
        :flex-flow (row wrap)
        :gap ((lh 1) (px 12))
        (box :flex (1 1 auto) "Primary")
        (box :flex-grow 2 "Secondary")))
```

### Grid

Grid placement is one-based. Tracks may be fixed, `auto`, fractional,
`minmax`, or `repeat` values. Placement properties also belong directly to a
child `box`.

```elisp
(ebox-build
 '(grid :width (px 640)
        :grid-template-columns ((px 200) (fr 1) (fr 1))
        :grid-template-rows ((lh 1) (lh 1))
        :gap ((lh 1) (px 12))
        (box :grid-column (1 :span 3) "Header")
        (box :grid-column 1 :grid-row 2 "Navigation")
        (box :grid-column 2 :grid-row 2 "Main")
        (box :grid-column 3 :grid-row 2 "Aside")))
```

## 4. Use geometry and paint properties

Box geometry uses explicit `(unit number)` values. The same syntax applies to
width, height, their minimum/maximum bounds, padding, margins, gaps, borders,
Flex basis, and fixed Grid tracks. Ebox implements a CSS sizing subset with an
Elisp data representation, not CSS strings such as `"80ch"`.

| Unit | Meaning |
| --- | --- |
| `(px 240)` | 240 pixels. |
| `(% 50)` | 50% of the property's containing-block reference size. |
| `(vw 100)` | 100% of the viewport width. |
| `(vh 100)` | 100% of the viewport height. |
| `(ch 80)` | 80 times the effective font's advance width for `0`. |
| `(lh 3)` | Three effective line heights. |

`ch` does not count arbitrary characters or CJK glyphs.
`1vw` and `1vh` each mean 1% of the corresponding viewport axis. A displayed
Ebox viewport is the target window's usable body area, excluding its mode line
and header line; a Playground preview therefore uses the preview window.

<a id="size-unit-constraints"></a>

### Unit constraints by property

The following table is the unit contract for all Ebox author entry points.
Inline means horizontal and block means vertical in Ebox's supported writing
mode. These axis restrictions deliberately narrow CSS's general length model.

| Value context | Allowed units | Properties |
| --- | --- | --- |
| Inline geometry | `px`, `ch`, `vw`, `%` | `width`, `min-width`, `max-width`; left/right and inline padding/margin; `column-gap`; Row `item-gap`; Grid column tracks. |
| Block geometry | `lh`, `vh`, `%` | `height`, `min-height`, `max-height`; top/bottom and block padding/margin; `row-gap`; Column `item-gap`; Grid row tracks. |
| Positioned offsets | Inline units for `left`; block units for `top` | Signed lengths and size expressions; `%` refers to the paint host's corresponding content axis. |
| Flex main size | The parent Flex's main-axis units | `flex-basis` and the basis in `(grow shrink basis)`; row directions use inline units, column directions use block units. |
| Border paint thickness | `px`, `ch`, `lh`, `vw`, `vh` | `border-width`, each side's border width, and the width component of border shorthands; percentages are forbidden. |

The same restrictions apply recursively to every branch of `calc`, `min`,
`max`, and `clamp`, and to nested Grid track functions. A disallowed unit is
an error when `ebox-build` constructs the tree, even if arithmetic would
cancel it or another branch would win. For example, `:height (px 24)`,
`:width (lh 3)`, and `:height (min (lh 2) (px 24))` are rejected.
Border thickness is a separate paint value, so `:border ((px 1) solid "red")`
is valid on all four sides.

Stylesheets and dynamic updates follow the same contract: after computed styles
are known and before layout, Ebox rechecks the parent Flex direction and child
basis. Invalid updates do not publish to an existing buffer. Numeric `:flex 1`
uses an implicit `(% 0)` basis, valid on either main axis; explicit bases still
follow the parent direction.

Shorthands are checked after expansion onto their sides or axes. A one-value
`padding`, `margin`, or `gap` must therefore be valid on both axes: use `%`
for such a shared length, or spell out the two axes, for example
`:padding ((lh 1) (ch 2))` and `:gap ((lh 1) (px 12))`.
Use `:padding-inline (px 12)` or `:padding-block (lh 1)` to set only one axis.

Percent widths refer to containing-block width; percent heights require a
definite containing-block height and otherwise follow the property's
indefinite-size rule. Percentage padding and margins on every side refer to
containing-block width. Border widths do not accept percentages.
Negative margins and `auto` margins are outside this subset; the current
buffer backend does not implement overlapping margin geometry.

| Property | Keywords | Default |
| --- | --- | --- |
| `width`, `height` | `auto`, `min-content`, `max-content`, `fit-content`, `stretch` | `auto` |
| `min-width`, `min-height` | `auto`, `min-content`, `max-content`, `fit-content`, `stretch` | `auto` |
| `max-width`, `max-height` | `none`, `min-content`, `max-content`, `fit-content`, `stretch` | `none` |

For a normal block root with an available viewport, `auto` width fills the
available space and `auto` height follows content. `min-content` and
`max-content` request intrinsic sizes. `fit-content` fits available space
between those intrinsic bounds; `stretch` fills available space with the
margin box. `none` removes a maximum-size constraint. Automatic minimums
depend on layout; an explicit `(px 0)` minimum allows an item to shrink below
its automatic content minimum on the inline axis. Use `(lh 0)` for the block
minimum. An empty Box with no padding, border, or explicit height has zero
height; `(box :height (lh 1))` explicitly reserves one blank line.

The four size functions compose units without evaluating Lisp during layout:

```elisp
'(column :width (min (% 100) (ch 80))
         :height (calc (- (vh 100) (lh 1)))
         (box :width (max (px 120) (% 25)) "Sidebar")
         (box :width (clamp (ch 20) (% 50) (ch 60)) "Body"))
```

`calc` accepts one arithmetic expression; `+` and `-` combine lengths, `*`
multiplies a length by a scalar, and `/` divides it by a nonzero scalar.
`min` and `max` choose from one or more permitted lengths. `clamp` takes
minimum, preferred, and maximum lengths. Functions may nest. Bare numbers inside math
are scalars, never implicit `ch` or `lh` lengths.

Units and functions remain data until layout, so viewport and containing-block
changes are resolved again. Floating-point intermediate results are preserved:
`33vw` of an 853-pixel viewport is 281.49 pixels before display quantization.
The buffer backend materializes block geometry in whole lines; fractional
line targets are quantized at that boundary. Vertical `px` lengths are not
part of the author contract. `:overflow hidden` clips excess vertical lines and
limits each content line to the measured content width. It retains the fitting
prefix without splitting supported text clusters; a glyph or image that cannot
fit is omitted as a whole. Fixed display spaces can be shortened to the exact
remaining pixel width. A cut glyph's remaining gap keeps its source faces,
including background paint, so
padding and borders retain their positions. This is pixel-width truncation,
not partial-glyph/image masking or automatic ellipsis. Omitted child text does
not leave its help, hover, pointer, or keymap active in the filler.

For example, `(box :width (ch 3) :wrap-mode none :overflow hidden "ABCDEFGHIJ")`
keeps only the prefix that fits three zero-glyph advances; with `visible`,
overflow may extend outside the computed width. Set `hidden` on the container
whose content boundary should be enforced. It applies to that container's
composed child output as well as its direct text. `scroll` provides vertical
scrolling and does not add horizontal scrolling.

Bare geometry numbers, one-element pixel lists, `viewport`, `viewport-height`,
`contain`, and parameterized `fit-content` are rejected. Even zero needs an
axis-appropriate unit: `(px 0)` inline or `(lh 0)` block. Grid `(fr n)` remains a track fraction; Grid placement and
Flex growth/shrink factors remain dimensionless numbers.

Text style declarations accept only font, foreground/background, and
text-decoration properties. Text also accepts the four native node capabilities
described below.
Padding, margin,
border, size, `:outer`, overflow, visibility, and wrapping policy belong only
to Box. Font and color on Box may feed inherited Text facts, but never give
Text Box geometry.

```elisp
(ebox-build
 '(box :width (px 420)
       :padding ((lh 1) (ch 2))
       :margin ((lh 0) (ch 1))
       :border ((px 1) solid "#8A93A6")
       :color "#263244"
       :background-color "#FFFFFF"
       "A readable panel"))
```

Use `:outer inline` or `:outer block` to state how a Box participates in its
parent. The child-layout algorithm still comes from the form name.

<a id="retained-layers"></a>

### Retained layers

Use positioning properties on existing Box forms to overlap content. Give the
host an explicit height when absolute children need a reserved canvas: they do
not increase its automatic flow size.

```elisp
(ebox-build
 '(box :width (ch 12) :height (lh 3)
       "ABCDEFGHIJKL\nabcdefghijkl\n0123456789ab"
       (box :position absolute :left (ch 2) :top (lh 1)
            :width (ch 5) :height (lh 1)
            :background-color "#334155" :color "#FFFFFF"
            "Panel")))
```

`:position relative` keeps the child's ordinary slot and moves only its paint.
`:position absolute` removes the child from normal, Row, Column, Flex, or Grid
flow and places it from the parent content origin. Signed `:left` uses inline
units; signed `:top` uses block units and is floored to whole host rows at final
placement. Both accept size expressions. A local host clips its composed output
to its canvas. Nested local groups are automatic: a child's high `:z-index`
cannot jump above a sibling of its host. Integer depths paint low to high;
normal content precedes positioned content at equal depth, and equal-depth
positioned boxes follow document order.

The upper box covers its content, padding, and border, including blanks, while
its margin leaves the lower content visible. Visible text retains its native
help, pointer, hover, and keymap properties; covered text contributes none of
those interactions. The retained lower node and its semantic ID still exist.
Updates to it become visible with their latest content and properties when
the covering box moves or becomes hidden.

Use a root layer to place a panel beyond a clipped local container while
keeping its logical parent and inherited styles:

```elisp
(ebox-build
 '(box :width (ch 20) :height (lh 4)
       (box :height (lh 1) :overflow hidden
            (box :id "trigger" :width (ch 6) "Open")
            (box :id "panel" :position absolute :layer root
                 :anchor "trigger" :placement bottom-start
                 :width (ch 8) :height (lh 2)
                 "Choice A\nChoice B"))))
```

`:layer root` selects the root content canvas as the paint target. It does not
reparent the panel for selectors, inheritance, or region updates. `:anchor`
uses a unique semantic ID in the paint host's logical subtree. Both properties
require absolute positioning. Placements are `bottom-start`, `bottom-end`,
`top-start`, and `top-end`; offsets adjust the requested origin. Panels flip
vertically if the opposite side fits, then shift within the host canvas.
Missing or invisible anchors do not paint a panel; ambiguous IDs and placement
dependency cycles are errors.

Composition uses horizontal pixels and one shared vertical text-row grid.
Positioned subtrees must have the same effective font line height as their
host. Whole supported clusters survive cuts; partially covered glyphs/images
are replaced with noninteractive space retaining the source faces (including
background paint), and fixed display spaces can be shortened. Blank canvas
outside the source remains neutral.
There is no alpha blending, half-glyph masking, or child frame. Layered trees
fall back to Elisp when native reflow cannot represent them.

Publication remains a TP transaction, including hidden-node updates and
rollback. Fixed-footprint local changes can recompose only the affected host;
geometry changes and root-layer dependencies may require broader work. No
per-update latency or universal local-update guarantee is implied. Run
`make test` for the focused contract. The separate `ebox-playground`
package provides `layer-minimal.ebox` and `layer-reference.ebox`; batch tests
do not establish GUI visual parity or remote CI success.

### Wrapping and the optional EKP dependency

`:wrap-mode word` wraps ordinary words and permits character breaks for CJK;
`char` breaks at the common text-cluster boundaries supported by Ebox; `none`
keeps explicit newlines without adding soft line breaks. `kp` delegates
paragraph layout to the independent [EKP package](https://github.com/Kinneyzhang/emacs-kp)
using the Knuth–Plass algorithm. The mode belongs to a Box and is inherited by
its text content.

Install EKP 1.0.0 or newer, or add its source directory to `load-path`, before
using `:wrap-mode kp`. It is an optional dependency loaded on demand; ordinary
Ebox layouts require only ECSS and TP. Choosing `kp` without a compatible EKP
signals an installation or update error; install EKP or explicitly select
another mode. Ebox never silently switches to word wrapping. The EKP accelerator and the Ebox Rust
reflow module are separate optional modules; enabling one does not install the
other.

```elisp
(add-to-list 'load-path "/path/to/ekp")
(ebox-render
 (ebox-build '(box :width (ch 40) :wrap-mode kp :overflow hidden
                   "Knuth–Plass considers the paragraph when choosing line breaks.")))
```

Common combining marks, variation selectors, emoji modifiers, ZWJ sequences,
and regional-indicator pairs are kept together by Ebox's text-cluster handling.
This is not complete Unicode grapheme segmentation or browser-level
bidirectional layout. Font shaping and glyph availability remain dependent on
Emacs, the selected fonts, and the window system.

<a id="native-node-interaction"></a>
### Native node interaction

Text and every Box form accept `:help-echo`, `:pointer`, `:hover-style`, and
`:keymap`. These are explicit node capabilities outside the CSS cascade.
For example, render a Box with dynamic help, a hand pointer, hover paint, and
one callback for both mouse and keyboard activation:

```elisp
(ebox-render-to-buffer
 "*Ebox Interaction*"
 (ebox-build
  `(box :id "action" :padding ((lh 1) (ch 2))
        :border ((px 1) solid "#5893A3")
        :help-echo ,(ebox-help-create
                     (lambda ()
                       (format-time-string "Help requested at %H:%M:%S")))
        :pointer hand
        :hover-style (:color "#FFFFFF" :background-color "#286477"
                      :text-decoration-line underline)
        :keymap ,(ebox-keymap-create :activate #'describe-mode)
        "Click or press RET / SPC here to describe this buffer's mode.")))
```

`:help-echo` accepts a string, a native function with arguments
`(WINDOW OBJECT POSITION)`, or `nil`. Prefer `ebox-help-create` to adapt a
zero-argument business function returning a string or `nil`; Ebox supplies the
hovered buffer's context. Emacs calls the function when requesting help; the DSL
does not call it while building the tree. `:pointer` accepts
`text`, `arrow`, `vdrag`, `modeline`, `hand`, `hdrag`, `nhdrag`, `hourglass`,
or `nil`. Help display and exact pointer appearance depend on the user's Emacs
settings and window system.

`:hover-style` accepts `nil` or an Ebox paint plist containing only `:color`,
`:background-color`, `:text-decoration-line`, `:text-decoration-color`, and
`:text-decoration-style`. Within a rendered line, one declaring node's text
and padding share a native `mouse-face`, with unspecified attributes taken from
that node's base style. Differently colored child text covered by this hover
uses the same hover base. Physical left/right borders are excluded from hover;
horizontal border strokes remain intact. Font metrics and geometry do not change.
The [API reference](manual.md)
defines the accepted values. Ebox compiles this plist to native `mouse-face`;
there is no arbitrary native-property passthrough.

Box help, pointer, and keymap cover its rendered content, padding, and border,
excluding that Box's margin and structural newlines; hover follows the rule
above. A nested Text or Box can replace
each capability with an explicit value. Explicit `nil` blocks an enclosing
value; an omitted property leaves the enclosing surface coverage in place.

`:keymap` accepts a native Emacs keymap or `nil`. Prefer `ebox-keymap-create`:
its `:activate` callback takes no arguments and handles `RET`, `[return]`, `SPC`,
and `[mouse-1]`. Rapid double and triple clicks each activate once per release;
primary-button press and drag events do nothing, preserving point and selection
instead of starting native word or line selection. Use `:bindings` for an alist
of key-description strings or event
vectors paired with zero-argument callbacks. The helper uses the event window's
buffer for mouse callbacks, so a callback can directly update a semantic ID
with `(ebox-region-update "action" :help-echo "Activated")`.
Explicit bindings can override the repeated-click, press and drag defaults.

Move point into the surface to use keyboard bindings. Optional commands
`ebox-next-interaction` and `ebox-previous-interaction` move between declaring
nodes that currently render a usable keymap. Each owner contributes one stop,
even if its map covers padding or several lines; explicit child maps are
separate stops. Empty maps, explicit `nil`, and invisible or clipped-away
content do not add stops. Navigation follows the current committed buffer, so
updates do not require a separate refresh. At a boundary it reports a user error
without wrapping or moving point. These commands add no bindings automatically.
For example, opt in for buffers using `ebox-buffer-mode`:

```elisp
(keymap-set ebox-scroll-map "TAB" #'ebox-next-interaction)
(keymap-set ebox-scroll-map "<backtab>" #'ebox-previous-interaction)
```

Raw native keymaps are also accepted; their mouse commands must handle the
event's target buffer themselves. Ebox uses native command dispatch and does
not create an application state or focus-management system. A hand pointer
alone does not bind a click command.

The Playground's [interaction lab](https://gitea.gklazycat.heiyu.space/geekinney/ebox-playground/src/branch/main/README.md#native-interaction-lab)
keeps its business functions and state in `interaction-reference.el`, with its
layout in `interaction-reference.ebox`. It demonstrates callbacks, nested
overrides, and replacing or removing all four capabilities through public
region updates.

## 5. Render and publish

`ebox-render` returns propertized text without changing a live buffer.
`ebox-render-to-buffer` mounts a retained TP surface and returns its buffer.
Both functions, and `ebox-display-buffer`, accept the opaque value returned by
`ebox-build`.

```elisp
(ebox-render ebox-guide-input)
(ebox-render-to-buffer "*Ebox Guide*" ebox-guide-input)
```

To display the result as well, use `ebox-display-buffer`. It finishes rendering
before asking Emacs to place the buffer, respects `display-buffer-alist`, and
accepts the same optional action argument as native `display-buffer`:

```elisp
(ebox-display-buffer "*Ebox Guide*" ebox-guide-input
                     '(display-buffer-pop-up-window))
```

It returns the buffer and does not select the result or delete other windows.
A rendering error leaves the window layout untouched. A custom display action
can still have its own window effects; if it fails after publication, the
successfully rendered buffer remains available. Use `ebox-render-to-buffer`
when the caller owns display placement entirely.

Build a fresh canonical input and use `ebox-commit` for an atomic update:

```elisp
(ebox-commit
 "*Ebox Guide*"
 (ebox-build
  '(column :padding ((lh 1) (ch 2))
           (text "Updated notes")
           (box :key body "The new input is caller-owned."))))
```

Validation, rendering, or publication failure leaves the previous buffer and
runtime state intact. `ebox-buffer-update-report` returns a defensive copy of
the last successful update report.

## 6. Query and update a mounted surface

`:id`, `:class`, and `:key` are author metadata. Selectors use ECSS semantics.
In the target mounted buffer, pass the semantic `:id` directly:

```elisp
(with-current-buffer "*Ebox Guide*"
  (ebox-region-update "status" :color "#166534"))
```

For an explicit buffer address, resolve an `:id` to an opaque, surface-scoped
handle:

```elisp
(let ((handle (ebox-region-resolve "*Ebox Guide*" "status")))
  (ebox-region-update handle :color "#166534"))
```

The same API replaces native capabilities on Text or Box regions. For the
interaction example above:

```elisp
(with-current-buffer "*Ebox Interaction*"
  (ebox-region-update "action" :help-echo "Updated help" :pointer 'arrow
                      :hover-style '(:background-color "#F6D6AB"))
  (ebox-region-update "action" :help-echo nil :pointer nil
                      :hover-style nil :keymap nil))
```

Update arguments are evaluated Elisp, so literal symbols and plists need
quotes, unlike properties inside already quoted DSL data. Omitted update
properties stay unchanged. Explicit `nil` clears that capability and blocks
an enclosing value.
Ebox snapshots keymaps; replace `:keymap` to publish new bindings instead of
mutating the original map. Clearing a node keymap leaves ordinary buffer and
global bindings available.

`ebox-selector-query-buffer` returns document-ordered matches from a mounted
buffer. `ebox-selector-update-buffer` applies one style update to all editable
matches. Numeric region ids are diagnostic render metadata, not stable update
handles.

For one action that makes several region updates, group them:

```elisp
(ebox-call-with-update-batch
 (lambda ()
   (ebox-region-update "status" :help-echo "Ready")
   (ebox-region-update "status" :color "#166534")
   'ready)
 (get-buffer "*Ebox Guide*"))
```

The callback runs in the supplied buffer, or the current buffer when omitted,
and the helper returns `ready` here. It flushes its own nonempty batch once;
inside an existing batch it leaves the flush to the outer owner. A nonlocal
exit restores the pending state from before this call, and a failed owned
flush preserves the last committed surface. This does not undo arbitrary
business side effects in the callback.

## 7. Resize and scroll

When content exceeds a finite height, `:overflow scroll` creates an internal
scroll window. Keyboard scrolling targets point; wheel and trackpad scrolling
target the mouse position carried by the event. Remaining distance passes
through enclosing scroll owners from inner to outer, then to ordinary Emacs
scrolling. Events over another column, outside a box, or on the mode line do
not select an unrelated scroll box elsewhere on the page.

```elisp
(ebox-build
 '(box :id log :width (px 420) :height (lh 8) :overflow scroll
       "line 1\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7\nline 8\nline 9"))
```

Visible mounted buffers follow one chosen display window. Each mounted buffer
owns one viewport layout: showing the same buffer in two windows with different
widths does not provide two independent layouts. Mount the same canonical input
in separate buffers when each view needs its own width. Integrations may apply
an explicit viewport, measured in pixels horizontally and lines vertically,
with:

```elisp
(ebox-rerender-buffer-with-context
 (get-buffer "*Ebox Guide*") 800 30)
```

## 8. Public API

The supported API inventory, calling signatures and usage notes are in the
Commentary of [`ebox.el`](../ebox.el). Unlisted symbols are internal, regardless
of naming. This manual explains workflows and integration contracts.

## 9. Verification

```sh
make load EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make compile EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make test EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make check EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
```

## Framework integration contract

Ebox provides framework SPI v2 through `(require 'ebox)`. This interface is
for framework implementers such as ETAF; application code normally uses the
render/update API described above. Query `ebox-framework-spi-capabilities` and
validate the immutable provider with `ebox-framework-spi-validate-provider` before
retaining its public operation descriptors. Do not read private provider fields.

| Operation | Input and result |
| --- | --- |
| `ebox-framework-spi-initial` | An unmounted buffer, canonical input and a stage/rollback callback pair; returns the completed report also supplied to the callbacks. It cannot join an outer TP transaction. |
| `ebox-framework-spi-update` | A mounted buffer, canonical input or candidate, and a stage/rollback pair; returns the same report object observed by the stage callback. |
| `ebox-unmount-buffer` | Releases the retained mount so a fresh initial generation can be created. |

The framework owns application state; Ebox owns layout/runtime indexes; TP owns
buffer publication and the transaction. Stage callbacks run after provisional TP
and Ebox state agree. Rollback runs framework rollback, then Ebox state restoration,
then TP restoration. A failed initial mount restores editor custody, including text,
point, mark, narrowing, overlays, undo and modified state. Killing the buffer remains
authoritative. Post-accept observer/retirement failures are diagnostics, not a reason
to pretend a committed publication rolled back. Callers must supply both callbacks
and propagate failure; they must not select a second writer as a fallback.

```elisp
(require 'ebox)
(let ((buffer (generate-new-buffer " *framework-example*")))
  (unwind-protect
      (progn
        (ebox-framework-spi-validate-provider (ebox-framework-spi-capabilities))
        (ebox-framework-spi-initial buffer (ebox-build '(box "Initial"))
                                    #'ignore #'ignore)
        (ebox-framework-spi-update buffer (ebox-build '(box "Updated"))
                                   #'ignore #'ignore)
        (with-current-buffer buffer (buffer-string)))
    (ebox-unmount-buffer buffer)
    (kill-buffer buffer)))
```

`tests/acceptance.json` lists the maintained public API acceptance scenarios.
Consumers link to this contract instead of maintaining another copy of its ordering.
