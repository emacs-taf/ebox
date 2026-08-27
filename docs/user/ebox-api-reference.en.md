# Ebox public API reference

[中文](ebox-api-reference.zh.md)

This document is the exhaustive user-facing inventory for the standalone Ebox
package. It describes the supported node model, properties, layout helpers,
rendering/publication workflows, selectors, scrolling, measurement, DSL, and
optional native module. `ebox--*` names and undocumented module helpers are
implementation details. The facade inventory is also available as the
`ebox-public-api` constant after `(require 'ebox)`.

Ebox owns box nodes, style normalization, measurement, layout, rendering,
semantic update planning, selector integration, Grid, and the optional Rust
reflow accelerator. TP owns live buffer publication, physical diff execution,
revisions, and rollback. ECSS owns selector parsing, matching, and cascade
semantics. Ebox does not provide Components, application state, UI controls,
or an application lifecycle.

## 1. Install and load

Ebox requires Emacs 29.1 or newer, ECSS, and TP. With sibling source
checkouts:

```elisp
(add-to-list 'load-path "/path/to/github/ecss")
(add-to-list 'load-path "/path/to/github/tp")
(add-to-list 'load-path "/path/to/github/ebox")
(require 'ebox)
```

Loading Ebox loads the Elisp layout/runtime modules. It does not create a
buffer, enable a mode in the current buffer, build Rust, or mutate the current
editing buffer. The optional native module is loaded only when its workflow or
an eligible native path requests it.

## 2. The normal lifecycle

The public workflow is:

```elisp
(let ((root
       (ebox-column
        (ebox-create :id "status" :content "Ready" :width '(240))
        (ebox-create :content "A caller-owned source tree"))))
  ;; Pure materialization; returns a multi-line propertized string.
  (ebox-render root)

  ;; Retained TP surface; returns the live buffer.
  (ebox-render-to-buffer "*Ebox Demo*" root)

  ;; Later, build a new declarative root and publish it atomically.
  (ebox-commit
   "*Ebox Demo*"
   (ebox-column
    (ebox-create :id "status" :content "Updated" :width '(240))
    (ebox-create :content "The unchanged source is not mutated."))))
```

`ebox-render` has no live-buffer side effect. A static tree without an active
stylesheet or inline inherited-style dependency can use isolated pure
materialization; stylesheet-dependent pure renders use an ephemeral TP
materialization. Both produce the same public string contract. The two buffer
entry points use a retained TP surface. Ebox copies declarative input before
assigning runtime identity, so the same source tree may be mounted in several
buffers.

`ebox-display-buffer` is the convenience wrapper when Ebox should also display
the buffer. It deletes other windows before switching to the rendered buffer;
use `ebox-render-to-buffer` when the caller owns window selection.

## 3. Nodes and composition

### Box and simple layout constructors

```elisp
(ebox-create &rest properties)
(ebox-concat node-1 node-2)       ; two nodes side by side
(ebox-stack node-1 node-2)        ; two nodes vertically
(ebox-row &rest nodes)             ; many nodes side by side; a sole Range keeps its row parent
(ebox-column &rest nodes)          ; many nodes vertically; a sole Range keeps its column parent
(ebox-spacer &rest properties)    ; blank box
```

`ebox-create` returns a declarative box node. `:content` is string content;
container children are normally supplied to `ebox-row`, `ebox-column`,
`ebox-flex`, or `ebox-grid`. `ebox-concat` and `ebox-stack` accept two nodes;
use the variadic row/column helpers for more than two children. Nil children
are ignored. An empty row or column becomes a spacer.

In a `row`, omitted or `auto` widths use each child’s intrinsic width when the
children are concatenated; the parent viewport is not reused as every child’s
width. Explicit `viewport`, `stretch`, and definite widths still resolve against
their containing block. A `column` fills narrower layout rows to its containing
block, while a visual box paints its border and padding at its own used width.

`:key` is the stable application identity for a sibling. `:id` is a logical
selector/update identifier. `:host-ref` is an opaque application-owned anchor
used by host-reference lookup and logical candidate replacement. Host refs
must be unique and non-nil within one source tree.

### Flex

