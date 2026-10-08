# Ebox Manual

[中文](manual.zh-CN.md)

This manual explains the supported retained-engine workflows.  The complete API
inventory, signatures and lifecycle notes live in the Commentary of
[`../ebox.el`](../ebox.el); unlisted symbols are internal.

## 1. Load Ebox

```elisp
(require 'ebox)
```

Loading the package installs definitions only.  It does not create a buffer,
enable a mode or run image conversion.

## 2. Build retained trees

A tree is made of retained mutable nodes.  Detached nodes can be rendered or
mounted; mounted nodes keep their identity and are updated in place.

### Author forms

`ebox-build` accepts one compact author grammar:

| Form | Result |
| --- | --- |
| `"text"` | A text node. |
| `(text PROPS... "text")` | A text node with properties. |
| `(box PROPS... CHILD...)` | A normal box. |
| `(row PROPS... CHILD...)` | A horizontal one-axis container. |
| `(column PROPS... CHILD...)` | A vertical one-axis container. |
| `(flex PROPS... CHILD...)` | A flex container. |
| `(grid PROPS... CHILD...)` | A grid container. |

Children are nested directly.  Properties are ordinary keyword/value pairs.

```elisp
(defvar ebox-guide-root
  (ebox-build
   '(column :id "root" :padding ((lh 1) (ch 2)) :item-gap (lh 1)
            (text :class "title" "Inbox")
            (row :item-gap (ch 1)
                 (box :id "open" :tab-index 0 "Open")
                 (box :id "done" "Done")))))
```

### Programmatic construction

Use `ebox-node-create` and `ebox-text-create` when Lisp code already has the
node shape or needs to retain references.

```elisp
(let* ((label (ebox-text-create "Count: 0" '(:class "counter")))
       (root (ebox-node-create 'column '(:width (ch 20))
                               (list label))))
  (list root label))
```

A node may have only one parent.  Copy a subtree with `ebox-node-copy` when the
same current inputs must be reused elsewhere.

## 3. Mount, render and unmount

`ebox-render` returns a propertized string without a live buffer.  `ebox-mount`
mounts a root node or author form into a buffer and returns the root.  The
buffer text is then owned by Ebox until `ebox-unmount-buffer` releases the
mount.

```elisp
(let ((root (ebox-mount "*Ebox Guide*"
                        '(column :width (ch 24)
                                 (box "First")
                                 (box "Second"))
                        :width 240 :height 8)))
  (ebox-buffer-root "*Ebox Guide*")       ; => root
  (ebox-mount-viewport "*Ebox Guide*"))   ; => (240 . 8)
```

Mount options `:width` and `:height` fix the viewport.  Omit either option to
let Ebox measure the display window when one exists, or use the variables
`ebox-viewport-width` and `ebox-viewport-height` for detached rendering.

## 4. Update nodes and batch flushes

Mutations mark dirty bits and queue the owning mount.  Outside a batch, Ebox
flushes immediately.  Inside `ebox-with-batch`, all queued mounts flush once at
the end of the outermost batch, even on nonlocal exit.

```elisp
(let* ((root (ebox-mount "*Ebox Update*"
                         '(column :width (ch 20)
                                  (box :id "count" "Count: 0")
                                  (box :id "status" "cold"))
                         :width 240 :height 8))
       (count (car (ebox-selector-query root "#count")))
       (status (car (ebox-selector-query root "#status"))))
  (ebox-with-batch
    (ebox-node-set-text (car (ebox-node-children count)) "Count: 1")
    (ebox-node-set-props status '(:background-color "#EEF2FF"))))
```

Useful mutation entry points include:

- `ebox-node-set-text` for text node content.
- `ebox-node-set-props` or `ebox-node-put` for author properties.
- `ebox-node-set-states` and `ebox-node-restyle` for selector state changes.
- `ebox-node-insert`, `ebox-node-remove`, `ebox-node-move` and
  `ebox-node-replace-children` for structure.
- `ebox-node-set-image` for prepared image content.

After a flush, query geometry with `ebox-node-geometry`, buffer positions with
`ebox-node-position` or `ebox-node-bounds`, and hit testing with `ebox-node-at`.

## 5. Styles, ECSS scopes and selectors

Inline properties are validated when nodes are built or updated.  Geometry uses
explicit length data such as `(px 120)`, `(ch 20)`, `(lh 2)`, `(% 50)`, `(vw 50)`
and `(vh 25)`.  `calc`, `min`, `max` and `clamp` compose lengths as data.
Horizontal properties accept horizontal units, vertical properties accept
line/viewport-height units, and border widths accept stroke units.  Bare numbers
are not public lengths.

