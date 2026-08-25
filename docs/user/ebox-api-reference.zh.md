# Ebox 公共 API 参考

[English](ebox-api-reference.en.md)

本文是独立 Ebox 包面向用户的完整清单，覆盖节点模型、property、布局
辅助函数、渲染/发布、selector、滚动、测量、DSL 和可选 native 模块。
`ebox--*` 名称与没有在本文说明的模块辅助函数属于实现细节。加载
`(require 'ebox)` 后，也可以通过 `ebox-public-api` 查看门面入口清单。

Ebox 负责 box node、样式归一化、测量、布局、渲染、语义更新规划、selector
适配、Grid 和可选 Rust reflow 加速器。TP 负责 live buffer 发布、物理 diff、
revision 和 rollback；ECSS 负责 selector 解析、匹配与 cascade。Ebox 不提供
Component、应用状态、UI control 或应用生命周期。

## 1. 安装与加载

Ebox 需要 Emacs 29.1 或更新版本，以及 ECSS 和 TP。使用同级源码 checkout：

```elisp
(add-to-list 'load-path "/path/to/github/ecss")
(add-to-list 'load-path "/path/to/github/tp")
(add-to-list 'load-path "/path/to/github/ebox")
(require 'ebox)
```

加载 Ebox 会加载 Elisp 布局/runtime 模块，但不会创建 buffer、在当前 buffer
启用 mode、构建 Rust 或修改当前编辑 buffer。可选 native 模块只在其工作流
或合资格的 native 路径需要时加载。

## 2. 常规生命周期

公共工作流如下：

```elisp
(let ((root
       (ebox-column
        (ebox-create :id "status" :content "Ready" :width '(240))
        (ebox-create :content "调用者拥有的 source tree"))))
  ;; 纯 materialization；返回多行带属性字符串。
  (ebox-render root)

  ;; retained TP surface；返回 live buffer。
  (ebox-render-to-buffer "*Ebox Demo*" root)

  ;; 后续构造新的声明式根树并原子发布。
  (ebox-commit
   "*Ebox Demo*"
   (ebox-column
    (ebox-create :id "status" :content "Updated" :width '(240))
    (ebox-create :content "未修改调用者的 source tree。"))))
```

`ebox-render` 不产生 live buffer 副作用。没有 active stylesheet 和 inline
继承样式依赖的静态树可以使用隔离的 pure materialization；依赖 stylesheet
的 pure render 使用临时 TP materialization。两者都遵守同一个公共字符串
契约。两个 buffer 入口都使用 retained TP surface。Ebox 会在分配 runtime
identity 前复制声明式输入，因此同一 source tree 可以挂载到多个 buffer。

`ebox-display-buffer` 是同时需要展示 buffer 时的便捷包装；它会先删除其他
window，再切换到渲染后的 buffer。如果窗口选择由调用方负责，应使用
`ebox-render-to-buffer`。

## 3. 节点与组合

### Box 与简单布局构造器

```elisp
(ebox-create &rest properties)
(ebox-concat node-1 node-2)       ; 两个节点横向排列
(ebox-stack node-1 node-2)        ; 两个节点纵向排列
(ebox-row &rest nodes)             ; 多个节点横向排列；单个 Range 仍保留 row parent
(ebox-column &rest nodes)          ; 多个节点纵向排列；单个 Range 仍保留 column parent
(ebox-spacer &rest properties)    ; 空白 box
```

`ebox-create` 返回声明式 box node。`:content` 是字符串内容；容器子节点通常
交给 `ebox-row`、`ebox-column`、`ebox-flex` 或 `ebox-grid`。`ebox-concat` 和
`ebox-stack` 接受两个节点；超过两个子节点时使用 row/column。nil 子节点会
被忽略；空 row/column 会变成 spacer。

`:key` 是兄弟节点范围内的稳定业务 identity；`:id` 是 logical selector/update
标识；`:host-ref` 是应用拥有的不透明锚点，用于 host-reference 查询和逻辑
candidate replacement。一个 source tree 内的非 nil host-ref 必须唯一。

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

