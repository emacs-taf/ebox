# Ebox Architecture

[中文](architecture.zh-CN.md)

Ebox is implemented as one mutable retained node tree per mount.  Public callers
build a tree, mount it into an Emacs buffer, and mutate nodes.  Ebox records
style, layout and paint dirt on the affected nodes, finds the smallest safe
layout boundary, composes only damaged root lines, and rewrites only changed
buffer line parts.

The public contract is the Commentary in [`../ebox.el`](../ebox.el).  Files under
`lisp/` are private implementation modules.

## Modules and dependency direction

`ebox.el` is the package entry.  It adds `lisp/` to `load-path`, requires the
implementation modules and owns the public API inventory.

Implementation modules are organized by responsibility:

| Module | Responsibility |
| --- | --- |
| `ebox-size.el` | Pure validation and resolution of `(unit number)` lengths and size functions. |
| `ebox-style.el` | Ebox style schema, aliases, validators, shorthand expansion, ECSS scope creation and style compilation. |
| `ebox-measure.el` | Pixel measurement, text-unit segmentation, display-space construction, property comparison and pad twins. |
| `ebox-node.el` | Retained node records, child sequences, author property parsing, author DSL, selector adapter and computed-style records. |
| `ebox-layout.el` | Text, box, row, column and positioned layout; line composition; damage ranges; root-line edit planning. |
| `ebox-flex.el` | Flex and grid algorithms used by `ebox-layout.el`. |
| `ebox-buffer.el` | Mounts, dirty queue, batching, flush orchestration, viewport measurement, buffer diff writing and geometry queries. |
| `ebox-interaction.el` | Keymaps, help/pointer/hover decoration, focus, activation, drag tracking, input sessions, scrolling and selector queries. |
| `ebox-viewport.el` | Window-size event bridge and settled viewport refit scheduling. |
| `ebox-image.el` | Image preparation, converter protocol, immutable raster cache and image content access. |
| `ebox-file.el` | `.ebox` source reading, companion loading, preview mode and package byte compilation helper. |

Low-level pure modules do not know about mounts.  Nodes depend on size, style
and measurement.  Layout depends on retained nodes and calls flex/grid through
private functions.  Buffer flushing depends on node and layout.  Interaction is
layered above mounted buffers.  Viewport delivery only requests `ebox-refit`.
Images are prepared outside layout and become node content.

## Core records

### Nodes

`ebox-node` is the retained tree record.  It stores:

- author identity and selector facts: tag, id, classes, attributes, states, key
  and user data;
- compiled declarations, default rules, local/shared ECSS scopes and active
  scope environment;
- interaction properties such as help, pointer, hover, keymap, tab index and
  disabled state;
- text or prepared image content;
- parent/child links in chunked sequences;
- computed style, measurement cache, intrinsic-size cache and last layout;
- dirty bits, dirty children, structural operations and overlay registration;
- scroll offset and owning mount pointer for roots.

Children and stacked layout items use chunked sequences.  Each element stores
its run and position, keeping insertion, deletion and indexed lookup bounded by
run size plus run count instead of shifting every later element of a flat
vector.

### Computed styles

`ebox-cs` is a hash-consed computed-style record built from ECSS computed
values, parent style and node tag.  It stores full normalized values plus hot
layout fields: faces, inherited paint, dimensions, edges, borders, overflow,
positioning, flex/row/column facts, z order, viewport-unit dependencies and a
layout key.  Equal local inputs share the same style object, so geometry
comparisons can use object identity or interned layout keys.

The style environment is retained on nodes.  Inline rules and defaults become
scopes, and shared scopes contribute only through their explicit roots and
members.  Subject-local scope styles can participate in style cache keys;
structural selectors fall back to ECSS computation.

### Layout and mount records

`ebox-geo` stores resolved margin, border, padding, border-box size,
content-box size, visible height, scroll offset, content height and layout
items.  Stacked layouts use chunked item sequences; positioned layouts use
vectors.  Anonymous inline paragraphs are `ebox-para` records owned by their
box.