Text and boxes support font, color and text-decoration properties.  Boxes also
support dimensions, padding, margin, borders, overflow, visibility, positioning,
row/column gaps, flex item/container properties and grid tracks/placement.  The
schema is strict; invalid properties or values signal before an existing mount is
changed.  Left and right borders paint at their resolved pixel width.  Top and
bottom borders draw as the line's overline or underline, so a top or bottom
border wider than 1px signals `ebox-error`.

Inline ECSS rules can be attached with `:ecss`.  Reusable scopes are created with
`ebox-style-scope-create`, attached to a root with `:ecss-scope-roots`, and
joined by members through `:ecss-scopes`.

```elisp
(let* ((scope (ebox-style-scope-create
               '((".warn" :color "#B45309" :font-weight bold))
               :origin 'author))
       (root (ebox-mount "*Ebox Styles*"
                         `(column :ecss-scope-roots (,scope)
                                  (text :class "warn" "Warning")
                                  (text "Normal"))
                         :width 240 :height 6)))
  (length (ebox-selector-query root ".warn"))) ; => 1
```

Selectors see retained nodes through ECSS subject facts: type, `:id`, `:class`,
`:attributes`, `:states`, parent and children.  As in CSS, `[id="..."]` and
`[key="..."]` match a node's `:id` and `:key`, including ids that are not
valid `#` identifiers.  Interaction also derives `focus`, `active` and
`disabled` selector states.

Use `ebox-selector-query`, `ebox-selector-query-buffer` and
`ebox-selector-match-node-p` for public selector work.

## 6. Layout and positioning

Choose the smallest container that states the layout intent:

- `box` stacks block children and lays inline text in paragraphs.
- `row` and `column` place direct children along one axis and support
  `:item-gap` and `:cross-align`.
- `flex` supports flex direction, wrapping, distribution, item growth/shrink and
  alignment.
- `grid` supports explicit/automatic tracks, fractions, `minmax`, `repeat`, gaps
  and one-based placement.

Absolute positioning is part of box layout.  An absolute child is removed from
its parent's flow and placed from the parent's content origin by `:left` and
`:top` (an inline parent defers to its nearest enclosing box); the parent clips
the composed overlay to its canvas, so give it an explicit height when absolute
children need reserved space. `:z-index` orders overlapping paint.  The
`:layer` property can select the root paint target while preserving logical
parentage for selectors and inheritance.  Anchored absolute boxes use `:anchor`
and `:placement` to position relative to a unique semantic target in their host.
While that target is missing the box paints nothing, has no position and cannot
take focus.

`overflow hidden` clips horizontally and vertically at whole display units.
`overflow scroll` provides vertical scrolling through the scrolling APIs below.

## 7. Interaction

Interaction capabilities are author properties retained on nodes.  During paint,
Ebox copies them to Emacs text properties over the node's content, padding and
border; descendants with explicit values override ancestors.

### Keymaps, activation and focus

Create native keymaps with `ebox-keymap-create`.

```elisp
(defvar ebox-guide-activated nil)

(let* ((root (ebox-mount
              "*Ebox Interaction*"
              `(column :width (ch 20)
                       (box :id "button" :tab-index 0
                            :keymap ,(ebox-keymap-create
                                       :activate (lambda ()
                                                   (setq ebox-guide-activated t)))
                            "Activate"))
              :width 240 :height 6))
       (button (car (ebox-selector-query root "#button"))))
  (ebox-focus button "*Ebox Interaction*")
  (with-current-buffer "*Ebox Interaction*"
    (ebox-activate (ebox-node-position button) t)))
```

`ebox-mount` enables `ebox-buffer-mode`, which installs scrolling keys,
TAB/backtab focus cycling and RET/return activation; unmounting disables it.
After turning the mode off, applications can call
`ebox-focus`, `ebox-focus-next`, `ebox-focus-previous`, `ebox-focus-within`,
`ebox-activate`, `ebox-next-interaction` and `ebox-previous-interaction`
directly.

### Help, pointers, hover and drag

- `:help-echo` accepts a string or a function made with `ebox-help-create`.
- `:pointer` sets an Emacs pointer shape.
- `:hover-style` maps to `mouse-face` for color and text-decoration changes.
- Descendants inherit an ancestor's `:help-echo`, `:pointer`, `:hover-style` and
  `:keymap`; an explicit nil on the descendant blocks the inherited value.
- `:hover-content` temporarily replaces a text node or the first child text of a
  box while the mouse is over a group; `:hover-group` updates related members as
  one batch.
- `ebox-keymap-create` can bind `:drag` callbacks and a supported
  `:drag-lock-modifier`.  Drag callbacks receive a plist with phase, node,
  window, buffer, start, position, delta and cancellation reason.

### Input sessions

Input sessions are the only supported way to let the user edit mounted text
directly.  A session flushes pending changes, makes the painted span writable,
defers further writes for that mount, and restores the published text when it
ends.

```elisp
(let* ((root (ebox-mount "*Ebox Input*" '(box :id "field" "draft")
                         :width 160 :height 3))
       (field (car (ebox-selector-query root "#field")))
       (session (ebox-input-begin "*Ebox Input*" field)))
  (prog1 (ebox-input-text session)
    (ebox-input-end session)))