容器 property 是 `:flex-direction`、`:flex-wrap`、`:flex-flow`、
`:justify-content`、`:align-items`、`:align-content`、`:gap`、`:row-gap` 和
`:column-gap`，另加 `:width`、`:height`、padding、border、paint 等普通 box
property。默认方向是 row、nowrap，主轴是 flex-start，交叉轴是 stretch。

item property 是 `:order`、`:flex`、`:flex-grow`、`:flex-shrink`、`:flex-basis`
和 `:align-self`。它们可以直接放在 child box 上，也可以通过
`ebox-flex-item` 附加。传给 `ebox-flex-item` 的非 item property 会在 child
外包一层普通 box。

Flex preferred/min/max size 支持 Ebox 子集：`auto`、`min-content`、
`max-content`、`fit-content`、`stretch`、`contain`；max-size 还支持
`none`。`fit-content` 可以带数字或 viewport 相对限制。这些是 Ebox 布局值，
不表示完整浏览器 CSS 兼容性。

### Grid

```elisp
(ebox-grid
 :width '(640)
 :grid-template-columns '((200) 1fr 1fr)
 :grid-template-rows '(1 1)
 :gap '(1 (12))
 (ebox-grid-item
  (ebox-create :content "Header")
  :grid-column '(1 :span 3))
 (ebox-create :content "Main" :grid-column 1 :grid-row 2)
 (ebox-create :content "Aside" :grid-column 2 :grid-row 2))
```

`ebox-grid-fr` 构造分数轨道：`(ebox-grid-fr 2)` 返回 `(fr 2)`。Grid 轨道支持
固定尺寸、`auto`、`(fr FACTOR)`、`1fr` 这样的 symbol、`minmax` 和 `repeat`。
没有显式给出的行列使用隐式轨道；`:grid-auto-columns`、`:grid-auto-rows`
和 `:grid-auto-flow`（`row` 或 `column`）控制隐式放置。

Grid placement 从 1 开始。`:grid-column` 和 `:grid-row` 接受正整数起点、
`(start :span 正整数)`，或 `start` 小于 `end` 的 `(start end)`。
`:grid-column-span` 与 `:grid-row-span` 接受正整数。`ebox-grid-item` 是便捷
包装器；placement property 也可以直接放在 child node 上。

## 4. 单位、box property 与文本属性

### 尺寸单位

| 值 | 含义 |
| --- | --- |
| 普通横向数字，例如 `12` | 字符列数，按当前 display 的空格宽度转换。 |
| 单元素横向 list，例如 `'(240)` | 绝对像素。 |
| 纵向数字，例如 `3` | 行数。 |
| `(viewport)` 或 `viewport` | 当前 viewport 的像素宽度。 |
| `(viewport-height)` 或 `viewport-height` | 当前 viewport 的行高。 |
| `auto`、`min-content`、`max-content`、`fit-content`、`stretch`、`contain` | 在对应 property 与 formatting context 支持时使用 intrinsic/preferred width。 |

`:box-sizing` 默认是 `border-box`，也支持 `content-box`。宽度 property 是
`:width`、`:min-width`、`:max-width`；高度 property 是 `:height`、
`:min-height`、`:max-height`。几何负值会被拒绝。依赖 viewport 的节点要在
viewport context 中渲染，或通过 `ebox-rerender-buffer-with-context` 重排。

### Box、paint 与文本 property

以下名称可用于 `ebox-create`。Stylesheet 规则使用其中的 style/geometry
property；`ebox-region-update` 接受其目标支持的可变 content/style/scroll
子集。Direct update 不会添加 child 或修改 selector metadata；结构变化使用
`ebox-commit` 或 logical candidate。结构 metadata、`:content` 和
`:surface-properties` 是节点/render 输入，不是 stylesheet declaration。表中
同时列出 canonical 名称与兼容别名。