```elisp
(ebox-flex
 :width '(480)
 :flex-flow '(row wrap)
 :gap '(1 (12))
 (ebox-flex-item (ebox-create :content "A")
                 :flex '(1 1 auto)
                 :align-self 'center)
 (ebox-create :content "B" :flex-grow 2))
```

Container properties are `:flex-direction`, `:flex-wrap`, `:flex-flow`,
`:justify-content`, `:align-items`, `:align-content`, `:gap`, `:row-gap`, and
`:column-gap`, plus ordinary box properties such as `:width`, `:height`,
padding, border, and paint. Defaults are row direction, nowrap, flex-start
main-axis justification, and stretch cross-axis alignment.

Item properties are `:order`, `:flex`, `:flex-grow`, `:flex-shrink`,
`:flex-basis`, and `:align-self`. They may be placed directly on a child or
attached with `ebox-flex-item`. Non-item properties passed to
`ebox-flex-item` wrap the child in a normal box.

The supported size keywords for flex preferred/min/max sizes are the Ebox
subset `auto`, `min-content`, `max-content`, `fit-content`, `stretch`, and
`contain`; the max-size set also accepts `none`. `fit-content` may carry a
numeric or viewport-relative limit. These are Ebox layout values, not a claim
of full browser CSS compatibility.

### Grid

```elisp
(ebox-grid
 :width '(640)
 :grid-template-columns '((200) 1fr 1fr)
 :grid-template-rows '(1 1)
 :gap '(1 (12))
 (ebox-create :content "Header" :grid-column '(1 :span 3))
 (ebox-create :content "Main" :grid-column 1 :grid-row 2)
 (ebox-create :content "Aside" :grid-column 2 :grid-row 2))
```

`ebox-grid-fr` constructs a fractional track: `(ebox-grid-fr 2)` returns
`(fr 2)`. Grid tracks support fixed sizes, `auto`, fractional tracks written
as `(fr FACTOR)` or symbols such as `1fr`, `minmax`, and `repeat`. Omitted
positions use implicit tracks. `:grid-auto-columns`, `:grid-auto-rows`, and
`:grid-auto-flow` (`row` or `column`) control implicit placement.

Grid item placement is one-based. `:grid-column` and `:grid-row` accept a
positive start integer, `(start :span positive-integer)`, or `(start end)` with
`end` greater than `start`. `:grid-column-span` and `:grid-row-span` accept
positive integers. Placement properties belong directly to the child Box;
Grid item is a parent-child role, not a wrapper or constructor.

## 4. Units, box properties, and text properties

### Size units

| Value | Meaning |
| --- | --- |
| Ordinary horizontal number, e.g. `12` | Character columns, converted using the current display's space width. |
| One-element horizontal list, e.g. `'(240)` | Absolute pixels. |
| Vertical number, e.g. `3` | Lines. |
| `(viewport)` or `viewport` | Current viewport width in pixels. |
| `(viewport-height)` or `viewport-height` | Current viewport height in lines. |
| `auto`, `min-content`, `max-content`, `fit-content`, `stretch`, `contain` | Intrinsic/preferred width values where the property and formatting context support them. |

`:box-sizing` defaults to `border-box`; `content-box` is also supported.
Width values include `:width`, `:min-width`, and `:max-width`; height values
include `:height`, `:min-height`, and `:max-height`. Negative geometry is
rejected. A viewport-dependent node must be rendered with a viewport context
or rerendered with `ebox-rerender-buffer-with-context`.

### Box, paint, and text properties

The following names are inputs to `ebox-create`. Style rules accept the
style/geometry names in this table, while `ebox-region-update` accepts the
mutable content/style/scroll subset supported by its target. Direct updates do
not add children or change selector metadata; use `ebox-commit` or a logical
candidate for structural changes. Structural metadata, `:content`, and
`:surface-properties` are node/render inputs rather than stylesheet
declarations. Canonical logical names and compatibility aliases are shown
together.

