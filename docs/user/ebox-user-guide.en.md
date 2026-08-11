# Ebox user guide

Ebox is the low-level box, layout, and buffer-rendering package. Use it directly when an application needs precise geometry or use it as the rendering substrate below ETAF. This guide intentionally does not introduce Components, reactive state, behaviors, or application data.

## 1. Load the package

```elisp
(add-to-list 'load-path "/path/to/github/ebox")
(require 'ebox)
```

Loading defines the public package and its pure layout modules. It does not create a buffer, install a mode, build Rust code, or change the current editing buffer.

## 2. Build a node tree

`ebox-create` makes a node. Container helpers accept child nodes and return another node:

```elisp
(ebox-column
 (ebox-create :content "Title"
              :face 'bold
              :color "#263244"
              :bgcolor "#F4F6FB"
              :padding '(1 2))
 (ebox-row
  (ebox-create :content "Left" :width 12)
  (ebox-create :content "Right" :width 12)))
```

The public shape is data, not rendered text. A node may contain `:content`, `:ebox-content-node`, or child nodes supplied to a container. Use `:key` when siblings have stable application identity and `:host-ref` when an application needs a public handle position after rendering.

## 3. Dimensions and surface properties

Ordinary horizontal numbers are character columns. A one-element list denotes a pixel width; vertical numbers are line counts. Padding and margins accept scalar or CSS-like 1–4-value forms. Borders are width, style, and color:

```elisp
(ebox-create
 :content "A readable panel"
 :width '(420)
 :padding '(1 2)
 :margin '(0 1)
 :border '((1) solid "#8A93A6")
 :color "#263244"
 :bgcolor "#FFFFFF")
```

Keep foreground and background explicit on tinted surfaces. `:face` may be a face symbol or a face plist; use `:color` and `:bgcolor` when the surface itself carries semantic colors.

## 4. Row, column, flex, and Grid

Use row and column for simple one-dimensional composition. Use flex when free space is distributed among items. Use Grid when two-dimensional tracks or stable placement matter:

```elisp
(ebox-grid
 :width '(640)
 :grid-template-columns '((200) 1fr 1fr)
 :grid-template-rows '(1 1)
 :gap '(1 (12))
 :padding '(1 2)
 :border '((1) solid "#8A93A6")
 (ebox-create :content "Header" :grid-column 1 :grid-column-span 3)
 (ebox-create :content "Navigation" :grid-column 1 :grid-row 2)
 (ebox-create :content "Main" :grid-column 2 :grid-row 2)
 (ebox-create :content "Aside" :grid-column 3 :grid-row 2))
```

Grid tracks can be fixed, fractional, `auto`, `minmax`, or repeated. Explicit placement is one-based. Use positive integer spans and let implicit tracks fill omitted positions. Multiline items are aligned line by line to their grid rectangle before a wrapper border is painted, keeping a bordered Grid's right edge continuous even when child lines have different natural widths.

## 5. Render text or a buffer

`ebox-render` is pure with respect to buffers and returns propertized text through an ephemeral TP surface. `ebox-render-to-buffer` copies the declarative source and mounts a retained TP surface for initial publication:

```elisp
(let ((node (ebox-column
             (ebox-create :id "status" :content "Ready" :width '(240))
             (ebox-create :content "Rendered by Ebox"))))
  (ebox-render node)
  (ebox-render-to-buffer "*Ebox Demo*" node))
```

The returned text carries display, face, region, and identity properties needed by Ebox. Do not edit those properties by hand. The source node remains caller-owned and can be mounted in more than one buffer; each buffer receives independent runtime identity and state.

## 6. Update an existing buffer

Build a fresh root tree and commit it to the existing buffer:

```elisp
(ebox-commit
 "*Ebox Demo*"
 (ebox-column
  (ebox-create :content "Updated" :key 'title :width '(240))))
```

Ebox compares stable keys and region identity, prepares the semantic dirty/owner plan, and asks TP to atomically publish the new retained surface and Ebox runtime state. It records both the Ebox plan and TP execution summary:

```elisp
(ebox-buffer-update-report "*Ebox Demo*")
```

If a candidate cannot be proven safe, Ebox escalates to an owner or root rerender. A failed render, publication, runtime-state swap, or publication callback leaves the previous buffer, TP surface, Ebox runtime state, and last successful report intact.

## 7. Selectors and handles

Selectors query the rendered tree and return public match records. They do not own application state. Give an editable box a logical `:id`, resolve it in one live buffer, and pass the opaque surface-scoped handle to `ebox-region-update`:

```elisp
(let ((handle (ebox-region-resolve "*Ebox Demo*" "status")))
  (ebox-region-update handle :content "Ready" :color "#166534"))
```

The same logical id in two buffers resolves to two different handles, so updating one surface cannot accidentally mutate the other. A handle becomes stale when its retained object is removed or its buffer is killed. `ebox-region-update` accepts only a live handle; numeric region ids are internal render metadata and are not an update API.

`ebox-selector-parse` compiles CSS-like strings directly to ECSS's structured selector AST. Queries support type, `#id`, `.class`, `[key=value]`, descendant whitespace, child `>`, adjacent sibling `+`, and general sibling `~`. Ebox maps logical children and indexed candidates to ECSS subjects; `ecss-selector-match-p` is the only final matcher, so query and cascade semantics cannot diverge. Attribute selectors see built-in `:id`/`:key` plus metadata explicitly supplied through `:selector-attributes`, for example `:selector-attributes '((role . button))`; visible content, layout properties, Ebox runtime containers, and internal `:ebox-*` slots never become selector attributes implicitly.

```elisp
(ebox-selector-query-buffer "*Ebox Demo*" ".toolbar > box.action")
(ebox-selector-query-buffer "*Ebox Demo*" "#first + .later")
(ebox-selector-query-buffer "*Ebox Demo*" "#first ~ [role=button]")
```

## 8. Standalone `.ebox` files

`ebox-build` reads one data-oriented Ebox form:

```elisp
(ebox-build
 '(grid :width (640)
        :grid-template-columns ((200) 1fr 1fr)
        :gap (1 (12))
        (box :content "A")
        (box :content "B")
        (box :content "C")))
```

Inside a `.ebox` fixture, keep the structural form unquoted. Quote list and symbol constants in property positions (for example, `:gap '(1 (12))` and `:justify-content 'center`), while leaving executable Elisp property expressions unquoted. `ebox-playground` evaluates those property expressions before passing the form to `ebox-build`, matching the `etaf-view` value convention.

Executable `.ebox` references are maintained by the sibling [`ebox-playground`](../../ebox-playground/README.md) package. Its `examples/` directory contains the migrated Basic, Comprehensive, Flex, Responsive, and complete Grid reference files; they remain low-level layout examples and do not require the ETAF framework.

## 9. Optional native reflow

The Rust module accelerates eligible reflow work; it is not required for correctness. Load Ebox normally, run `make native-build` when you want a local module, and configure `ebox-native-reflow-module-path` if the module is outside its default location. Ebox keeps the Elisp path as the exact fallback and never builds native code while loading.

## 10. Public boundary

Use public `ebox-*` functions and constructors. Names beginning with `ebox--` are private implementation details and may change. ETAF is the sibling package for Components, View trees, state, behavior, Context, data, and application lifecycle; Ebox should stay focused on geometry and publication.

## 11. Verification

From the repository root:

```sh
make load EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make compile EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make check EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
```

Use `make grid-tests`, `make dsl-tests`, or `make visual-check-tests` for focused changes. Use `make native-rust-tests` after changing the native module.