| 范围 | Property |
| --- | --- |
| Content/geometry | `:content`、`:box-sizing`、`:width`、`:min-width`、`:max-width`、`:height`、`:min-height`、`:max-height` |
| Padding | `:padding`、`:padding-inline`、`:padding-block`；longhand `:padding-block-start`、`:padding-inline-end`、`:padding-block-end`、`:padding-inline-start`；别名 `:padding-top`、`:padding-right`、`:padding-bottom`、`:padding-left`，以及 `:padding-right-pixel`、`:padding-left-pixel`、`:padding-top-height`、`:padding-bottom-height` |
| Margin | `:margin`、`:margin-inline`、`:margin-block`；longhand `:margin-block-start`、`:margin-inline-end`、`:margin-block-end`、`:margin-inline-start`；别名 `:margin-top`、`:margin-right`、`:margin-bottom`、`:margin-left`，以及 `:margin-right-pixel`、`:margin-left-pixel`、`:margin-top-height`、`:margin-bottom-height` |
| Border | `:border`、`:border-top`、`:border-right`、`:border-bottom`、`:border-left`、`:border-width`、`:border-style`、`:border-color`；side longhand `:border-*-width`、`:border-*-style`、`:border-*-color`；兼容别名 `:border-top-p`、`:border-bottom-p`、`:border-left-pixel`、`:border-right-pixel` |
| Paint | `:color`、`:background-color`、别名 `:bgcolor` |
| Typography | `:font`、`:font-family`、`:font-height` 和别名 `:font-size`、`:font-weight`、`:font-slant` |
| Text/layout | `:text-align`（`left`、`center`、`right`）、`:vertical-align`（`top`、`center`/`middle`、`bottom`）、`:overflow`（`scroll`、`hidden`、`visible`）、`:wrap-mode`（`word`、`char`、`kp` 或 nil）、`:visibility`（`visible` 或 `hidden`） |
| Structural style | `:display` 会在 node/layout context 中计算；有效的 display tuple 通常由布局构造器选择。 |
| Flex container/item | `:flex-direction`、`:flex-wrap`、`:flex-flow`、`:justify-content`、`:align-items`、`:align-content`、`:gap`、`:row-gap`、`:column-gap`（别名 `:grid-row-gap`、`:grid-column-gap`）；item 名称 `:order`、`:flex`、`:flex-grow`、`:flex-shrink`、`:flex-basis`、`:align-self` |
| Grid container/item | `:grid-template-columns`、`:grid-template-rows`、`:grid-auto-columns`、`:grid-auto-rows`、`:grid-auto-flow`、`:justify-items`；item placement `:grid-column`、`:grid-row`、`:grid-column-span`、`:grid-row-span` |
| 额外文本属性 | `:surface-properties` 接受偶数长度的 Emacs text-property plist，应用到不含换行的渲染字符；内层非 nil 属性优先。 |

Box 字体入口是 `:font`，不是 `:face`。`:font` 接受 Emacs face symbol、face
名称字符串或 face plist；typography longhand 会合并到该 face。`:visibility
'hidden` 会隐藏 ink，但保留布局 footprint 与 metadata。`:overflow 'visible`
会发布超出高度的可见行；`hidden` 会裁剪；`scroll` 暴露有限窗口，并在内容
高于 box 时启用 Ebox 滚动。

Padding 与 margin 使用 CSS 的 1–4 值展开。横向值使用上述横向单位，顶部和
底部使用行单位。左右 border 是像素几何；上下 border 通过 Emacs overline/
underline face 实现，因此宽度是存在性标志而非任意像素厚度。

### Node metadata 与 selector 输入

这些输入用于标识节点，不会直接改变几何：

| 输入 | 含义 |
| --- | --- |
| `:id` | logical selector/update id。symbol 和其他标量会归一化为字符串；直接 update 解析时应保持 id 唯一。 |
| `:key` | reconciliation 使用的稳定兄弟 identity，同时作为内建 selector `:key` attribute 暴露。 |
| `:class` | 一个 class token 或 class token 列表，用于 selector matching。 |
| `:selector-state` | 一个 state token 或 state token 列表，用于匹配 `:hover`、`:active` 等 state pseudo。 |
| `:selector-attributes` | 显式 attribute alist，例如 `((role . button))`；content、布局值和 runtime 字段不会自动推断。 |
| `:host-ref` | 应用拥有的唯一不透明 anchor，用于 `ebox-host-ref-position`、`ebox-host-ref-bounds` 和 host-ref candidate replacement。 |
| `:scroll-offset` | scroll region 的初始/受控行偏移。交互优先使用滚动命令；update 必须使用 live region handle。 |

