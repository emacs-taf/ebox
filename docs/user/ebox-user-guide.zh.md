# Ebox 用户指南

Ebox 是底层的 box、布局和 buffer 渲染包。当应用需要精确几何时可以直接使用，也可以作为 ETAF 下方的渲染基座。本指南不引入 Component、响应式状态、behavior 或应用数据。

## 1. 加载包

```elisp
(add-to-list 'load-path "/path/to/github/ebox")
(require 'ebox)
```

加载只定义公共包和纯布局模块，不会创建 buffer、安装 mode、构建 Rust 或修改当前编辑 buffer。

## 2. 构造节点树

`ebox-create` 构造节点；容器辅助函数接收子节点并返回新的节点：

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

公共形状是数据，而不是已渲染文本。节点可以有 `:content`、`:ebox-content-node`，或由容器接收的子节点。兄弟节点具有稳定业务 identity 时使用 `:key`；应用需要在渲染后查询公开位置时使用 `:host-ref`。

## 3. 尺寸与表面属性

普通横向数字表示字符列；单元素 list 表示像素宽度；纵向数字表示行数。padding 和 margin 接受标量或 CSS 风格的 1–4 值。border 由宽度、样式和颜色组成：

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

带色背景的 surface 要显式设置前景色与背景色。`:face` 可以是 face symbol 或 face plist；当 surface 本身承载语义颜色时，优先使用 `:color` 与 `:bgcolor`。

## 4. row、column、flex 与 Grid

简单的一维组合使用 row 和 column；需要分配剩余空间时使用 flex；需要二维轨道或稳定放置时使用 Grid：

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

Grid 轨道支持固定值、分数、`auto`、`minmax` 和重复轨道。显式放置从 1 开始；span 使用正整数；省略的位置由隐式轨道补齐。多行子项会先逐行对齐到自己的 Grid 矩形，再绘制外层边框；即使子项各行的自然宽度不同，带边框的 Grid 右边缘也会保持连续。

## 5. 渲染文本或 buffer

`ebox-render` 相对于 buffer 是纯函数，通过临时 TP surface 返回带属性文本；`ebox-render-to-buffer` 会复制声明式 source，并挂载 retained TP surface 完成首次发布：

```elisp
(let ((node (ebox-column
             (ebox-create :id "status" :content "Ready" :width '(240))
             (ebox-create :content "Rendered by Ebox"))))
  (ebox-render node)
  (ebox-render-to-buffer "*Ebox Demo*" node))
```

返回文本带有 Ebox 所需的 display、face、region 和 identity 属性，不要手动修改这些属性。source 节点仍由调用者拥有，可以挂载到多个 buffer；每个 buffer 都获得独立的 runtime identity 与状态。

## 6. 更新已有 buffer

构造新的根树并提交到已有 buffer：

```elisp
(ebox-commit
 "*Ebox Demo*"
 (ebox-column
  (ebox-create :content "Updated" :key 'title :width '(240))))
```

Ebox 会比较稳定 key 和 region identity，准备 dirty/owner 语义计划，再由 TP 原子发布新的 retained surface 与 Ebox runtime 状态。报告同时保留 Ebox 计划与 TP 执行摘要：

```elisp
(ebox-buffer-update-report "*Ebox Demo*")
```

无法证明安全时会提升到 owner 或 root rerender；render、发布、runtime 状态交换或发布回调失败时，之前的 buffer、TP surface、Ebox runtime 状态和最近一次成功报告都必须保持不变。

## 7. Selector 与 handle

Selector 查询已渲染的树并返回公共匹配记录，但不拥有应用状态。给可编辑 box 设置逻辑 `:id`，在某个 live buffer 中解析它，再把不透明、surface-scoped 的 handle 交给 `ebox-region-update`：

```elisp
(let ((handle (ebox-region-resolve "*Ebox Demo*" "status")))
  (ebox-region-update handle :content "Ready" :color "#166534"))
```

两个 buffer 中相同的逻辑 id 会解析为两个不同 handle，因此更新一个 surface 不会误改另一个。retained object 被删除或 buffer 被 kill 后，原 handle 会变 stale。`ebox-region-update` 只接受 live handle；数字 region id 只是内部渲染元数据，不是更新 API。

`ebox-selector-parse` 会把 CSS-like 字符串直接编译成 ECSS 的结构化 selector AST。查询支持 type、`#id`、`.class`、`[key=value]`、空格 descendant、子节点 `>`、相邻兄弟 `+` 和一般兄弟 `~`。Ebox 只负责把逻辑子节点关系与索引候选映射成 ECSS subject，最终匹配统一由 `ecss-selector-match-p` 决定，因此 query 与 cascade 不会产生两套语义。属性 selector 只看内建的 `:id`/`:key`，以及通过 `:selector-attributes` 显式传入的元数据，例如 `:selector-attributes '((role . button))`；可见 content、布局属性、Ebox runtime 容器与内部 `:ebox-*` 槽位绝不会被隐式转换成 selector 属性。

```elisp
(ebox-selector-query-buffer "*Ebox Demo*" ".toolbar > box.action")
(ebox-selector-query-buffer "*Ebox Demo*" "#first + .later")
(ebox-selector-query-buffer "*Ebox Demo*" "#first ~ [role=button]")
```

## 8. 独立 `.ebox` 文件

`ebox-build` 读取一个面向数据的 Ebox form：

```elisp
(ebox-build
 '(grid :width (640)
        :grid-template-columns ((200) 1fr 1fr)
        :gap (1 (12))
        (box :content "A")
        (box :content "B")
        (box :content "C")))
```

在 `.ebox` fixture 中，结构表单保持不加 quote。属性位置的 list 和 symbol 常量要加 quote，例如 `:gap '(1 (12))`、`:justify-content 'center`；可执行的 Elisp 属性表达式则保持不加 quote。`ebox-playground` 会在把 form 交给 `ebox-build` 之前求值这些属性表达式，这与 `etaf-view` 的属性值约定一致。

可执行的 `.ebox` 参考文件由同级 [`ebox-playground`](../../ebox-playground/README.md) 包维护。它的 `examples/` 目录包含迁移后的 Basic、Comprehensive、Flex、Responsive 以及完整 Grid 参考文件；这些文件只演示低层布局，不依赖 ETAF。

## 9. 可选 native reflow

Rust 模块用于加速符合条件的 reflow，但不是正确性的前提。正常加载 Ebox；需要本地模块时运行 `make native-build`，若模块不在默认位置则配置 `ebox-native-reflow-module-path`。Ebox 保留完全等价的 Elisp 路径，并且加载时不会自动构建 native。

## 10. 公共边界

使用公共的 `ebox-*` 函数与构造器。以 `ebox--` 开头的名称是私有实现细节，可能随时变化。ETAF 是同级包，负责 Component、View 树、状态、behavior、Context、data 和应用生命周期；Ebox 应保持对几何与发布的专注。

## 11. 验证

在仓库根目录运行：

```sh
make load EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make compile EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make check EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
```

局部修改可先运行 `make grid-tests`、`make dsl-tests` 或 `make visual-check-tests`；修改 native 模块后运行 `make native-rust-tests`。