```

Use `ebox-call-with-input` for a short synchronous reader around a visible,
enabled node.  `ebox-input-cancelled` means the node or mount disappeared before
control returned.

## 8. Scrolling

A node with `:overflow scroll` or `auto` and content taller than its viewport is
scrollable.  Scroll offsets are stored on the retained node.

```elisp
(let* ((root (ebox-mount "*Ebox Scroll*"
                         '(box :id "pane" :height (lh 2) :overflow scroll
                               "one\ntwo\nthree\nfour")
                         :width 200 :height 4))
       (pane (car (ebox-selector-query root "#pane"))))
  (ebox-node-set-scroll pane 1)
  (ebox-node-scroll-offset pane)) ; => 1
```

Interactive commands scroll the innermost scrollable node under point first and
fall back to ordinary window scrolling when no Ebox node can consume the rest:
`ebox-scroll-down`, `ebox-scroll-up`, `ebox-scroll-page-down`,
`ebox-scroll-page-up`, `ebox-wheel-scroll-down` and `ebox-wheel-scroll-up`.
`ebox-scroll-step` controls wheel and line-step size.

## 9. Images

Images are prepared into immutable character grids before rendering.  Preparation
owns file reads, Emacs image descriptors, optional converter processes and the
fallback placeholder.  Rendering and buffer writes only copy prepared content.

```elisp
(let* ((prepared (ebox-image-prepare "cover.png" 24 12
                                     :adapter 'placeholder))
       (image (ebox-node-create 'image (list :image prepared)))
       (root (ebox-node-create 'column nil
                               (list image (ebox-text-create "caption")))))
  (ebox-render root))
```

Use `ebox-image-info` to inspect the chosen adapter and dimensions,
`ebox-image-content` to get an owned string, and `ebox-image-cache-clear` after
converter or font capability changes.  To change an image node in place, prepare
the new value and call `ebox-node-set-image`.

## 10. Viewport and refit

A mounted buffer has one viewport.  Ebox measures the selected or displayed
window when fixed `:width`/`:height` options are absent.  Use separate buffers
for the same tree at independent widths.

- `ebox-mount-viewport` returns the current `(WIDTH . HEIGHT)`.
- `ebox-mount-set-viewport` fixes or clears dimensions, then refits.
- `ebox-refit` remeasures the display window and relayouts only nodes that read
  changed viewport units or whose root size follows the viewport.
- `ebox-viewport-window-width` reports usable pixel width for a window.
- `ebox-viewport-settle-delay` controls trailing refit after window-size events.

## 11. Observer and update report

Set an observer to receive each successful flush report.  The same report is
available later with `ebox-buffer-update-report`.

```elisp
(let ((root (ebox-mount "*Ebox Report*" '(box :id "n" "old")
                       :width 160 :height 3)))
  (ebox-buffer-set-observer
   "*Ebox Report*"
   (lambda (_buffer report) (message "Ebox wrote %S" report)))
  (ebox-node-set-text (car (ebox-node-children
                            (car (ebox-selector-query root "#n"))))
                      "new")
  (ebox-buffer-update-report "*Ebox Report*"))
```

Reports contain `:strategy` (`full` or `lines`), `:edits`, `:lines`, `:ranges`,
`:flush` and, for observer calls, `:duration-ms`.

## 12. Failures and recovery

Ebox validates public inputs at the boundary and signals ordinary Emacs errors
under Ebox-specific error symbols where documented in `ebox.el`.

- Invalid style properties, size units, selector facts or image arguments signal
  before mutating an existing mounted buffer.
- A node with a parent cannot be inserted elsewhere; detach or copy it first.
- A text node cannot contain children.
- `ebox-focus`, activation, scrolling and input-session entry points signal
  `user-error` or `ebox-input-error` when the requested target is unavailable.
- An active input session defers flushes for that mount; ending the session
  restores the published text and then writes queued tree changes.
- `ebox-unmount-buffer` releases markers, hooks and mount state while leaving the
  current buffer text in place.
- `ebox-clear-cache` should be called after font or named-face metric changes;
  `ebox-image-cache-clear` should be called after converter or image capability
  changes.

When a buffer has been edited outside Ebox, the next write discards remembered
line parts and rewrites from the retained tree.  Treat the node tree, not the
buffer text, as the source of truth.