`:id`、`:key` 和 `:host-ref` 不是 stylesheet declaration。`:class`、
`:selector-state` 和 `:selector-attributes` 是 selector metadata，不是通用
应用状态。

## 5. Stylesheet 与 cascade

多数节点只需 inline property。需要 selector 驱动样式时使用隔离的 Ebox
stylesheet：

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

`ebox-style-add-rule` 接受 selector string 或 AST、Ebox declaration plist，
以及 ECSS cascade 关键字 `:origin`、`:layer`、`:scope`。
`ebox-style-reset-rules` 清空 stylesheet。规则属于已加载的全局 Ebox style
registry；改变规则不会自动发布已有 mounted buffer，因此规则变化后要对
目标 buffer rerender 或 commit。`ebox-style-cascade-active-p` 可检查当前
是否存在规则。

基于 ECSS 的 style domain 包含 color 与 typography inheritance、computed
value、cascade layer、custom-property declaration，以及 paint/geometry/
structure dirty 分类。Ebox 只解释本文列出的 property；百分比、绝对定位、
z-index、阴影、border radius、浏览器级 bidi 和完整浏览器 typography 不属于
本包。

名称以 `--` 开头的 custom property 可以由 ECSS style domain 携带，但除非宿主
集成把它解析为本文支持的 Ebox property，否则不会影响 Ebox 输出。

## 6. 渲染、identity 与更新

### Region id 与 logical handle

`ebox-region-ids` 会从未渲染树或已渲染字符串按文档顺序返回 region id。需要
低层 source 映射时，在第一次 mount 前捕获：

```elisp
(let* ((root (ebox-column
              (ebox-create :id "title" :content "Title")
              (ebox-create :id "body" :content "Body")))
       (ids (ebox-region-ids root)))
  (ebox-render-to-buffer "*Ebox Demo*" root)
  ids)
```

应用更新优先使用 logical id 与不透明 handle：

```elisp
(let ((handle (ebox-region-resolve "*Ebox Demo*" "body")))
  (ebox-region-update handle :content "Changed" :color "#166534"))
```

`ebox-region-resolve` 在 buffer 不存在、logical id 缺失或 id 有歧义时发出
错误。Handle 绑定一个 retained TP surface；对象移除或 buffer kill 后会 stale。
数字 region id 是渲染 metadata，不能作为 `ebox-region-update` 的参数。

### Direct 与 selector 更新

`ebox-region-update` 接受可变 content/style/scroll property 关键字；除非处于
显式 batch，否则返回已提交的 update report。它先构造隔离 candidate，规划
最小安全 Ebox owner，再请求 TP 发布一次。它不会添加 child，也不会修改
`:id`、`:class`、`:key` 或其他 selector metadata。非法 declaration、render
失败、publication 失败或 callback 失败都会保留原 buffer/runtime/report。

`ebox-selector-update-buffer` 把 property 应用到 buffer 中所有可编辑的
selector match，返回：

```elisp
(:selector SELECTOR
 :matched INTEGER
 :updated INTEGER
 :skipped ((:node-id ID :reason no-region) ...)
 :reports (REPORT ...))
```

显式多更新 batch 只有在应用确实拥有该边界时才使用较低层 incremental batch
函数；一般场景使用 `ebox-selector-update-buffer`。

### Logical candidate

Candidate 是基于当前已发布 runtime 的一次性 transaction。多个稳定 subtree
需要一起替换并只提交一次时使用：

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

如果框架的 semantic owner 与 backend anchor 分离，可在选择更宽的发布 owner
之前使用只读函数 `ebox-range-ref-present-p`。当 semantic Range 嵌套在 material
anchor 内、当前 Ebox publication 没有独立地址时，它返回 nil。

`ebox-candidate-replace-host-ref` 使用应用拥有的 `:host-ref`，不需要 runtime
node id。两个 replacement 函数都接受可选的 `old-semantic-key` 与
`new-semantic-key`，用于有限的 detached identity 复用。Candidate 在 commit
时 sealed，不能复用；若捕获的 runtime 或 buffer tick 发生变化，它也会 stale。