| Area | Properties |
| --- | --- |
| Content/geometry | `:content`, `:box-sizing`, `:width`, `:min-width`, `:max-width`, `:height`, `:min-height`, `:max-height` |
| Padding | `:padding`, `:padding-inline`, `:padding-block`; longhands `:padding-block-start`, `:padding-inline-end`, `:padding-block-end`, `:padding-inline-start`; aliases `:padding-top`, `:padding-right`, `:padding-bottom`, `:padding-left` and the pixel/height aliases `:padding-right-pixel`, `:padding-left-pixel`, `:padding-top-height`, `:padding-bottom-height` |
| Margin | `:margin`, `:margin-inline`, `:margin-block`; longhands `:margin-block-start`, `:margin-inline-end`, `:margin-block-end`, `:margin-inline-start`; aliases `:margin-top`, `:margin-right`, `:margin-bottom`, `:margin-left` and the pixel/height aliases `:margin-right-pixel`, `:margin-left-pixel`, `:margin-top-height`, `:margin-bottom-height` |
| Border | `:border`, `:border-top`, `:border-right`, `:border-bottom`, `:border-left`, `:border-width`, `:border-style`, `:border-color`; side longhands `:border-*-width`, `:border-*-style`, `:border-*-color`; Ebox boolean shorthands `:border-top-p`, `:border-bottom-p`; compatibility aliases `:border-left-pixel`, `:border-right-pixel` |
| Paint | `:color`, `:background-color`, and alias `:bgcolor` |
| Typography | `:font`, `:font-family`, `:font-height` and alias `:font-size`, `:font-weight`, `:font-slant` |
| Box content | `:text-align` (`left`, `center`, `right`), `:vertical-align` (`top`, `center`/`middle`, `bottom`), `:overflow` (`scroll`, `hidden`, `visible`), `:wrap-mode` (`word`, `char`, `kp`, or `none`; default `word`), `:visibility` (`visible` or `hidden`) |
| Structural style | `:display` is computed for node/layout contexts; the layout constructors normally choose the valid display tuple. |
| Flex container/item | `:flex-direction`, `:flex-wrap`, `:flex-flow`, `:justify-content`, `:align-items`, `:align-content`, `:gap`, `:row-gap`, `:column-gap` (aliases `:grid-row-gap`, `:grid-column-gap`); item names `:order`, `:flex`, `:flex-grow`, `:flex-shrink`, `:flex-basis`, `:align-self` |
| Grid container/item | `:grid-template-columns`, `:grid-template-rows`, `:grid-auto-columns`, `:grid-auto-rows`, `:grid-auto-flow`, `:justify-items`; item placement `:grid-column`, `:grid-row`, `:grid-column-span`, `:grid-row-span` |
| Extra text properties | `:surface-properties` accepts an even property list of Emacs text properties, applied to rendered characters without newlines. Inner non-nil properties win. |

Use `:font`, not `:face`, for the box font. `:font` accepts an Emacs face
symbol, a face name string, or a face plist; the typography longhands are
merged into that face. `:visibility 'hidden` suppresses ink while preserving
layout footprint and metadata. With `:overflow 'visible`, excess lines are
published as visible overflow; `hidden` clips them; `scroll` exposes a bounded
window and enables Ebox scrolling when content is taller than the box.

Padding and margin use CSS 1–4-value expansion. Horizontal entries use the
horizontal units above, while top/bottom entries use line units. Left/right
border widths are pixel geometry. Top/bottom borders use Emacs overline and
underline faces, so their width is a presence flag rather than arbitrary pixel
thickness.

### Node metadata and selector inputs

These inputs identify nodes without changing their geometry:

| Input | Meaning |
| --- | --- |
| `:id` | Logical selector/update id. Symbols and other scalar values are normalized to strings; an id should be unique where a direct update resolves it. |
| `:key` | Stable sibling identity used by reconciliation and also exposed as the built-in selector `:key` attribute. |
| `:class` | One class token or a list of class tokens for selector matching. |
| `:selector-state` | One state token or a list of state tokens matched by state pseudos such as `:hover` and `:active`. |
| `:selector-attributes` | Explicit attribute alist, such as `((role . button))`; content, layout values, and runtime fields are never inferred. |
| `:host-ref` | Unique application-owned opaque anchor for `ebox-host-ref-position`, `ebox-host-ref-bounds`, and host-ref candidate replacement. |
| `:scroll-offset` | Initial/controlled line offset for a scroll region. Prefer scroll commands for interaction; updates require a live region handle. |

