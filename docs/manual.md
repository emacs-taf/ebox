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
`:font-style`, `:text-align`, and `:wrap-mode`. Geometry, background colors,
and `:visibility` do not inherit; an unpainted child can show its parent's
background, and a hidden box suppresses its whole subtree's ink without
changing any descendant's computed style. For example:

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
text-decoration properties. Text also accepts the native node capabilities
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
Positioned descendants must not exceed their containing host's effective font
line height; smaller glyphs are allowed inside the fixed row. Whole supported clusters survive cuts; partially covered glyphs/images
are replaced with noninteractive space retaining the source faces (including
background paint), and fixed display spaces can be shortened. Blank canvas
outside the source remains neutral.
There is no alpha blending, half-glyph masking, or child frame. Layered trees
fall back to Elisp when native reflow cannot represent them.

Publication remains a Ebox publication transaction, including hidden-node updates and
rollback. Fixed-footprint local changes can recompose only the affected host;
geometry changes and root-layer dependencies may require broader work. No
per-update latency or universal local-update guarantee is implied. Run
`make test` for the focused contract. The separate `ebox-playground`
package provides `layer-minimal.ebox` and `layer-reference.ebox`; batch tests
do not establish GUI visual parity or remote CI success.

### Incremental Box geometry

`ebox-region-update-geometry` is the typed low-level path for changing a
mounted Box's position, size, bounds, or stacking facts. It accepts
`:box-sizing`, `:position`, `:left`, `:top`, `:z-index`, `:layer`, `:anchor`,
`:placement`, and width/height properties with their min/max bounds. Ebox
validates the ordinary unit grammar, builds an isolated candidate, and publishes
the change through the same retained transaction as `ebox-region-update`:

```elisp
(ebox-region-update-geometry
 "panel"
 :left (px 12) :top (lh 2)
 :width (ch 24) :height (lh 4)
 :z-index 3)
(ebox-region-geometry "panel")
;; => (:box-sizing border-box :position absolute :left (px 12) ...)
```

`ebox-region-geometry` returns a detached plist of the current effective Box
facts, including registered initial values for omitted declarations. During an
explicit update batch it reports the last accepted publication until the batch
is flushed. Stale, unmounted, or Text handles signal an error. Padding, margin,
border and other style properties remain available through the general
`ebox-region-update` API because they are styling/layout details rather than
the position/size/layer primitive shared by framework behaviors.

The typed path does not implement pointer tracking, resize handles, focus,
maximize/minimize modes, or window-management policy. A framework behavior or
application may use `ebox-keymap-create` to receive a gesture and then call
this API with the next declarative geometry. Ebox owns validation, retained
layout, occlusion recomposition, incremental publication, and rollback; the
caller owns interaction state and policy.

Frameworks that repeatedly update the same mounted Host can prepare a fixed
geometry operation once. `ebox-geometry-prepare` accepts its buffer, Host
reference (or semantic ID), and fixed property order. Reuse a value vector with
`ebox-geometry-apply`; a nil result means no state was staged and the caller
must use its ordinary update route. The prepared operation becomes stale after
an ordinary publication, replacement or unmounting. Reprepare at the next
settled control-plane boundary; never treat a stale operation as accepted.
Targets within one supported canvas share its retained preparation, so alternating
accepted prepared operations keeps the other targets' operations usable.
Repreparation after a compatible paint or positioning publication retains the
canvas's compiled wrapper and ownership resources. The old operation remains
stale; callers still obtain a new binding for the accepted generation.

```elisp
(let ((operation (ebox-geometry-prepare
                  (current-buffer) "panel" [:left :top :z-index]))
      (values (vector '(px 12) '(lh 2) 3)))
  (unless (and operation (ebox-geometry-apply operation values))
    (ebox-region-update-geometry "panel" :left '(px 12) :top '(lh 2) :z-index 3)))
```