`ebox-mount` binds one root to one buffer.  It stores viewport dimensions,
line anchors, remembered written line parts, update reports, observer, focus,
active and hover state, input session, queue flag, flush count and saved display
settings.

## Dirty bits and queueing

Every mutation goes through `ebox--mutation`, which runs the change and flushes
queued mounts unless a batch or flush is active.

Dirty bits are:

- `ebox--d-style`: style or selector inputs changed.
- `ebox--d-layout`: geometry or content size may have changed.
- `ebox--d-paint`: paint can change while geometry is unchanged.
- `ebox--d-desc`: a descendant changed.
- `ebox--d-queued`: the node is listed in its parent's dirty children.

`ebox--mark` sets bits on the changed node, clears intrinsic caches, records the
dirty path in ancestors and queues the mount of the root.  Structural mutations
also push compact operation descriptions onto the parent so stacked layouts can
record precise insertion/removal damage when possible.

`ebox-with-batch` increments a dynamic batch depth.  The outermost unwind path
calls `ebox-flush`, so all queued mounts are written once with the final tree
state.

## Flush pipeline

`ebox--flush-mount` is the central retained-engine pass:

1. Bind the mount viewport and current mount.
2. Run the style pass over dirty paths.
3. Run layout on the root with the current viewport.
4. Place anchored absolute boxes until stable.
5. Prune superseded damage records.
6. Convert damage to ordered root-line edits.
7. Rewrite the whole buffer on the first flush, or rewrite only edit ranges.
8. Store and deliver the update report.

A mount with an active input session stays queued but is not written; ending the
session requeues it and the same pipeline catches up.

## Style pass

`ebox--style-pass` visits a node when its style bit is set, when it has no
computed style, or when an ancestor's computed style changed.  It computes a new
`ebox-cs` from the node's declarations, active scopes and parent style.

If the new style is equal by object identity, no further work is needed.  If
only the layout key is unchanged, Ebox marks paint dirt.  Otherwise it marks
layout dirt, clears intrinsic caches and, where necessary, marks parent layout
because flex/grid item facts, outer participation or absolute positioning affect
the container.

Viewport-unit dependencies are registered in a weak table.  `ebox-refit` uses
that table to mark only nodes that actually read `vw` or `vh` when the mounted
viewport changes.

## Layout passes and relayout boundaries

`ebox--layout` receives a node, available inline pixels, mode (`stretch`,
`shrink` or `exact`), containing block height and optional forced height.  The
last constraint vector is retained on the node.  If the constraint and relevant
dirty bits are unchanged, layout is skipped.

When descendants are dirty, `ebox--relayout-partial` tries to settle only the
recorded dirty children.  A stacked container can absorb a child's height change
by shifting later stack items and adjusting its own content height.  This is the
common relayout boundary: when the ancestor's outer size and child placements
remain compatible, damage stays local.  If a container cannot absorb the change,
Ebox relayouts that container.  If a full relayout leaves the container size and
child places unchanged, inner damage is preserved; otherwise the container's
whole margin box is damaged and ancestors see only its new outer size.

Text measurement is cached per text node, font face and wrap mode.  Paragraph
layout breaks text into pixel-width units, preserving supported clusters and
fixed display spaces.  Boxes resolve horizontal sizes in pixels and vertical
sizes in lines.  Row and column position direct children on one axis.  Flex
performs main-size growth/shrink with min/max freezing, wrapping and alignment.
Grid expands tracks, resolves fixed/intrinsic/fractional sizes and places items
by one-based grid positions.

Absolute boxes are registered with a positioning host: the nearest non-inline
parent, or the root for `:layer root`.  Local overlays compose
inside that host; root-targeted overlays still keep their logical parent for
style and selectors.  Anchored overlays compute placement from a unique target
and are placed after normal layout so target movement can be reflected without
unrelated relayout.

## Paint and parts cache

Layout produces geometry; paint is composed lazily per root line.  A node line is
a tree of string parts representing margins, borders, padding, content,
overlays and interaction properties.  Nodes cache composed line parts up to a
height limit; paragraphs cache wrapped line strings.  Damage invalidates the
changed node and ancestors that have already composed its lines.