`ebox-candidate-patch-host-paint` 比较前后 declarative Host 输出；只有全部变化
都属于 node-local paint 时才记录属性 patch。它保留子树与 runtime identity，
并在一次受影响子树遍历中更新继承前景；需要普通子树替换时返回 nil。

`ebox-candidate-replace-root` 使用私有且绑定 candidate 的 root 地址。它只接受
一个声明式节点、清除调用方 runtime identity，并采用 last-wins 语义。最终 root
replacement 会吸收其前后记录的 descendant node/host-ref operation，不添加
wrapper，也不暴露公共 reference。

`ebox-child-range` 在 material child list 中创建非节点 segment descriptor。
其非 nil ref 在 root 内全局唯一，items 直接参与 parent 的 key、selector、style
与 layout scope。`ebox-candidate-replace-range-ref` 接受 proper declarative
node list，只替换该 base payload；empty payload 仍可寻址。

### Host-reference 位置

```elisp
(ebox-host-ref-position "*Ebox Demo*" 'toolbar)
;; => 第一个 live 字符位置，或 nil
(ebox-host-ref-bounds "*Ebox Demo*" 'toolbar)
;; => (START . END)，不含 margin，或 nil
```

位置与 bounds 属于当前 publication generation；每次更新后都要重新获取。
Host-reference table 与 logical selector id 是两套不同的机制。

### Report 与 viewport reflow

如果上层框架在调用 Ebox 前需要先分配新的 view tree，可以把整个输入 callback
纳入 Ebox 的 render GC budget：

```elisp
(ebox-call-with-render-burst
 (lambda ()
   (let ((next-root (build-framework-view)))
     (ebox-commit buffer next-root))))
```

优先使用能保证异常清理的 `ebox-call-with-render-burst`。如果操作无法表达为
一次函数调用，`ebox-render-burst-begin` 会返回交给
`ebox-render-burst-end` 的不透明 token；调用方必须使用 `unwind-protect`，并按
后进先出顺序结束嵌套 token。交互 burst 与 Ebox commit 共用 deferred state，
在最外层 end 后 0.2 秒恢复调用方 GC 设置；新 burst 会取消并取代待执行的
restore。Batch burst 立即精确恢复 threshold 与 percentage，且不会在边界主动
执行 GC。这些函数只定义 allocation/GC ownership，不会 publish、commit，也
不会暴露 Ebox runtime state。

`ebox-buffer-update-report` 返回 mounted buffer 上一次成功报告的 defensive
copy；目标缺失或不是 Ebox runtime 时会报错。首次 mount 在第一次 update
前没有 update report。报告包含 Ebox strategy、publication scope、TP surface
revision、物理 operation 和 reconciliation 事实。

完整签名是 `(ebox-commit BUFFER NEXT-ROOT &optional FRAMEWORK-PUBLISH
FRAMEWORK-ROLLBACK)`。buffer、TP surface 与 Ebox runtime 一致后，publish 接收
report；若后续 phase 失败，rollback 最多一次接收同一个 report，其 error/quit
会被隔离。`:framework-participant-state`、
`:framework-participant-diagnostics` 与 `:scroll-finalization-diagnostics`
是只读 outcome 字段。

当 root 依赖新的 viewport 时使用 `ebox-rerender-buffer-with-context`：

```elisp
(ebox-rerender-buffer-with-context
 (get-buffer "*Ebox Demo*")
 800                         ; viewport 像素宽度
 30)                         ; 可选 viewport 行高
```

该调用保留 node/region identity，并通过 viewport dirty planning 处理变化。
`(viewport)` 与 `(viewport-height)` 从该 context 解析。纯渲染时也可以在
render 外部动态绑定 `ebox-viewport-width`（像素）与 `ebox-viewport-height`
（行数）。不要原地修改已经发布的 node tree。

## 7. Selector