`:id`, `:key`, and `:host-ref` are not stylesheet declarations. `:class`,
`:selector-state`, and `:selector-attributes` are selector metadata, not
general-purpose application state.

## 5. Stylesheets and cascade

Inline properties are enough for most nodes. For selector-driven styles, use
the isolated Ebox stylesheet:

```elisp
(ebox-style-reset-rules)
(ebox-style-add-rule
 ".card"
 '(:color "#1F2937"
   :background-color "#F8FAFC"
   :padding '(1 (12)))
 :layer 'base)
(ebox-style-add-rule
 ".card:has(> .warning)"
 '(:border-color "#DC2626")
 :layer 'state)
```

`ebox-style-add-rule` accepts a selector string or parsed AST, an Ebox
declaration plist, and the ECSS cascade keywords `:origin`, `:layer`, and
`:scope`. `ebox-style-reset-rules` clears the stylesheet. Rules are global to
the loaded Ebox style registry; changing rules does not silently publish an
already-mounted buffer, so rerender or commit the affected buffer after a
rule change. `ebox-style-cascade-active-p` reports whether rules are present.

The ECSS-backed style domain includes inheritance for color and typography,
computed values, cascade layers, custom-property declarations, and dirty
classification for paint/geometry/structure changes. Ebox interprets only the
properties listed in this reference; percentages, absolute positioning,
z-index, shadows, border radius, browser bidi, and full browser typography are
outside the package.

Custom properties whose names start with `--` may be carried by the ECSS style
domain, but they do not affect Ebox output unless a host integration resolves
them into one of the supported Ebox properties.

## 6. Rendering, identity, and updates

### Region ids and logical handles

`ebox-region-ids` returns region ids in document order from an unrendered tree
or rendered string. Capture ids before the first mount if a low-level source
mapping needs them:

```elisp
(let* ((root (ebox-column
              (ebox-create :id "title" :content "Title")
              (ebox-create :id "body" :content "Body")))
       (ids (ebox-region-ids root)))
  (ebox-render-to-buffer "*Ebox Demo*" root)
  ids)
```

For application updates, prefer logical ids and opaque handles:

```elisp
(let ((handle (ebox-region-resolve "*Ebox Demo*" "body")))
  (ebox-region-update handle :content "Changed" :color "#166534"))
```

`ebox-region-resolve` signals when the buffer is absent, the logical id is
missing, or the id is ambiguous. A handle is scoped to one retained TP
surface; it becomes stale when its object is removed or its buffer is killed.
Numeric region ids are render metadata and are not accepted by
`ebox-region-update`.

### Direct and selector updates

`ebox-region-update` accepts mutable content/style/scroll property keywords and
returns the committed update report unless an explicit batch queues it. It
builds an isolated candidate, plans the smallest safe Ebox owner, and asks TP
to publish once. It does not add children or mutate `:id`, `:class`, `:key`,
or other selector metadata. Invalid declarations, render failures, publication
failures, and callback failures leave the previous buffer/runtime/report intact.

`ebox-selector-update-buffer` applies properties to all editable selector
matches and returns:

```elisp
(:selector SELECTOR
 :matched INTEGER
 :updated INTEGER
 :skipped ((:node-id ID :reason no-region) ...)
 :reports (REPORT ...))
```

An explicit multi-update batch can use the lower-level incremental batch
functions only when an application deliberately owns that boundary; the
normal public alternative is `ebox-selector-update-buffer`.

### Logical candidates

Candidates are one-shot transactions based on the exact currently published
runtime. They are useful when several stable subtrees must be replaced before
one commit:

```elisp
(let* ((buffer (get-buffer "*Ebox Demo*"))
       (candidate (ebox-candidate-begin buffer))
       (match (car (ebox-selector-query-buffer buffer "#body"))))
  (ebox-candidate-replace
   candidate
   (plist-get match :node-id)
   (ebox-create :id "body" :content "Candidate replacement"))
  (ebox-commit buffer candidate))
```