`ebox--join-parts` flattens nested parts.  Display spaces are interned by pixel
width and face.  Emacs coalesces adjacent characters whose `display` objects are
`eq`, so `ebox-measure.el` keeps twin pad displays and substitutes an alternate
at part boundaries.  This preserves exact pixel spacing while allowing line
parts to be shared across flushes.

Interaction decoration happens during composition.  Ebox fills absent `ebox-node`,
`keymap`, `help-echo`, `pointer` and `mouse-face` properties so the innermost
explicit node wins and ancestor keymaps cover descendants that do not override
them.  An inner node's explicit nil is painted as a present property, so it
blocks the ancestor's value instead of inheriting it.

Overlays splice into the lines they cover without concatenating them.
`ebox--split-parts` cuts the underlying parts at the overlay's pixel columns;
a string that straddles a cut becomes sized substrings plus edge spaces, and
composed strings record their pixel widths in `ebox--part-widths` so later
splices need no remeasurement.  An overlay line without a border stays a part
list, so moving an overlay costs its covered lines times their part count.

## Buffer writes

The first mount flush erases and writes the full root.  Later flushes compute
root-line edits from damage records.  Each edit is `(START OLD NEW)`, where
`START` is in post-layout line coordinates after preceding edits.

Line anchors every 128 lines let Ebox find edit starts without keeping one marker
per line.  Point and window starts inside rewritten ranges are tracked by line
and column, then restored after the write.

For a changed line, `ebox--write-line` uses the mount's remembered part list.
`ebox--rewrite-parts` removes equal shared string objects at the front and back
and replaces only the middle.  If no remembered parts are available, Ebox falls
back to `ebox--rewrite-line`, which compares characters by prefix/suffix and
sets only changed property runs.  A foreign buffer edit invalidates remembered
parts by buffer tick and the next flush recomputes safely from the retained tree.

Position tracking is skipped when the mount has no lines yet, so the first
content written into an empty buffer leaves point and window starts at the
top.  At the end of each flush `ebox--sync-canvas` remaps the buffer's
`default` background to the root's computed background, so window space
below the last row and beyond the line ends matches the root; unmounting
removes the remap.

## Viewport, scrolling and input

A mount records one viewport.  `ebox-viewport.el` watches frame/window-size
notifications, waits for a quiet interval and calls `ebox-refit` for displayed
mounts.  Temporary minibuffer, completion or echo-area height changes do not
force a smaller viewport unless the frame itself changed.

Scroll offsets live on nodes.  A scroll mutation changes visible content lines,
not layout constraints, so a clean scrollable node can enqueue direct line
damage for its own visible height.

An input session temporarily transfers one painted span to the user.  Ebox saves
markers, original text and read-only state, defers writes for that mount, and on
end restores the retained text before flushing queued node changes.

## Invariants

- The retained node tree is the source of truth; buffer text is an output cache.
- A node has at most one parent.  Detached roots may be rendered or mounted;
  mounted descendants must stay in their root tree.
- Public mutations alone change retained nodes.  Implementation caches are
  invalidated from dirty bits, not by reading buffer text.
- A computed style belongs to the parent style, declarations, selector facts and
  scope environment used to build it.
- Vertical geometry is line based; horizontal geometry is pixel based.
- A clean node under the same constraint keeps its layout and composed line
  caches.  A dirty node either records precise damage or damages the smallest
  boundary whose shape changed.
- Buffer writes preserve unrelated buffer state: read-only, undo list,
  modified flag, point and window starts.
- Image decoding and external converter execution happen only in image
  preparation, never in layout or buffer writing.
- Private modules may change; consumers require only `ebox` and use only the
  symbols documented in `ebox.el`.

## Rationale

The retained tree removes the need to rebuild a complete description for every
small change.  Dirty bits classify what can be reused.  Hash-consed computed
styles make inherited and scoped style reuse cheap.  Relayout boundaries turn
common edits, such as text changes in a vertical stack, into local line damage.
Parts-level buffer diffs avoid replacing characters and properties that Emacs
redisplay can keep.  The result is a small public API: build, mount, mutate,
flush, query and unmount.