`ebox-selector-parse` 委托 ECSS 并返回结构化 AST；
`ebox-selector-match-node-p` 匹配单个声明式节点；`ebox-selector-query-all`
从未 mounted tree 返回按文档顺序的 match；`ebox-selector-query-buffer` 查询
live buffer 的 retained runtime，并给每条 match 添加 `:buffer`，可编辑节点
还会添加 `:region-handle`。

ECSS 支持的 selector 语法包括：

- selector list、compound type/id/class selector；
- attribute presence 与 `=`、`~=`、`|=`、`^=`、`$=`、`*=`，以及 `i`/`s` flag；
- 通过 `:selector-state` 提供的 `:hover`、`:active` 等 state pseudo；
- `:is(...)`、`:where(...)`、`:not(...)` 与 relational `:has(...)`；
- 空格 descendant、子节点 `>`、相邻兄弟 `+`、一般兄弟 `~` combinator。

Ebox 的 node type 会映射为 selector type：`box`、`row`、`column`、`flex`、
`grid`、`item`。`:id` 与 `:key` 是内建 attribute；额外 attribute 必须显式
传入，例如 `:selector-attributes '((role . button))`。可见 content、布局
值和内部 runtime slot 不会被推断成 selector attribute。

```elisp
(ebox-selector-query-buffer "*Ebox Demo*" ".toolbar > box.action")
(ebox-selector-query-buffer "*Ebox Demo*" "div:has(> .warning)")
(ebox-selector-update-buffer "*Ebox Demo*" "[role=button]"
                             :color "#2563EB")
```

兼容别名 `ebox-select-all` 与 `ebox-update-selector` 分别指向
`ebox-selector-query-buffer` 和 `ebox-selector-update-buffer`。

## 8. 滚动与 viewport state

设置 `:overflow 'scroll`（默认值）和有限的 `:height` 创建滚动窗口：

```elisp
(ebox-create
 :id "log"
 :width '(420)
 :height 8
 :overflow 'scroll
 :content (mapconcat #'identity lines "\n"))
```

`ebox-scroll-down`、`ebox-scroll-up`、`ebox-scroll-page-down` 和
`ebox-scroll-page-up` 操作 point 所在的最内层滚动区域；找不到可消费该命令
的 Ebox region 时委托普通 Emacs scrolling。`ebox-wheel-scroll-down` 与
`ebox-wheel-scroll-up` 接受 mouse event；当 `ebox-wheel-smooth-scroll` 非 nil
时会分步动画，否则委托 `mwheel-scroll`。`ebox-buffer-mode` 在本地安装
`ebox-scroll-map`；`ebox-render-to-buffer` 会在返回的 buffer 上启用该 mode。

`ebox-scroll-state` 接受数字 region id，返回用于 source-model 映射的只读
state plist。可用事实包括 `:scroll-offset`、content height/lines 与缓存的
visible lines。把 plist 当作 diagnostic/read-only 数据；用
`ebox-region-update` 的 `:scroll-offset` 或滚动命令改变位置。

Scroll content 会惰性预取，并按有界 slice 渲染。安全的 retained update 会
保留缓存 scroll state；发布失败时它与其他 runtime 状态一起 rollback。

## 9. 测量与缓存配置

`ebox-string-pixel-width` 返回字符串第一行的 display 像素宽度，同时考虑
text scale 和固定 `display` space；它也是布局使用的公共测量原语。
`ebox-display-signature` 返回测量缓存使用的当前 display 输入。
如果在正常 display-signature 信号之外修改了字体或 named face，可调用
`ebox-clear-cache`。

主要 customization 变量如下：