Frameworks that retain semantic owners separately from backend anchors can
use `ebox-range-ref-present-p` as a read-only check before choosing a wider
published owner. It returns nil when the semantic Range is nested inside a
material anchor and therefore is not independently addressable in the current
Ebox publication.

`ebox-candidate-replace-host-ref` uses an application-owned `:host-ref`
instead of a runtime node id. Both replacement functions accept optional
`old-semantic-key` and `new-semantic-key` pairs for bounded detached identity
reuse. A candidate is sealed by commit and cannot be reused; it also becomes
stale if the captured buffer runtime or buffer tick changes.

`ebox-candidate-patch-host-paint` compares previous and next declarative Host
outputs and records a node-local patch only when every changed field is
paint-only. It retains child/runtime identity, updates inherited foreground
state in one affected-subtree pass, and returns nil when ordinary subtree
replacement is required.

`ebox-candidate-replace-root` targets a private candidate-bound root address.
It accepts exactly one declarative node, clears caller runtime identities, and
is last-wins. The final root replacement absorbs descendant node and host-ref
operations recorded before or after it, with no wrapper or public reference.

`ebox-child-range` creates a non-node segment descriptor in a material child
list. Its non-nil ref is root-global and its items participate directly in the
parent's key, selector, style, and layout scope. Use
`ebox-candidate-replace-range-ref` with a proper declarative node list to
replace that base payload. Empty payloads remain addressable.

### Host-reference positions

```elisp
(ebox-host-ref-position "*Ebox Demo*" 'toolbar)
;; => first live character position, or nil
(ebox-host-ref-bounds "*Ebox Demo*" 'toolbar)
;; => (START . END), excluding margins, or nil
```

Positions and bounds belong to the current publication generation. Obtain new
values after any update. Ebox's host-reference table is distinct from logical
selector ids.

### Reports and viewport reflow

Frameworks that allocate a new view tree before calling Ebox can include the
whole input callback in Ebox's render GC budget:

```elisp
(ebox-call-with-render-burst
 (lambda ()
   (let ((next-root (build-framework-view)))
     (ebox-commit buffer next-root))))
```

`ebox-call-with-render-burst` is the preferred exception-safe boundary.  When
the operation cannot be expressed as one function call,
`ebox-render-burst-begin` returns an opaque token for
`ebox-render-burst-end`; callers must use `unwind-protect` and end nested
tokens in last-in, first-out order.  Interactive bursts share Ebox commit's
deferred state and restore the caller's GC settings 0.2 seconds after the
outermost end.  A new burst cancels and supersedes the pending restore.  Batch
bursts restore the exact threshold and percentage immediately and do not run
GC at the boundary.  These functions only define allocation/GC ownership;
they do not publish, commit, or expose Ebox runtime state.

`ebox-buffer-update-report` returns a defensive copy of the last successful
report for a mounted buffer; it signals for a missing/non-Ebox buffer. A fresh
mount has no update report until its first update. Reports include the Ebox
strategy and publication scope plus TP surface revision and physical
operation/reconciliation facts.

The complete commit signature is `(ebox-commit BUFFER NEXT-ROOT &optional
FRAMEWORK-PUBLISH FRAMEWORK-ROLLBACK)`. Publish receives the report after the
buffer, TP surface, and Ebox runtime agree. If a later phase fails, rollback
receives that same report at most once; rollback errors and quits are contained.
`:framework-participant-state`, `:framework-participant-diagnostics`, and
`:scroll-finalization-diagnostics` are read-only outcome fields.

Use `ebox-rerender-buffer-with-context` when a root depends on a new viewport:

```elisp
(ebox-rerender-buffer-with-context
 (get-buffer "*Ebox Demo*")
 800                         ; viewport width in pixels
 30)                         ; optional viewport height in lines
```

This preserves node/region identity and routes the change through viewport
dirty planning. `(viewport)` and `(viewport-height)` are resolved from this
context. For pure rendering, callers may instead bind `ebox-viewport-width`
in pixels and `ebox-viewport-height` in lines around the render. Do not mutate
a published node tree in place.