The current compiled route supports absolute translation and stacking inside
fixed containing planes, including enclosing fixed wrappers. Horizontal units
are retained `px` or `ch`; vertical units are retained `lh`. Unchanged size
bindings may share the value vector. A normal-layout absolute Box with only
fixed Text children also supports cropped width/height updates: use an opaque
string background, `overflow hidden`, `wrap-mode none`, left/top alignment,
explicit `(px 0)` minimum width and `(lh 0)` minimum height, and no maximum,
padding, margins, borders or scrolling. Request `[:width :height]` during the
initial preparation, before a translation-only session has been retained.
The single fixed containing plane bounds positive integer pixel width and row
height. Preparation paints one maximum native text raster; execution changes
its visible row/column extent and restores formerly clipped text on expansion.
It does not cache every possible size, rasterize the interface as an image,
or postpone application state or input-target publication.

Ordinary publication is still required for wrapping, child layout, decorated
window shells, out-of-capacity sizes, anchors, root portals and scroll
dependencies without a prepared implementation. Unsupported input is declined
before publication, not silently converted into clipping. Source, style,
font and display changes retain the same invalidation and rollback contract.
Reusing placement storage does not certify a latency
budget or allocation-free rendering; clipping and native text publication still
have their own measured costs. Fixed wrapper decoration, ownership projection and
publication reuse compiled resources and process damaged rows.

Frameworks with related paint, Text and geometry effects can prepare one cohort
with `ebox-update-prepare` after mounting or a structural/configuration update.
Keep the cohort for subsequent interactions. Each specification is
`[HOST-REF PROPERTY-VECTOR]`; disjoint specifications may address the same Host.
Class members add a third aligned variant vector containing finite canonical
class values. A string is one Ebox class token; integrations with whitespace
class syntax normalize it before preparation and use a retained lookup during
application. Reuse member value vectors
and a sparse vector of changed member indices with `ebox-update-apply`.
One stage/rollback callback pair covers every changed member and one publication.
For a mounted Box with semantic ID `panel` and Text with semantic ID `label`,
handle either preparation or application declining with one ordinary batch:

```elisp
(let ((operation (ebox-update-prepare
                  (current-buffer)
                  [["panel" [:left :z-index]]
                   ["label" [:color :content]]]))
      (values [[(px 20) 3] ["#0088cc" "Ready"]]))
  (unless (and operation (ebox-update-apply operation values [0 1]))
    (ebox-call-with-update-batch
     (lambda ()
       (ebox-region-update-geometry "panel" :left '(px 20) :z-index 3)
       (ebox-region-update "label" :color "#0088cc" :content "Ready")))))
```

The cohort uses the shared fixed canvas from prepared geometry. Its supported
properties and values are defined by `ebox-update-prepare` in
[the API inventory](../ebox.el). Preparation binds source cells to retained
primitives; output is rendered only when a change is applied. Cold preparation
admits class variants unobserved by style selectors; unknown variants or
dependencies use ordinary publication. `ebox-update-binding-token` identifies
the current binding context; `ebox-update-prepare-report` distinguishes stale
context from an unsupported member, allowing frameworks to avoid repeatedly
preparing a known rejection.
Each apply recomputes the changed styles and renders the affected retained
primitive with the ordinary renderer. An absolute Host may move, resize and
change its content rows. Flow content must keep its rows and pixel intervals:
Text may change width inside a fixed single-row Flex allocation, while a change
that would move neighbouring content returns nil. Active hover replacements
also decline before publication. The caller then uses its ordinary update
transaction.
A retained source record keeps its
opaque handle; a new record binding invalidates earlier operations without
breaking previously exported canonical input. Accepted paint marks computed
styles stale for the next ordinary update, which recomputes the cascade before
using general local-update proofs.

Optional preparation callbacks pair framework state with the same publication:
`stage` and `rollback` are zero-argument functions supplied together;
`after-commit` runs after acceptance. A failing stage restores both authorities.
An after-commit error propagates after the accepted publication. Each
`ebox-geometry-prepare` operation owns one Host; `ebox-update-prepare` groups
supported changes across Hosts into one atomic publication. Unsupported groups
use the ordinary batch route. Exported snapshots remain independent of subsequent
prepared moves.
Point follows a retained logical focus target while point has not been moved
manually. Complete occlusion clears focus and active ownership and updates hover
bounds. If clearing those states would change computed styling, that sample
declines before staging so the ordinary route can publish the style change too.

### Wrapping and the optional EKP dependency

