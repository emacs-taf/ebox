# Ebox user guide

[中文](ebox-user-guide.zh.md)

Ebox is the low-level Text/Box layout and buffer-rendering package. This guide
uses one public author grammar and keeps framework-integration details separate.
See the [API reference](ebox-api-reference.en.md) for the complete function
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
(defvar ebox-guide-root
  (ebox-build
   '(column :padding (1 2)
            :border ((1) solid "#8A93A6")
            (text :color "#263244" "Research notes")
            (row :item-gap 1
                 (box :id "status" :background-color "#F4F6FB" "Inbox")
                 (box :background-color "#EEF2FF" "Archive")))))
```

Use `box` with geometry but no child when an empty rectangular area is needed.
No extra node type is necessary.

## 3. Choose the layout that states the intent

Use `box` for ordinary content, `row` or `column` for direct one-axis
composition, `flex` when free space or wrapping matters, and `grid` for
two-dimensional tracks or explicit placement.

### Row and column

`row` and `column` accept `:item-gap` and `:cross-align`. Their children remain
ordinary Text or Box nodes.

```elisp
(ebox-build
 '(row :item-gap 2 :cross-align center
       (box :width 12 "Left")
       (box :width 12 "Right")))
```

### Flex

Flex container properties belong to `flex`. Participation properties belong
directly to a child `box` because they describe the parent-child relationship.

```elisp
(ebox-build
 '(flex :width (480)
        :flex-flow (row wrap)
        :gap (1 (12))
        (box :flex (1 1 auto) "Primary")
        (box :flex-grow 2 "Secondary")))
```

### Grid

Grid placement is one-based. Tracks may be fixed, `auto`, fractional,
`minmax`, or `repeat` values. Placement properties also belong directly to a
child `box`.

```elisp
(ebox-build
 '(grid :width (640)
        :grid-template-columns ((200) 1fr 1fr)
        :grid-template-rows (1 1)
        :gap (1 (12))
        (box :grid-column (1 :span 3) "Header")
        (box :grid-column 1 :grid-row 2 "Navigation")
        (box :grid-column 2 :grid-row 2 "Main")
        (box :grid-column 3 :grid-row 2 "Aside")))
```

## 4. Use geometry and paint properties

Horizontal numbers are character columns; a one-element list such as `(240)`
is a pixel width. Vertical numbers are lines. Text accepts only font,
foreground/background, and text-decoration properties. Padding, margin,
border, size, `:outer`, overflow, visibility, and wrapping policy belong only
to Box. Font and color on Box may feed inherited Text facts, but never give
Text Box geometry.

```elisp
(ebox-build
 '(box :width (420)
       :padding (1 2)
       :margin (0 1)
       :border ((1) solid "#8A93A6")
       :color "#263244"
       :background-color "#FFFFFF"
       "A readable panel"))
```

Use `:outer inline` or `:outer block` to state how a Box participates in its
parent. The child-layout algorithm still comes from the form name.

## 5. Render and publish

`ebox-render` returns propertized text without changing a live buffer.
`ebox-render-to-buffer` mounts a retained TP surface and returns its buffer.

```elisp
(ebox-render ebox-guide-root)
(ebox-render-to-buffer "*Ebox Guide*" ebox-guide-root)
```

Build a fresh root and use `ebox-commit` for an atomic update:

```elisp
(ebox-commit
 "*Ebox Guide*"
 (ebox-build
  '(column :padding (1 2)
           (text "Updated notes")
           (box :key body "The new root is caller-owned."))))
```

Validation, rendering, or publication failure leaves the previous buffer and
runtime state intact. `ebox-buffer-update-report` returns a defensive copy of
the last successful update report.

## 6. Query and update a mounted surface

`:id`, `:class`, and `:key` are author metadata. Selectors use ECSS semantics.
Resolve an `:id` to an opaque, surface-scoped handle before a direct update:

```elisp
(let ((handle (ebox-region-resolve "*Ebox Guide*" "status")))
  (ebox-region-update handle :color "#166534"))
```

`ebox-selector-query-buffer` returns document-ordered matches from a mounted
buffer. `ebox-selector-update-buffer` applies one style update to all editable
matches. Numeric region ids are diagnostic render metadata, not stable update
handles.

## 7. Resize and scroll

A finite height plus `:overflow scroll` creates a scroll window. Ebox buffer
mode installs keyboard and wheel commands that route through the innermost
scroll owner before falling back to ordinary Emacs scrolling.

```elisp
(ebox-build
 '(box :id log :width (420) :height 8 :overflow scroll
       "line 1\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7\nline 8\nline 9"))
```

Visible mounted buffers follow their display window. Integrations may apply an
explicit viewport with:

```elisp
(ebox-rerender-buffer-with-context
 (get-buffer "*Ebox Guide*") 800 30)
```

## 8. Standalone `.ebox` files

A `.ebox` file contains one unquoted structural form:

```elisp
(column :padding '(1 2)
        (text :color "#263244" "Title")
        (box :width '(240) "Body"))
```

The sibling `ebox-playground` evaluates property expressions before calling
`ebox-build`. Quote list and symbol constants in a `.ebox` file, as shown
above. When calling `ebox-build` directly, pass inert data as in the earlier
examples.

## 9. Typed integration API

Frameworks that already normalize author input may bypass the list DSL. They
construct one TextNode with `ebox-text-create`, one typed LayoutConfig with the
matching layout constructor, then one BoxNode with `ebox-box-create`.

```elisp
(ebox-box-create
 :layout (ebox-row-layout-create :item-gap 1 :cross-align 'center)
 :children (list (ebox-text-create :value "Left")
                 (ebox-text-create :value "Right")))
```

Here `:layout` and `:children` are fields of the evaluated typed constructor.
They are not author properties and do not extend the seven-entry grammar.

## 10. Optional native reflow and verification

The Rust module is optional and Ebox never builds it while loading:

```elisp
(ebox-native-status)
(ebox-native-build)
```

From the repository root:

```sh
make docs-contract-tests EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make dsl-tests EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make check EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
```