Visible mounted buffers follow their displaying window automatically. Ebox
publishes every size event immediately through its retained incremental path.
The Emacs hook is serialized and reentrant calls are rejected; there is no
second host hook, timer, or viewport queue.
`ebox-viewport-window-width` returns the same display-safe pixel width used by
that controller, so hosts must not install a second resize hook or width rule.
The former `ebox-viewport-resize-delay` setting has been removed; immediate
delivery has no timer setting to migrate.

## 7. Selectors

`ebox-selector-parse` delegates to ECSS and returns its structured AST.
`ebox-selector-match-node-p` matches one declarative node against a selector
or AST. `ebox-selector-query-all` returns document-ordered matches from an
unmounted tree. `ebox-selector-query-buffer` queries the retained runtime of a
live buffer and adds `:buffer` and, when the node is editable, `:region-handle`
to each match record.

Supported selector syntax comes from ECSS:

- selector lists and compound type/id/class selectors;
- attribute presence and `=`, `~=`, `|=`, `^=`, `$=`, `*=` operators with `i`
  and `s` flags;
- state pseudos such as `:hover` and `:active` through `:selector-state`;
- `:is(...)`, `:where(...)`, `:not(...)`, and relational `:has(...)`;
- descendant whitespace, child `>`, adjacent sibling `+`, and general sibling
  `~` combinators.

Ebox node types are exposed as selector types `box`, `row`, `column`, `flex`,
`grid`, and `item`. `:id` and `:key` become built-in attributes. Additional
attributes must be supplied explicitly, for example
`:selector-attributes '((role . button))`; visible content, layout values,
and internal runtime slots are never inferred as selector attributes.

```elisp
(ebox-selector-query-buffer "*Ebox Demo*" ".toolbar > box.action")
(ebox-selector-query-buffer "*Ebox Demo*" "div:has(> .warning)")
(ebox-selector-update-buffer "*Ebox Demo*" "[role=button]"
                             :color "#2563EB")
```

The compatibility aliases `ebox-select-all` and `ebox-update-selector` refer
to `ebox-selector-query-buffer` and `ebox-selector-update-buffer`.

## 8. Scrolling and viewport state

Set `:overflow 'scroll` (the default) and a finite `:height` to create a
scroll window:

```elisp
(ebox-create
 :id "log"
 :width '(420)
 :height 8
 :overflow 'scroll
 :content (mapconcat #'identity lines "\n"))
```

`ebox-scroll-down`, `ebox-scroll-up`, `ebox-scroll-page-down`, and
`ebox-scroll-page-up` operate on the innermost scroll region at point. They
delegate to ordinary Emacs scrolling when no Ebox region can consume the
command. `ebox-wheel-scroll-down` and `ebox-wheel-scroll-up` accept mouse
events, animate when `ebox-wheel-smooth-scroll` is non-nil, and otherwise
delegate to `mwheel-scroll`. `ebox-buffer-mode` installs `ebox-scroll-map`
locally; `ebox-render-to-buffer` enables the mode on its returned buffer.

`ebox-scroll-state` accepts a numeric region id and returns a read-only state
plist for source-model mapping. Its useful public facts include the current
`:scroll-offset`, content height/lines, and cached visible lines. Treat the
plist as diagnostic/read-only data; use `ebox-region-update` with
`:scroll-offset` or the scroll commands to change position.

Scroll content is lazily prefetched and can be rendered in bounded slices.
Ebox preserves cached scroll state across safe retained updates and rolls it
back with the rest of a failed publication.

## 9. Measurement and cache controls

`ebox-string-pixel-width` returns the first-line display pixel width of a
string, honoring text scale and fixed `display` spaces. It is the same public
measurement primitive used by layout. `ebox-display-signature` returns the
current display inputs used for measurement cache invalidation. Call
`ebox-clear-cache` after changing font or named-face metrics outside the normal
display-signature signals.

The main customization variables are:

