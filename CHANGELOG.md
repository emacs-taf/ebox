# Changelog

All notable changes to Ebox are documented here.

## Unreleased

### Added

- Keyboard focus models composite widgets: `:focus-group` (`vertical`,
  `horizontal` or `grid`) makes a container one Tab stop entered at its
  selected or last focused member and roved with arrows; `:focus-scope modal`
  confines navigation to an open dialog; `ebox-focus-direction` moves to the
  nearest stop in a direction; `ebox-focus-scope` and `ebox-focus-stops`
  expose the scope; `ebox-focus-change-functions` reports each focus move.

- Box backgrounds take `:border-radius` on graphical frames, and block
  padding accepts fractions of a line such as `(lh 0.5)`, painting the
  background over that part of the line while rows keep one line height.
- `ebox-image-prepare` accepts `:inset (TOP . BOTTOM)` to leave a few pixels
  blank above and below a graphics image without changing its rows.
- On macOS, colour emoji are shown as full-height line images rendered by a
  helper compiled with `swiftc` and cached under `ebox-emoji/` in
  `user-emacs-directory`.
- Soft wraps keep closing punctuation off line starts and opening
  punctuation off line ends.
- `ebox-input-begin` accepts `:on-change`, `:on-leave`, `:keymap` and
  `:local-variables`; `ebox-input-edit-commands` lists the keymap commands
  that edit the value.
- The `:scroll-anchor end` style keeps a scroller pinned to its last line
  as content changes until the user scrolls away, for logs and chat views.
- `ebox-node-scroll-into-view` scrolls enclosing scrollers so a node shows.
- The `:swipe` interaction property receives one `left` or `right` call per
  horizontal two-finger trackpad gesture over a node, with momentum absorbed.
- The `:scroll` interaction property receives a scroller's new line offset
  whenever scrolling changes it, so lists can load more rows at an edge.
- `ebox-node-scroll-into-view` takes an optional `start` or `end` alignment.
- `ebox-viewport-measure` returns the viewport a buffer's mount would take,
  before the buffer is mounted.
- `ebox-viewport-change-functions` runs with a mounted buffer after its
  viewport size changed and the new layout settled.
- `make native` byte-compiles Ebox and stores native code in the user's
  `eln-cache`, which Emacs loads in place of the bytecode.

### Changed

- Tab visits focus stops in ascending `:tab-index` and then tree order
  instead of screen rows, so a sidebar's controls all come before the pane
  beside it.

- **BREAKING:** Ebox now exposes a mutable retained-node engine.  Build roots
  with `ebox-build`, `ebox-node-create` or `ebox-text-create`; mount them with
  `ebox-mount`; then update the existing tree with node mutation functions.
  Flushes restyle, relayout and repaint dirty paths, and rewrite only changed
  buffer lines/parts.
- `ebox-file-load-companion` loads a compiled `.ebox` companion when its
  bytecode is newer than the `.el` source; edited sources still load directly.
- An input session no longer makes the painted text writable or defers the
  mount's flushes.  It edits the node's value in a hidden buffer with native
  commands, undo and input methods while the node keeps its padding,
  borders and wrapping and grows as the value does.  Clicks, drags,
  double and triple clicks inside the node edit the value, and input method
  preedit text wraps inside the node instead of overflowing it.
- A `:layer root` absolute box without an anchor is placed and sized from the
  root's border box instead of its content box, so a full-size scrim or
  viewer covers the root's padding.

### Removed

- **BREAKING:** Removed the previous engine's canonical inputs, source builders,
  surfaces, publications, transactions, prepared update/geometry APIs,
  generation/candidate model, layer module, native Rust layout module, framework
  SPI and render-burst interfaces.  Migrate high-level callers by keeping Ebox
  node references instead of external handles: old full input replacement maps to
  building or copying a retained root and mounting it; old source-builder child
  updates map to `ebox-node-insert`, `ebox-node-remove`, `ebox-node-move` or
  `ebox-node-replace-children`; old content/property/selector updates map to
  `ebox-node-set-text`, `ebox-node-set-image`, `ebox-node-set-props`,
  `ebox-node-put`, `ebox-node-set-states` or `ebox-node-restyle`; old explicit
  update grouping maps to `ebox-with-batch`.

### Fixed

- A two-finger swipe that reverses direction starts and fires the next
gesture at once, so consecutive left and right swipes each register
instead of waiting out the momentum's quiet interval.
- An interactive overlay clipped by its host keeps its keymap, pointer and
  help on blank rows and on padding cut at the clip edge, so clicks there
  reach it.
- Transparent pixels of a graphics image show the background of the box
  holding it instead of the frame background, so round avatars blend into
  a highlighted row.
- On graphical frames, glyphs whose fallback font is taller than the line,
  such as colour emoji, symbols, mathematical letters and other fallback
  scripts, are scaled to fit their row.  Rows
  keep one line height, so image slices beside them, such as avatars, stay
  joined.
- Printing keys in a mounted canvas outside an input session no longer
  insert text into the application buffer.
- A node's bounds include the cells under its own absolutely positioned
  children, such as a range control's fill.
- `ebox-node-at` on a padding or gap cell returns the innermost box that
  owns the cell instead of the root.
- `ebox-node-at` on a blank or padding cell inside a scroller returns the
  innermost box under that cell, not the scroller.
- Graphical images paint one slice glyph per row instead of one per cell,
  so scrolling and repainting views with many images no longer stalls;
  an image row cut at a box or overlay edge keeps its visible part.
- Scrolling past a scroller's end no longer scrolls a window that already
  shows the whole buffer, so pinned headers and footers stay in place.
- `ebox-buffer-mode` turns off `show-paren-mode` in the mounted buffer and
  restores it when the mode is disabled, so painted text never shows paren
  match or mismatch highlights.
- An image narrower than its stretched box paints the box background beside
  it, so a photo inside a wider bubble leaves no unpainted gap.
- A mounted viewport in a window without a right fringe ends before the
  truncation column, so full-width rows no longer display Emacs's `$` glyph.
- A mounted buffer shown in a window of another size, without any window
  resizing, refits to that window.
- Content wider than its box is cut at the box edge, so later siblings on a
  line keep their columns instead of shifting right.
- Content that fills a mounted buffer which was empty keeps point and the
  window start at the top, so an application no longer opens scrolled to the
  end of its buffer.
- A mounted buffer's default background follows the root's background color,
  so the partial line below the last row and other space beyond the laid-out
  text match the application surface; unmounting removes the remapping.
- Hover feedback covers every row of a multirow element: the rows join into
  one native `mouse-face` run instead of highlighting only the row under the
  pointer.
- A `:visibility hidden` box keeps its layout slot but paints no interaction
  feedback, so an empty slot no longer shows hover, pointer or help output.