| 分组 | 变量与默认值 |
| --- | --- |
| Render cache | `ebox-render-cache-max-entries` 2048；`ebox-render-cache-max-bytes` 32 MiB；`ebox-render-root-cache-max-entries` 16；`ebox-render-root-cache-max-bytes` 8 MiB |
| 键盘/鼠标滚动 | `ebox-scroll-step` 1；`ebox-wheel-scroll-step` 1；`ebox-wheel-smooth-scroll` nil；`ebox-wheel-smooth-scroll-interval` 0.016；`ebox-wheel-smooth-scroll-lines-per-tick` 4；`ebox-wheel-smooth-scroll-target-ticks` 8。键盘以 point 为 anchor，滚轮以 event 位置为 anchor，剩余行沿嵌套 owner 向外冒泡。交互式、内容完整且无 chrome 的根 document owner 可在 idle 时一次 materialize，之后使用 Emacs 原生 window line start；普通更新/resize 只预热 retained index，不启动第二次 native publication；嵌套/lazy/chrome owner 继续走事务化 Ebox publication。 |
| Lazy scroll | `ebox-scroll-lazy-prefix-lookahead-lines` 8；`ebox-scroll-lazy-idle-prefetch-lines` 128；`ebox-scroll-lazy-idle-prefetch-slice-lines` 16；`ebox-scroll-lazy-idle-prefetch-delay` 0.15 |
| Runtime prewarm | `ebox-runtime-idle-prewarm` t；`ebox-runtime-idle-prewarm-delay` 0.1；`ebox-runtime-idle-prewarm-prefix-resume-delay` 2.0；`ebox-runtime-idle-prewarm-slice-size` 32；`ebox-native-buffer-scroll` t（仅 initial/visible-window handoff；严格 root-owner proof） |
| 预测 reflow | `ebox-runtime-idle-reflow-cache-prewarm` t；`ebox-runtime-idle-reflow-cache-prewarm-delay` 0.15 |
| Reflow GC | `ebox-reflow-cache-prewarm-gc-cons-threshold` `auto`；`ebox-reflow-cache-prewarm-gc-auto-frame-budget` 0.2；`ebox-reflow-cache-prewarm-gc-auto-min-threshold` 64 MiB；`ebox-reflow-cache-prewarm-gc-auto-max-threshold` 1 GiB；`ebox-reflow-cache-prewarm-gc-auto-initial-threshold` 512 MiB；`ebox-reflow-cache-prewarm-gc-auto-target-layouts` 24；`ebox-reflow-cache-prewarm-gc-cons-percentage` 0.1 |
| Visual verification | `ebox-visual-check-output-dir` 指向可选 screenshot/report 使用的临时目录。 |

Idle prewarm 不会发布 buffer text 或 runtime state。宿主应用不希望后台准备
工作时，可把对应的 boolean 设为 nil。

## 10. 独立 `.ebox` DSL

`ebox-build` 编译数据型 list form。支持的 tag 是 `box`/`ebox`、`row`、
`column`、`flex`、`item`、`grid`、`grid-item` 和 `spacer`：

```elisp
(ebox-build
 '(grid :width (640)
        :grid-template-columns ((200) 1fr 1fr)
        :gap (1 (12))
        (grid-item :grid-column (1 :span 3)
                   (box :content "Header"))
        (box :content "Main")))
```

`box` 下的直接字符串会合并为换行内容；child form 会变成默认纵向 child
layout。`row` 与 `column` 可以接收 box property 并包住 child layout；`flex`
接收容器 property；`item` 接收 flex item property；`grid-item` 必须有一个
child；`spacer` 不能有 child。

在 `.ebox` 文件中，结构 form 保持不加 quote；property 位置的 list 和 symbol
常量要作为 data quote，例如 `:gap '(1 (12))` 或 `:justify-content 'center`；
要执行的 Elisp property expression 保持不 quote，交给同级 playground runner
求值。

## 11. 可选 Rust reflow

Native 模块是加速器，不是正确性的依赖。Rust 边界只接收有界的数值布局工作；
Ebox 保留完全等价的 Elisp fallback，加载时绝不构建 Rust。

```elisp
(ebox-native-status)       ; 显示 toolchain、路径、ABI 与加载诊断
(ebox-native-build)        ; 异步构建/安装
(ebox-native-build t)      ; 先清理 Ebox 私有 Cargo cache
```

仓库命令是 `make native-build`。使用 `ebox-native-reflow-module-path` 配置
module 文件或目录。Session 限制为 `ebox-native-reflow-max-jobs` 512、
`ebox-native-reflow-max-results` 512、`ebox-native-reflow-max-result-bytes`
64 MiB。模块缺失或 ABI 不兼容时继续使用 Elisp；原因可由
`ebox-native-status` 查看。