| Group | Variables and defaults |
| --- | --- |
| Render cache | `ebox-render-cache-max-entries` 2048; `ebox-render-cache-max-bytes` 32 MiB; `ebox-render-root-cache-max-entries` 16; `ebox-render-root-cache-max-bytes` 8 MiB |
| Keyboard/mouse scroll | `ebox-scroll-step` 1; `ebox-wheel-scroll-step` 1; `ebox-wheel-smooth-scroll` nil; `ebox-wheel-smooth-scroll-interval` 0.016; `ebox-wheel-smooth-scroll-lines-per-tick` 4; `ebox-wheel-smooth-scroll-target-ticks` 8. Keyboard uses point; wheel uses event position; residual lines bubble through nested owners. An interactive complete, chrome-free root document owner may be idle-materialized once and then use Emacs's native window line start; ordinary updates/resizes only warm retained indexes and never start a second native publication; nested/lazy/chrome owners retain transactional Ebox publication. |
| Lazy scroll | `ebox-scroll-lazy-prefix-lookahead-lines` 8; `ebox-scroll-lazy-idle-prefetch-lines` 128; `ebox-scroll-lazy-idle-prefetch-slice-lines` 16; `ebox-scroll-lazy-idle-prefetch-delay` 0.15 |
| Runtime prewarm | `ebox-runtime-idle-prewarm` t; `ebox-runtime-idle-prewarm-delay` 0.1; `ebox-runtime-idle-prewarm-prefix-resume-delay` 2.0; `ebox-runtime-idle-prewarm-slice-size` 32; `ebox-native-buffer-scroll` t (initial/visible-window handoff only; strict root-owner proof) |
| Predicted reflow | `ebox-runtime-idle-reflow-cache-prewarm` t; `ebox-runtime-idle-reflow-cache-prewarm-delay` 0.15 |
| Reflow GC | `ebox-reflow-cache-prewarm-gc-cons-threshold` `auto`; `ebox-reflow-cache-prewarm-gc-auto-frame-budget` 0.2; `ebox-reflow-cache-prewarm-gc-auto-min-threshold` 64 MiB; `ebox-reflow-cache-prewarm-gc-auto-max-threshold` 1 GiB; `ebox-reflow-cache-prewarm-gc-auto-initial-threshold` 512 MiB; `ebox-reflow-cache-prewarm-gc-auto-target-layouts` 24; `ebox-reflow-cache-prewarm-gc-cons-percentage` 0.1 |
| Visual verification | `ebox-visual-check-output-dir` points to the temporary directory used for optional screenshots and reports. |

Idle prewarming never publishes buffer text or runtime state. Set the relevant
boolean to nil when a host application must avoid background preparation.

## 10. Standalone `.ebox` DSL

`ebox-build` compiles a data-oriented list form. Supported tags are `box` and
`ebox`, `row`, `column`, `flex`, `item`, `grid`, and `spacer`:

```elisp
(ebox-build
 '(grid :width (640)
        :grid-template-columns ((200) 1fr 1fr)
        :gap (1 (12))
        (box :grid-column (1 :span 3) :content "Header")
        (box :content "Main")))
```

Strings directly under `box` become newline-joined content. Child forms become
a default vertical child layout. `row` and `column` can receive box
properties around their child layout. `flex` accepts container properties;
`item` accepts flex item properties and exactly one or more child forms;
`spacer` accepts no children.

Inside a `.ebox` file, keep structural forms unquoted. Quote list and symbol
constants in property positions when they are data, such as
`:gap '(1 (12))` or `:justify-content 'center`; executable Elisp expressions
remain unquoted for the sibling playground runner.

## 11. Optional Rust reflow

The native module is an accelerator, not a correctness dependency. Its Rust
boundary receives bounded numeric layout work only; Ebox keeps the Elisp path
as the exact fallback and never builds Rust while loading.

```elisp
(ebox-native-status)       ; show toolchain, path, ABI, and load diagnosis
(ebox-native-build)        ; asynchronous build/install
(ebox-native-build t)      ; clean Ebox's private Cargo cache first
```

The equivalent repository command is `make native-build`. Configure
`ebox-native-reflow-module-path` with a module file or directory. Session
limits are `ebox-native-reflow-max-jobs` 512,
`ebox-native-reflow-max-results` 512, and
`ebox-native-reflow-max-result-bytes` 64 MiB. A missing or incompatible module
leaves Ebox on Elisp; `ebox-native-status` reports the reason.

`ebox-byte-compile` recompiles all active Ebox Elisp sources and does not build
Rust. Restart Emacs after a successful byte compilation if the current
process should load the new `.elc` files.