`:wrap-mode word` wraps ordinary words and permits character breaks for CJK;
`char` breaks at the common text-cluster boundaries supported by Ebox; `none`
keeps explicit newlines without adding soft line breaks. `kp` delegates
paragraph layout to the independent [EKP package](https://gitea.gklazycat.heiyu.space/geekinney/ekp)
using the Knuth–Plass algorithm. The mode belongs to a Box and is inherited by
its text content.

Install EKP 1.0.0 or newer, or add its source directory to `load-path`, before
using `:wrap-mode kp`. It is an optional dependency loaded on demand; ordinary
Ebox layouts require only ECSS. Choosing `kp` without a compatible EKP
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

Text and every Box form accept `:help-echo`, `:pointer`, `:hover-style`,
`:hover-content`, `:hover-group`, and `:keymap`, plus node-local `:tab-index` and `:disabled`
focus inputs. These are explicit node capabilities outside the CSS cascade.
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

`:hover-content` is an optional string (or zero-argument function returning a
string) that temporarily replaces a Text node's content while the pointer is
inside its rendered bounds. Ebox enters and leaves through the retained
`ebox-region-update` content path, so the source tree, focus and publication
rollback remain authoritative. A node with this capability enables local
`track-mouse` handling in its mounted buffer; ordinary Ebox buffers do not
receive motion events. Keep the alternate value on the same line as the base
value when the control's line height must remain stable. Ebox does not create
overlays or enter the primary-button drag tracking loop for this capability.

`:hover-group` gives sibling hover-content nodes one scalar group key. Entering
any member updates every member in one explicit Ebox incremental batch; leaving
the group restores all members in one batch. When omitted, a node is its own
group. This is useful for compound controls such as traffic-light buttons.

Box help, pointer, and keymap cover its rendered content, padding, and border,
excluding that Box's margin and structural newlines; hover follows the rule
above. A nested Text or Box can replace
each capability with an explicit value. Explicit `nil` blocks an enclosing
value; an omitted property leaves the enclosing surface coverage in place.

`:keymap` accepts a native Emacs keymap or `nil`. Prefer `ebox-keymap-create`:
its `:activate` callback takes no arguments and handles `RET`, `[return]`, `SPC`,
and `[mouse-1]`. On a mounted surface, pressing consumes motion and release,
with `:active` visible to selectors and styles while held. Release over the same
retained owner clears the state and activates once; release elsewhere cancels.
Rapid double and triple clicks each activate once. Release in the selected
window focuses the activated owner before its callback, so a panel opened by
the callback can return to that entry. Events dispatched for other windows
preserve their point and selection. Pure rendered text keeps release activation without mounted state. Use `:bindings` for an alist
of key-description strings or event
vectors paired with zero-argument callbacks. The helper uses the event window's
buffer for mouse callbacks, so a callback can directly update a semantic ID
with `(ebox-region-update "action" :help-echo "Activated")`.
Explicit bindings can override the repeated-click, press and drag defaults.

For direct manipulation, supply `:drag` to the same keymap factory. This example
keeps ordinary Elisp application state and moves the retained Box horizontally:

```elisp
(let ((x 0) (origin 0))
  (ebox-render-to-buffer
   "*Ebox drag*"
   (ebox-build
    `(column :width (ch 60)
      (box :id "handle" :position relative :left (px 0)
           :keymap ,(ebox-keymap-create
                     :drag (lambda (gesture)
                             (pcase (plist-get gesture :phase)
                               ('start (setq origin x))
                               ((or 'move 'end)
                                (setq x (+ origin (car (plist-get gesture :delta))))
                                (ebox-region-update "handle" :left (list 'px x))))))
           "Drag horizontally")))))
```

Ebox keeps the initial target through keyed reorder and checks its current
published ownership after native reads and before dispatch. One input round
merges at most 64 already pending motions in the original text window, uses
the latest position, completes its callback and redisplays. Polling does not
wait for more motion. Release, another press, cancellation, unrelated input
and leaving the window stop merging; unrelated events retain their order.
Release supplies its own final position. A locked gesture ends at its second
press and consumes subsequent motion until release without publishing again.
Leaving the original text window or losing the target/window ends tracking;
`C-g` cancels and propagates quit. Accepted positions remain application-owned.
`:activate` may also provide keyboard activation; `:drag` owns the primary mouse
sequence. The supported gesture fields and lifetime are documented in
[the entry](../ebox.el). Same-window GUI dragging is the intended scope;
cross-window/frame and terminal mouse dragging remain unverified.

Use `M-x ebox-activate` to invoke the focus target's RET command when point
remains at its first visible character, or otherwise the node at point. Call
`(ebox-activate position)` at an explicit accessible position. This uses only
the committed node keymap, including inherited maps and explicit nil barriers;
overlay/global maps, structural newlines and invisible text are not targets.
The framework does not move point or select a window. Missing targets signal
`user-error`; `(ebox-activate position t)` quietly returns nil for a missing
target, while callback errors still propagate. Each invocation reads the latest
publication, so replacement, rollback and unmount need no activation registry.
Generated `ebox-keymap-create :activate` commands use this same focus precedence
for RET, return and SPC. A focused parent therefore wins over a child map at the
same character. Mouse activation always uses the clicked binding. Custom keys
and raw native keymap commands keep their declared native behavior; explicit
`ebox-activate` applies logical focus to any native RET map.

Declare `:tab-index 0` to make a node a logical focus navigation stop; any
nonnegative integer participates, in ascending numeric order followed by buffer
start and end. Negative integers permit explicit focus but skip navigation;
nil or an omitted index does not create a stop. `:disabled t` excludes the node
from focus and suppresses its own or inherited keymap. These two inputs are
local to the declaring node; a child may declare an enabled map independently.
Reenable with `:disabled nil`; the original declared keymap becomes effective
again. Publish both inputs through ordinary `ebox-region-update` or canonical
commits. The same disabled fact derives `:disabled` for selector queries and
cascade, including descendant and sibling rules. Disabling a parent does not
mark its children disabled. Authored `:states` (or typed `:selector-state`)
accept custom states, but reject `disabled`, `focus` and `active`. Declare
`:disabled t`, use mounted focus operations, and use generated primary-button
gestures respectively. A rule such as `("#action:active" :color "#ff0000")`
uses the ordinary cascade. Pressed state follows retained updates and clears
when tracking ends or the target becomes unavailable. Drag callbacks observe
it while tracking; activation runs after it clears. A pressed style must leave
the requested target visible and enabled, otherwise the press fails without
changing the surface. Keyboard activation does not create this state. Hover
state integration into the cascade remains pending.

Use `ebox-focus-next` / `ebox-focus-previous` for logical navigation. The optional
second argument enables cycling. `ebox-focus-first` selects the first eligible
stop without clearing the existing focus if no stop exists. They return an opaque Host reference for
`ebox-focus` and `ebox-focused-host-ref`; frameworks may also use their explicit
source-builder identities. `ebox-focus` accepts nil to clear focus. It may
explicitly focus any enabled visible node, even without a tab index or keymap.
Focus changes cannot join an active Ebox publication transaction: setting, clearing or moving
focus signals an error before changing focus or point. Invoke them after the
transaction accepts, including from an `after-commit` callback. Read-only
`ebox-focused-host-ref` and zero-count navigation remain available. This prevents
an outer rollback from leaving a focus change that was never accepted.
The complete signatures and error contracts are in [ebox.el](../ebox.el).

```elisp
(ebox-render-to-buffer
 "*Ebox Focus*"
 (ebox-build '(column (text :key first :tab-index 0 "First")
                     (text :key second :tab-index 0 "Second"))))
(with-current-buffer "*Ebox Focus*"
  (let ((first (ebox-focus-next)))
    (ebox-focus-next 1 t)
    (ebox-focus first)))
```

Menus and dialogs can use `ebox-focus-within` with their panel's Host reference.
With no count it selects the first eligible stop in the committed subtree;
`(ebox-focus-within panel 1 t)` and `(ebox-focus-within panel -1 t)` cycle
forward and backward within it. Hidden, disabled and covered controls are
skipped by the same painted-target checks as ordinary focus navigation. Zero
queries whether current focus belongs to the panel. This is a navigation
operation, not a persistent modal restriction: callers own opening, dismissal
and keyboard bindings, and restore a retained trigger with `ebox-focus`.

Use `ebox-call-with-input` from a native activation callback to guard an
editing or selection session. The reader runs in the mounted buffer and owns
its native editing UI; it must not edit the rendered Ebox surface. Apply its
result only after the call returns:

```elisp
(require 'ebox)
(with-current-buffer (get-buffer-create "*ebox-input*")
  (let ((map (ebox-keymap-create
              :activate
              (lambda ()
                (interactive)
                (let* ((target (ebox-focused-host-ref))
                       (value (ebox-call-with-input
                               target (lambda () (read-string "Title: ")))))
                  (message "Accepted: %s" value))))))
    (ebox-render-to-buffer
     (current-buffer) (ebox-build `(box :keymap ,map :tab-index 0 "Edit title")))
    (ebox-focus-first)))
```

The boundary restores logical focus without selecting a window. It returns the
reader's value only for the same mounted, enabled, accessible target; otherwise
it signals `ebox-input-cancelled`, a subtype of `quit`. Keyed reorder retains
the owner. Reader errors and user quit propagate, while focus is restored when
possible. Call outside a Ebox publication transaction. Ebox owns neither application values
nor the native input buffer, and does not implement another text editor.

A focus change publishes the `:focus` selector state with its computed paint
and layout. For example, local rules `(("box:focus" :color "#ff0000"))` style
only the focused Box; descendant and sibling selectors use the same cascade.
The state belongs to the mounted buffer: pure rendering and another mount of
the same input have no focus until explicitly focused. Author state tokens
cannot supply `focus`. A rule that makes a newly requested target hidden or
fully clipped rejects that focus operation and preserves the old view. Ordinary
updates that hide or clip a retained target clear focus and recompute without
its focus state before publication. A rejected update restores the old state
and paint together. Clearing focus preserves numeric point, clamped if the
new layout is shorter. Publication observers may react to focus changes.

Focus first follows an existing explicit source identity. An expired reference
can continue only through a retained node with the same non-nil sibling key; an
unkeyed replacement clears focus.

Focus belongs to the mounted buffer, without selecting a window or maintaining
separate focus per window. Keyed reorder follows the retained node, even when a
new input supplies a fresh source handle. Query the current reference after
publication rather than retaining an old generation's automatically generated
reference. If point is still on the focused node's first visible character,
publication follows its new position. If point was moved manually, publication
preserves its numeric position, clamped to the accessible buffer. Published
removal, hiding or disabling clears focus and preserves that clamped position;
the next navigation starts at the first/last eligible stop. Rejected publication
restores the previous focus and point. Unmount and buffer death release focus.
Narrowing and invisible overlays are checked when navigating or setting focus.
The mounted `ebox-buffer-mode` supplies cyclic TAB and Shift-TAB/backtab
navigation, plus RET/return activation through `ebox-buffer-mode-map`. It is
enabled after successful mount and disabled on unmount, for standalone Ebox
and framework callers alike. No application input mode is required. Disabling
this mode removes its buffer bindings; native node keymaps remain available.

Move point into the surface to use keyboard bindings. Optional commands
`ebox-next-interaction` and `ebox-previous-interaction` move between declaring
nodes that currently render a usable keymap. Each owner contributes one stop,
even if its map covers padding or several lines; explicit child maps are
separate stops. Empty maps, explicit `nil`, and invisible or clipped-away
content do not add stops. Navigation follows the current committed buffer, so
updates do not require a separate refresh. At a boundary it reports a user error
without wrapping or moving point. These commands add no bindings automatically.
To bind these keys to keymap-owner navigation, customize the shared map:

```elisp
(keymap-set ebox-buffer-mode-map "TAB" #'ebox-next-interaction)
(keymap-set ebox-buffer-mode-map "<backtab>" #'ebox-previous-interaction)
```

Raw native keymaps are also accepted; their mouse commands must handle the
event's target buffer themselves. Ebox uses native command dispatch and does
not create application state. A hand pointer
alone does not bind a click command.

The Playground's [interaction lab](https://gitea.gklazycat.heiyu.space/geekinney/ebox-playground/src/branch/main/README.md#native-interaction-lab)
keeps its business functions and state in `interaction-reference.el`, with its
layout in `interaction-reference.ebox`. It demonstrates callbacks, nested
overrides, and replacing or removing all four capabilities through public
region updates.

## 5. Render and publish

`ebox-render` returns propertized text without changing a live buffer.
`ebox-render-to-buffer` mounts a retained Ebox publication surface and returns its buffer.
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

When `ebox-buffer-set-observer` enables observation, the optional
`:phase-duration-ms` plist attributes exclusive elapsed milliseconds to source,
style, plan, layout, projection and transaction. Nested phases are counted once;
their sum equals the observed Ebox duration. Transaction includes the remaining
commit/Ebox publication work and overlaps Ebox publication's independent report. The workspace runner consumes
these reports in its trace pass; CPU and allocation profiling run separately.

`:native-declined-reason` explains an unavailable native input capability before
execution, such as missing viewport dimensions or positioned nodes.
`:native-fallback-reason` describes an attempted native execution that could
not produce a supported result. Both retain normal Elisp rendering; a loaded
native module alone does not establish that an interaction used it.

The optional
`:projection-rejections` field records local attempts as
`(:projection KIND :reasons (REASON ...))`. It currently covers mixed local
planning and accepted local plans that subsequently require ordinary output:

`fragment-ledger` additionally records why a local replacement needed ordinary
fragment parsing, such as unaligned boundaries, missing retained source facts
or changed line topology. Role changes alone can retain parsing while rebuilding
target ownership; they do not require a whole-output parsing fallback.

| Reason | Boundary that declined the attempt |
| --- | --- |
| `geometry-allocation` | No supported local geometry allocation proof. |
| `native-property-composition` | The mixed paint compositor cannot publish changed native surface properties. |
| `paint-composition` | The external paint owners do not satisfy the compositor's constraints. |
| `candidate-style-preparation` | Candidate styles were not completely prepared for local reuse. |
| `retained-style-closure` | The published style bindings cannot safely represent the candidate. |
| `overlapping-output` | Geometry and paint output do not have a supported disjoint composition. |
| `output-proof` | A selected local plan could not produce proven local output. |

Several independent reasons can apply to one attempt. Absence of a record does
not certify eligibility: this is not an exhaustive proof trace. A different
local route may succeed; read the final `:projection-kind` for the published
route. Reasons do not attribute elapsed time. `make update-effects-performance`
performs two additional observed updates, covering both states, and aggregates
them as `rejection_counts`. These updates run the same correctness checks but
are excluded from latency samples and `projection_counts`; `diagnostic_updates`
records their count. Ordinary updates do not collect this detailed diagnostic.

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

Keep a handle while its node remains under the same parent: inserting or
reordering siblings does not invalidate it. Resolve a new handle after replacing
the node's logical identity, removing it or remounting the buffer.

The same API replaces native capabilities on Text or Box regions. For the
interaction example above:

```elisp
(with-current-buffer "*Ebox Interaction*"
  (ebox-region-update "action" :help-echo "Updated help" :pointer 'arrow
                      :hover-style '(:background-color "#F6D6AB")
                      :hover-content "×")
  (ebox-region-update "action" :help-echo nil :pointer nil
                      :hover-style nil :hover-content nil :keymap nil))
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

Ebox provides framework SPI v3 through `(require 'ebox)`. This interface is
for framework implementers such as ETAF; application code normally uses the
render/update API described above. Query `ebox-framework-spi-capabilities` and
validate the immutable provider with `ebox-framework-spi-validate-provider` before
retaining its public operation descriptors. Do not read private provider fields.

| Operation | Input and result |
| --- | --- |
| `ebox-framework-spi-initial` | An unmounted buffer, canonical input and a stage/rollback callback pair; returns the completed report also supplied to the callbacks. It cannot join an outer Ebox publication transaction. |
| `ebox-framework-spi-update` | A mounted buffer, canonical input or candidate, and a stage/rollback pair; returns the same report object observed by the stage callback. |
| `ebox-unmount-buffer` | Releases the retained mount so a fresh initial generation can be created. |

The framework owns application state; Ebox owns layout/runtime indexes; Ebox publication owns
buffer publication and the transaction. Stage callbacks run after provisional Ebox publication
and Ebox state agree. Rollback runs framework rollback, then Ebox state restoration,
then Ebox publication restoration. A failed initial mount restores editor custody, including text,
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


### Compose property and structural updates

Frameworks use `ebox-candidate-update-host-properties` when an existing Host's
own declarations change. Supply canonical previous and next authored inputs;
the previous input describes the captured base, including on repeated calls.
Only the matching Host's local properties participate. Input children and text
are ignored, so a shallow input is sufficient. Ebox retains current content,
children and identity and determines the style, layout and interaction effects.

The example changes the panel width while keeping its existing label:

```elisp
(require 'ebox)
(cl-labels
    ((panel (width &optional text)
       (let* ((builder (ebox-source-builder-create))
              (decls (ebox-style-compile-form 'column (list :width width)))
              (handle (ebox-source-builder-bind builder :identity 'panel
                                                :declarations decls))
              (children
               (when text
                 (list (ebox-text-create
                        :value text
                        :source-handle (ebox-source-builder-bind builder :identity 'label)
                        :owned-facts (ebox-canonical-facts-from-declarations 'text nil)))))
              (node (apply #'ebox-box-create
                           (append (ebox-canonical-box-configuration 'column decls)
                                   (list :source-handle handle :children children
                                         :owned-facts
                                         (ebox-canonical-facts-from-declarations 'column decls))))))
         (ebox-canonical-input-create (list node) (ebox-source-builder-finish builder)))))
  (let* ((buffer (get-buffer-create "*Ebox Properties*"))
         (previous (panel '(ch 32) "Retained content"))
         (next (panel '(ch 18))))
    (ebox-render-to-buffer buffer previous)
    (let ((candidate (ebox-candidate-begin buffer)))
      (ebox-candidate-update-host-properties candidate 'panel previous next)
      (ebox-commit buffer candidate))))
```

The same candidate can replace descendant Hosts or child Ranges. Property
updates refine retained owners after those structural operations; removal of an
owner absorbs its update, and complete root replacement absorbs all operations.
Repeated property updates for one owner use the last supplied delta. A node type
change requires subtree replacement. Unknown base references, invalid inputs and
sealed candidates signal errors; no paint-versus-layout fallback is requested of
the caller. Commit consumes the candidate once, even when publication fails.

Keep source identities stable for nodes that survive an update. Subtree and
Range replacement both match author keys first, then unkeyed source identities;
moving a retained node does not require adding a key at every nested level.
Its focus and descendant Range addresses remain usable after publication.

## Local rule input

`:ecss` accepts an ordered rule list and `:ecss-file` reads that same list from a
file using ECSS's [static data contract](https://gitea.gklazycat.heiyu.space/geekinney/ecss/src/branch/main/docs/manual.md#static-rule-data).
File contents have no quote wrapper; ordinary Elisp expressions quote literal
lists normally. File rules precede inline `:ecss` rules. Ebox validates selectors
and declarations through ECSS and its own property schema. Canonical input
producers call `ebox-style-compile-rules` and pass its result to the `:ecss` field
of `ebox-source-builder-bind`, so programmatic and DSL rules use the same path.

Canonical producers may also pass `:ecss-targets` to the same source binding.
The default t permits all descendants; a proper list restricts rule targets to
source `:identity` values compared with `equal`, and nil disables that scope's
rules. The list is snapshotted when bound. Rendering resolves identities against
that candidate's source index; missing targets fail before publication. Targets
outside the mounting source's subtree cannot match. For example, a root binding
with `:ecss-targets '(slot)` and rules for `.title` styles the source whose
`:identity` is `slot`, even beneath a child component, while excluding other
matching descendants. The producer must bind that identity in the same canonical
input. This is canonical integration metadata, not an additional DSL field.

Targets select recipients of rules; they do not change structural selector
relationships or inherited computed values. Create a new canonical input when
ownership changes. A failed candidate leaves committed ownership and output intact.
Exported canonical snapshots retain their targets for independent remounting.

Canonical Box producers use `ebox-canonical-box-configuration` to derive the
`:layout` and `:outer` constructor fields from canonical declarations. This is the
same projection used by the DSL: concrete configuration is cached in Ebox, and
ECSS-tagged values wait for cascade. The returned plist is detached and its typed
LayoutConfig is immutable. Invalid tags, declaration contexts or concrete values
signal an error. Keep the complete declarations in the source binding and derive
owned facts from them so deferred values participate in rendering and updates.

```elisp
(require 'ebox)
(require 'ecss)
(let* ((declarations (ebox-style-compile-form
                      'flex (list :flex-direction (ecss-important 'column))))
       (builder (ebox-source-builder-create))
       (handle (ebox-source-builder-bind builder :declarations declarations))
       (child-input (ebox-build '(box "Child")))
       (children (ebox-canonical-input-import-roots
                  child-input (ebox-canonical-input-roots child-input) builder))
       (node (apply #'ebox-box-create
                    (append (ebox-canonical-box-configuration 'flex declarations)
                            (list :children children :source-handle handle
                                  :owned-facts (ebox-canonical-facts-from-declarations
                                                'flex declarations))))))
  (ebox-render (ebox-canonical-input-create
                (list node) (ebox-source-builder-finish builder))))
```

## Shared author scopes

Frameworks create immutable scope descriptions with `ebox-style-scope-create`.
The input is the same ordered rule list as other style entries; optional `:origin`
uses ECSS origins, so a theme may provide UA defaults while component rules remain
author declarations. Invalid rules or origins signal errors without modifying
existing descriptions. Descriptions own no buffers or runtime resources and need
no disposal. Source data is snapshotted. To update rules for retained members,
use `(ebox-style-scope-with-rules scope rules :origin 'author)` and bind the
result to roots. It keeps the membership identity: existing members may carry
any revision. Each root uses its own rules, and old inputs stay unchanged.
Invalid revisions signal errors without modifying prior descriptions. The origin
defaults to author; specify it again when revising UA defaults.

Each canonical source lists its memberships in `:ecss-scopes` and its mounting
roots in `:ecss-scope-roots`. Both accept proper lists of distinct scope identities;
invalid lists fail during binding. Roots and members are independent. A member
receives rules only within a marked root's subtree; the root itself must also be
a member to receive `&` or `:scope` rules. Ordinary selectors address strict
descendants. A description may have several roots, each mounted independently.
Structural relationships and inheritance remain those of the canonical tree.

A parent-owned slot may carry its parent's description below a child component's
root while fallback carries the child's description. Dynamic content can carry
the existing description without rewriting target lists on ancestors. Descriptions
with no root in an input contribute no rules, allowing detached slices to be
assembled before their enclosing roots. Canonical import, retained updates and
snapshots preserve these facts. Failed candidates preserve committed ownership.
Sharing a description between applications shares immutable rules, not live state.

Shared scopes follow source-local `:ecss` scopes in cascade source order. Among
shared descriptions, the first marked root's document order and its list order
determine source order. Specificity, origin, importance and scope proximity retain
ECSS precedence. Two roots can share presentation without adding a visual node:

```elisp
(require 'ebox)
(let* ((scope (ebox-style-scope-create '(("&" :color "#ff0000"))))
       (builder (ebox-source-builder-create))
       (children
        (mapcar
         (lambda (label)
           (ebox-text-create
            :value label
            :source-handle (ebox-source-builder-bind
                            builder :ecss-scopes (list scope)
                            :ecss-scope-roots (list scope))
            :owned-facts (ebox-canonical-facts-from-declarations 'text nil)))
         '("First root" "Second root")))
       (root (ebox-box-create
              :layout (ebox-column-layout-create) :children children
              :source-handle (ebox-source-builder-bind builder)
              :owned-facts (ebox-canonical-facts-from-declarations 'column nil))))
  (ebox-render (ebox-canonical-input-create
                (list root) (ebox-source-builder-finish builder))))
```

## Computed declaration values

Programmatic style inputs can use `ecss-important`, `ecss-wide-value`, and
`ecss-var`. Longhand values are computed before paint and layout; importance
also preserves supported shorthand expansion. Construct these values in Elisp:

```elisp
(ebox-render
 (ebox-build
  (list 'box '--accent "#334155"
        (list 'text :color (ecss-var '--accent "#000000") "Accent"))))
```

Custom property names use `--name` symbols in rule lists, inline declarations
and `ebox-region-update`. Their inherited values may affect paint or geometry.
Updating a custom property recomputes retained consumers; important inline and
rule declarations participate in ECSS precedence. Concrete invalid values still
fail before publication. Variable resolution and invalid computed values follow
ECSS's schema fallback contract. Static `.ecss` files remain inert and never call
these constructors. Use explicit longhands for context-dependent shorthand values;
this interface does not implement deferred multi-value shorthand substitution.