`ebox-byte-compile` 会重新编译所有 active Ebox Elisp 源码，但不会构建 Rust。
成功后如需当前进程加载新的 `.elc`，请重启 Emacs。

## 12. 公共函数清单

下表覆盖门面清单中的公共函数；其下列出的 style-rule 函数是模块级公共
style API。

| 函数 | 用途 |
| --- | --- |
| `ebox-create`、`ebox-build` | 创建节点或编译 `.ebox` list DSL。 |
| `ebox-concat`、`ebox-stack`、`ebox-row`、`ebox-column`、`ebox-spacer` | 组合简单横向/纵向布局与空白 box。 |
| `ebox-flex`、`ebox-flex-item` | 构建 Flex 容器与 item metadata。 |
| `ebox-grid`、`ebox-grid-fr`、`ebox-grid-item` | 构建 Grid、分数轨道和 placement metadata。 |
| `ebox-render`、`ebox-render-to-buffer`、`ebox-display-buffer` | 纯 materialization、retained mount 与展示包装。 |
| `ebox-commit`、`ebox-buffer-update-report`、`ebox-rerender-buffer-with-context` | 原子根提交、报告查询和 viewport-context rerender。 |
| `ebox-region-ids`、`ebox-region-resolve`、`ebox-region-update` | Region 映射、logical handle 查询与直接更新。 |
| `ebox-child-range`、`ebox-range-ref-present-p`、`ebox-candidate-begin`、`ebox-candidate-replace`、`ebox-candidate-replace-range-ref`、`ebox-candidate-replace-root`、`ebox-candidate-replace-host-ref`、`ebox-candidate-patch-host-paint` | 持久 material child segment、backend anchor 查询、子树替换与 retained Host paint transaction。 |
| `ebox-host-ref-bounds`、`ebox-host-ref-position` | Host-reference 的 live bounds 与首位置。 |
| `ebox-selector-parse`、`ebox-selector-match-node-p`、`ebox-selector-query-all`、`ebox-selector-query-buffer`、`ebox-selector-update-buffer` | ECSS selector 编译、匹配、查询与批量更新。 |
| `ebox-select-all`、`ebox-update-selector` | 两个 buffer selector 函数的兼容别名。 |
| `ebox-buffer-mode`、`ebox-scroll-map`、`ebox-scroll-down`、`ebox-scroll-up`、`ebox-scroll-page-down`、`ebox-scroll-page-up`、`ebox-wheel-scroll-down`、`ebox-wheel-scroll-up`、`ebox-scroll-state` | 交互滚动、本地 keymap 与只读滚动状态。 |
| `ebox-string-pixel-width`、`ebox-display-signature`、`ebox-clear-cache` | Display-aware 测量与缓存管理。 |
| `ebox-native-build`、`ebox-native-status`、`ebox-byte-compile` | 可选 native 工作流与 Elisp byte compile。 |

加载 `(require 'ebox)` 后可用的 style inspection/rule 入口还包括
`ebox-style-add-rule`、`ebox-style-reset-rules`、
`ebox-style-cascade-active-p`、`ebox-style-compute`、
`ebox-style-expand-shorthands`、`ebox-style-compile-declarations`、
`ebox-style-merge-declarations`、`ebox-style-compute-subject`、
`ebox-style-property`、`ebox-style-canonical-name` 和
`ebox-style-dirty-kind`。前两个是应用通常使用的入口；其余函数供需要检查
或准备 ECSS-backed style data 的集成使用。

## 13. 验证与支持边界

在仓库根目录运行：

```sh
make load EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make compile EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make check EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make docs-contract-tests EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make native-rust-tests
```

聚焦目标包括 `make core-tests`、`make grid-tests`、`make surface-tests`、
`make selector-tests`、`make dsl-tests`、`make flex-tests` 和
`make visual-check-tests`。可运行的 `.ebox` 示例由同级 `ebox-playground`
包负责；ETAF 负责 Component、state、control 和应用行为。本包不要调用
私有 `ebox--*` 函数，也不要在 Ebox 任务中编辑历史 Ebox checkout。
