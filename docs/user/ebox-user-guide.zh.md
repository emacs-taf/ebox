# Ebox 用户指南

[English](ebox-user-guide.en.md)

Ebox 是底层 Text/Box 布局与 buffer 渲染包。本指南只使用一套公共 author 语法，
并把框架集成接口单独说明。完整函数清单见[公共 API
参考](ebox-api-reference.zh.md)。

## 1. 加载 Ebox

```elisp
(require 'ebox)
```

加载 Ebox 不会创建 buffer、在当前 buffer 启用 mode，也不会构建 Rust。

## 2. 只学习一个 author 模型

Ebox 文档由 Text 和 Box 节点组成。author 语法只有七个入口：

| 入口 | 含义 |
| --- | --- |
| `"text"` | 一个 Text 节点的简写。 |
| `(text ... "text")` | 带显式文本 property 的 Text。 |
| `(box ... CHILD...)` | 普通视觉 Box。 |
| `(row ... CHILD...)` | 使用简单横向子布局的 Box。 |
| `(column ... CHILD...)` | 使用简单纵向子布局的 Box。 |
| `(flex ... CHILD...)` | 使用 Flex 子布局的 Box。 |
| `(grid ... CHILD...)` | 使用 Grid 子布局的 Box。 |

子节点始终直接嵌套。布局 form 只是选择了子布局算法的 Box，不是另一种视觉对象。

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

需要空矩形区域时，使用只有几何 property、没有子节点的 `box`，不需要额外节点类型。

## 3. 用布局名称直接表达意图

普通内容用 `box`；直接的一维组合用 `row` 或 `column`；需要分配剩余空间或换行时
用 `flex`；需要二维轨道或显式放置时用 `grid`。

### Row 与 column

`row` 和 `column` 接受 `:item-gap` 与 `:cross-align`。它们的子节点仍然只是 Text
或 Box。

```elisp
(ebox-build
 '(row :item-gap 2 :cross-align center
       (box :width 12 "Left")
       (box :width 12 "Right")))
```

### Flex

Flex 容器 property 属于 `flex`。participation property 直接属于子 `box`，因为它
描述的是父子关系。

```elisp
(ebox-build
 '(flex :width (480)
        :flex-flow (row wrap)
        :gap (1 (12))
        (box :flex (1 1 auto) "Primary")
        (box :flex-grow 2 "Secondary")))
```

### Grid

Grid 放置从 1 开始。轨道可以是固定值、`auto`、分数、`minmax` 或 `repeat`。
placement property 同样直接属于子 `box`。

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

## 4. 使用几何与绘制 property

普通横向数字表示字符列，`(240)` 这样的单元素 list 表示像素宽度；纵向数字表示
行数。Text 只接受字体、前景/背景和文本装饰 property；padding、margin、border、
尺寸、`:outer`、overflow、可见性和换行策略只属于 Box。Box 上的字体与颜色可以
作为其 Text 子树的继承来源，但不会让 Text 获得 Box 几何。

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

用 `:outer inline` 或 `:outer block` 表达 Box 如何参与父布局。子布局算法仍由 form
名称决定。

## 5. 渲染与发布

`ebox-render` 返回带属性文本，不修改 live buffer；`ebox-render-to-buffer` 挂载
retained TP surface 并返回 buffer。

```elisp
(ebox-render ebox-guide-root)
(ebox-render-to-buffer "*Ebox Guide*" ebox-guide-root)
```

重新构建 root 后，用 `ebox-commit` 原子更新：

```elisp
(ebox-commit
 "*Ebox Guide*"
 (ebox-build
  '(column :padding (1 2)
           (text "Updated notes")
           (box :key body "The new root is caller-owned."))))
```

验证、渲染或发布失败时，旧 buffer 与 runtime 状态保持不变。
`ebox-buffer-update-report` 返回最近一次成功更新报告的防御性副本。

## 6. 查询和更新 mounted surface

`:id`、`:class` 与 `:key` 是 author metadata。Selector 使用 ECSS 语义。直接更新
前，把 `:id` 解析为不透明、surface-scoped 的 handle：

```elisp
(let ((handle (ebox-region-resolve "*Ebox Guide*" "status")))
  (ebox-region-update handle :color "#166534"))
```

`ebox-selector-query-buffer` 按文档顺序返回 mounted buffer 中的匹配；
`ebox-selector-update-buffer` 对所有可编辑匹配应用一次样式更新。数字 region id
只是诊断用渲染 metadata，不是稳定更新 handle。

## 7. Resize 与滚动

有限高度加 `:overflow scroll` 会创建 scroll window。Ebox buffer mode 安装键盘和
滚轮命令：先交给最内层 scroll owner，无法继续消费时才回退到普通 Emacs 滚动。

```elisp
(ebox-build
 '(box :id log :width (420) :height 8 :overflow scroll
       "line 1\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7\nline 8\nline 9"))
```

可见 mounted buffer 会跟随其 display window。集成层也可以显式应用 viewport：

```elisp
(ebox-rerender-buffer-with-context
 (get-buffer "*Ebox Guide*") 800 30)
```

## 8. 独立 `.ebox` 文件

`.ebox` 文件包含一个不加 quote 的结构 form：

```elisp
(column :padding '(1 2)
        (text :color "#263244" "Title")
        (box :width '(240) "Body"))
```

同级 `ebox-playground` 会先求值 property 表达式，再调用 `ebox-build`。因此 `.ebox`
文件中的 list 与 symbol 常量要加 quote，如上所示。直接调用 `ebox-build` 时，则像
前面的例子一样传入 inert data。

## 9. Typed 集成 API

已经完成 author normalization 的框架可以绕过 list DSL：用 `ebox-text-create`
构造 TextNode，用对应 layout constructor 构造 typed LayoutConfig，再用
`ebox-box-create` 构造 BoxNode。

```elisp
(ebox-box-create
 :layout (ebox-row-layout-create :item-gap 1 :cross-align 'center)
 :children (list (ebox-text-create :value "Left")
                 (ebox-text-create :value "Right")))
```

这里的 `:layout` 和 `:children` 是 evaluated typed constructor 的字段，不是 author
property，也没有扩展七入口语法。

## 10. 可选 native reflow 与验证

Rust 模块是可选加速器，Ebox 加载时不会构建它：

```elisp
(ebox-native-status)
(ebox-native-build)
```

在仓库根目录运行：

```sh
make docs-contract-tests EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make dsl-tests EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make check EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
```