## 12. Public function inventory

The following table covers the public functions in the facade inventory. The
style-rule functions immediately below are public module-level style APIs.

| Function | Use |
| --- | --- |
| `ebox-text-create`, `ebox-normal-layout-create`, `ebox-row-layout-create`, `ebox-column-layout-create`, `ebox-flex-layout-create`, `ebox-grid-layout-create`, `ebox-box-create` | Framework-integration port for typed TextNode, Normal/Row/Column/Flex/Grid LayoutConfig, and BoxNode values. |
| `ebox-create`, `ebox-build` | Create a legacy node or compile the `.ebox` list DSL during migration. |
| `ebox-concat`, `ebox-stack`, `ebox-row`, `ebox-column`, `ebox-spacer` | Compose simple horizontal/vertical layouts and blank boxes. |
| `ebox-flex`, `ebox-flex-item` | Build flex containers and item metadata. |
| `ebox-grid`, `ebox-grid-fr` | Build Grid layouts and fractional tracks; placement metadata belongs to direct child Boxes. |
| `ebox-render`, `ebox-render-to-buffer`, `ebox-display-buffer` | Pure materialization, retained mount, and display wrapper. |
| `ebox-commit`, `ebox-buffer-update-report`, `ebox-rerender-buffer-with-context`, `ebox-viewport-window-width` | Atomic root commit, report lookup, viewport-context rerender, and the shared display-safe width sampler. |
| `ebox-region-ids`, `ebox-region-resolve`, `ebox-region-update` | Region mapping, logical handle lookup, and direct update. |
| `ebox-child-range`, `ebox-range-ref-present-p`, `ebox-candidate-begin`, `ebox-candidate-replace`, `ebox-candidate-replace-range-ref`, `ebox-candidate-replace-root`, `ebox-candidate-replace-host-ref`, `ebox-candidate-patch-host-paint` | Persistent material child segments, backend-anchor lookup, subtree replacement, and retained Host paint transactions. |
| `ebox-host-ref-bounds`, `ebox-host-ref-position` | Live host-reference bounds and first position. |
| `ebox-selector-parse`, `ebox-selector-match-node-p`, `ebox-selector-query-all`, `ebox-selector-query-buffer`, `ebox-selector-update-buffer` | ECSS selector compilation, matching, querying, and batch update. |
| `ebox-select-all`, `ebox-update-selector` | Compatibility aliases for the two buffer selector functions. |
| `ebox-buffer-mode`, `ebox-scroll-map`, `ebox-scroll-down`, `ebox-scroll-up`, `ebox-scroll-page-down`, `ebox-scroll-page-up`, `ebox-wheel-scroll-down`, `ebox-wheel-scroll-up`, `ebox-scroll-state` | Interactive scrolling, local keymap, and read-only scroll state. |
| `ebox-string-pixel-width`, `ebox-display-signature`, `ebox-clear-cache` | Display-aware measurement and cache management. |
| `ebox-native-build`, `ebox-native-status`, `ebox-byte-compile` | Optional native workflow and Elisp byte compilation. |

Style-rule and style inspection entry points available after `(require 'ebox)`
include `ebox-style-add-rule`, `ebox-style-reset-rules`,
`ebox-style-cascade-active-p`, `ebox-style-compute`,
`ebox-style-expand-shorthands`, `ebox-style-compile-declarations`,
`ebox-style-merge-declarations`, `ebox-style-compute-subject`,
`ebox-style-property`, `ebox-style-canonical-name`, and
`ebox-style-dirty-kind`. The first two are the normal application entry
points; the remaining helpers are for integrations that need to inspect or
prepare ECSS-backed style data.

## 13. Verification and support boundary

From the repository root:

```sh
make load EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make compile EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make check EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make docs-contract-tests EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make native-rust-tests
```

Focused targets include `make core-tests`, `make grid-tests`,
`make surface-tests`, `make selector-tests`, `make dsl-tests`,
`make flex-tests`, and `make visual-check-tests`. The sibling
`ebox-playground` package owns runnable example fixtures; ETAF owns
Components, state, controls, and application behavior. Do not call private
`ebox--*` functions or edit the historical Ebox checkout as part of
this package.
