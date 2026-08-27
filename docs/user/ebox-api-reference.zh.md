# Ebox 公共 API 参考

[English](ebox-api-reference.en.md)

本文描述独立 Ebox 包当前的公共边界，并把普通 author 路径与框架集成使用的
evaluated typed API 分开。以 `ebox--` 开头的名称都是私有实现。

Ebox 需要 Emacs 29.1 或更高版本、ECSS 和 TP：

```elisp
(require 'ebox)
```

## 1. Author 语法

`ebox-build` 只接受以下 author 入口：

```text
STRING
(text PROPERTY VALUE ... STRING)
(box PROPERTY VALUE ... CHILD ...)
(row PROPERTY VALUE ... CHILD ...)
(column PROPERTY VALUE ... CHILD ...)
(flex PROPERTY VALUE ... CHILD ...)
(grid PROPERTY VALUE ... CHILD ...)
```

`STRING` 是 `(text STRING)` 的简写。Text form 必须且只能有一个字符串 payload。
每种 Box form 都接受零个或多个直接嵌套的 Text/Box 子节点。form 名称选择 Normal、
Row、Column、Flex 或 Grid 子布局；author 不通过 property 传入布局选择器。

```elisp
(ebox-build
 '(column :padding (1 2)
          (box :id "status" :color "#166534" "Ready")
          (row :item-gap 1
               (box "Left")
               (box "Right"))))
```

author source field 是 `:key`、`:class` 与 `:id`。`:outer` 可取 `inline` 或
`block`，控制 Box 如何参与父布局。

### 布局拥有的 property

| Form 或关系 | Property |
| --- | --- |
| `row`、`column` | `:item-gap`、`:cross-align` |
| `flex` | `:flex-direction`、`:flex-wrap`、`:flex-flow`、`:justify-content`、`:align-items`、`:align-content`、`:gap`、`:row-gap`、`:column-gap` |
| `flex` 的直接子 Box | `:order`、`:flex`、`:flex-grow`、`:flex-shrink`、`:flex-basis`、`:align-self` |
| `grid` | `:grid-template-columns`、`:grid-template-rows`、`:grid-auto-columns`、`:grid-auto-rows`、`:grid-auto-flow`、`:justify-items`、`:justify-content`、`:align-items`、`:align-content`、`:gap`、`:row-gap`、`:column-gap` |
| `grid` 的直接子 Box | `:order`、`:grid-column`、`:grid-row`、`:grid-column-span`、`:grid-row-span`、`:align-self` |

participation property 就是普通子 Box property，不会创建另一种公共节点或 wrapper。

### 当前常用 property

| 范围 | 当前输入 |
| --- | --- |
| 尺寸 | `:box-sizing`、`:width`、`:min-width`、`:max-width`、`:height`、`:min-height`、`:max-height` |
| 边缘 | `:padding`、`:margin`、`:border`、各 side shorthand 与 longhand |
| 绘制 | `:color`、`:background-color`、精确 alias `:bgcolor`、border color、`:visibility` |
| 文本布局 | `:text-align`、`:wrap-mode`（`word`、`char`、`kp`、`none`） |
| Overflow | `:overflow`（`visible`、`hidden`、`scroll`） |

普通横向数字表示字符列，单元素横向 list 表示像素；纵向数字表示行数。
`(viewport)` 与 `(viewport-height)` 使用当前 render context。property 验证属于
Ebox；context/value 组合无效时会直接报错。

## 2. Evaluated typed construction

已经拥有 author parsing 的框架可以直接构造 canonical node：

```elisp
(let ((layout (ebox-column-layout-create
               :item-gap 1 :cross-align 'stretch)))
  (ebox-box-create
   :layout layout
   :children (list (ebox-text-create :value "One")
                   (ebox-text-create :value "Two"))))
```

- `ebox-text-create` 要求 `:value STRING`；
- `ebox-normal-layout-create` 构造 Normal LayoutConfig；
- `ebox-row-layout-create` 与 `ebox-column-layout-create` 接受
  `:item-gap` 和 `:cross-align`；
- `ebox-flex-layout-create` 构造经过验证的 Flex LayoutConfig；
- `ebox-grid-layout-create` 构造经过验证的 Grid LayoutConfig；
- `ebox-box-create` 要求一个 typed `:layout` 值，并接受 typed node 的
  `:children` list。

最后两个 field 只属于 evaluated 集成契约，不是 author property，也不是另一套 DSL。

typed 模块还公开 `ebox-node-kind`、`ebox-text-node-p`、`ebox-box-node-p`、
`ebox-node-source-handle`、`ebox-text-node-value`、`ebox-box-node-layout`、
`ebox-box-node-children` 和 `ebox-box-node-range-anchors`。下面的 facade 清单重点列出
应用入口，因此不重复这些 inspection function。

## 3. 渲染与 retained 发布

| 函数 | 契约 |
| --- | --- |
| `ebox-render` | 返回带属性字符串，不发布 live buffer。 |
| `ebox-render-to-buffer` | 复制 built root，挂载 retained TP surface，启用 `ebox-buffer-mode` 并返回 buffer；可选 plist 只接受 `:observer FUNCTION`。 |
| `ebox-display-buffer` | 走 retained 路径渲染，删除其他 window 后切换到结果。 |
| `ebox-commit` | 原子发布重新构建的 root 或 one-shot logical candidate。 |
| `ebox-buffer-set-observer` | 给已经 mounted 的 buffer 设置或移除一个 function observer。 |
| `ebox-buffer-update-report` | 返回最近一次成功更新报告的防御性副本。 |
| `ebox-rerender-buffer-with-context` | 应用显式 viewport width 与可选 height，同时保留 identity。 |
| `ebox-viewport-window-width` | 返回 Ebox 对 window 使用的 display-safe 像素宽度。 |

`ebox-commit` 接受可选 framework publish/rollback callback。它们加入现有原子发布；
失败会恢复旧 buffer、surface、runtime state 与最近一次成功报告。

每个公共 Ebox publication 都拥有自己的 TP transaction。在已经 active 的外层 TP
transaction 中调用 mount、commit、viewport、region、selector、batch 或 TP-backed
scroll publication，会在 Ebox mutation 前被拒绝。

观察是可选只读边界，不拥有 transaction 权限。observer 签名是
`(OBSERVER BUFFER REPORT)`。一次 TP publication 被接受且 Ebox finalization 全部完成后，
observer 按顺序收到两份防御性 flat report：先 TP，后 Ebox。两者共享从 TP transaction
id 得到的 `:correlation-id`。Ebox stage 是 `mount`、`commit`、`viewport`、
`region`、`selector`、`batch` 和 `scroll`。嵌套公共调用复用最外层 operation，
因此多匹配 selector 或显式 batch 仍只发送一对 report。没有 TP surface publication
的 no-op 与 native-window scroll 不发送 report。observer error 在 accept 后被包含，
不能回滚渲染。

需要观察首次 mount 时，把 `:observer` 传给 `ebox-render-to-buffer`。mount report 只
瞬时发送；有无 observer 时 `ebox-buffer-update-report` 都仍为 nil。后续通过
`ebox-buffer-set-observer` 替换 observer，传 nil 时移除并从 TP surface 解绑 bridge。
observer 为 nil 时，Ebox 不创建 observation context，不取 timestamp/GC snapshot，
也不装饰 report。

`ebox-call-with-render-burst` 是框架 callback 的 exception-safe allocation/GC 边界。
`ebox-render-burst-begin` 与 `ebox-render-burst-end` 提供较底层的 token 形式，必须用
`unwind-protect` 配对。它们本身不发布内容。

## 4. Identity、直接更新与 logical candidate

| 函数 | 契约 |
| --- | --- |
| `ebox-region-ids` | 按文档顺序返回当前底层 region id。 |
| `ebox-region-resolve` | 把 mounted buffer 中一个逻辑 `:id` 解析为不透明、surface-scoped 的 handle。 |
| `ebox-region-update` | 通过一次 retained transaction 应用支持的可变样式或滚动 property。 |
| `ebox-child-range` | 从 typed node 构造透明、可寻址的 child Range descriptor。 |
| `ebox-candidate-begin` | 在 one-shot candidate 中捕获当前准确 mounted generation。 |
| `ebox-candidate-replace` | 替换一个 candidate node address。 |
| `ebox-candidate-replace-range-ref` | 替换一个透明 child Range payload。 |
| `ebox-candidate-replace-root` | 替换 candidate 的私有 root address。 |
| `ebox-candidate-replace-host-ref` | 替换一个 framework-owned opaque host reference。 |
| `ebox-candidate-patch-host-paint` | 记录经过证明的 paint-only host patch；需要 replacement 时返回 nil。 |
| `ebox-host-ref-bounds` | 返回 opaque host reference 当前不含 margin 的 bounds。 |
| `ebox-host-ref-position` | 返回其当前第一个位置。 |

handle 和位置只属于一个 live publication generation；对象被删除后要重新解析。
candidate 被 commit 封存后不能复用。

## 5. Selector

ECSS 是唯一 selector parser 与 matcher；Ebox 只提供 logical tree relation 和
mounted index。

| 函数 | 契约 |
| --- | --- |
| `ebox-selector-parse` | 把 CSS-like selector 编译为 ECSS AST。 |
| `ebox-selector-match-node-p` | 用 selector 或 AST 匹配一个 built node。 |
| `ebox-selector-query-all` | 按文档顺序查询 unmounted built tree。 |
| `ebox-selector-query-buffer` | 查询一个 mounted runtime。 |
| `ebox-selector-update-buffer` | 更新所有可编辑 mounted match 并返回结构化报告。 |
| `ebox-select-all` | `ebox-selector-query-buffer` 的 alias。 |
| `ebox-update-selector` | `ebox-selector-update-buffer` 的 alias。 |

## 6. 滚动

`ebox-buffer-mode` 安装 `ebox-scroll-map`。map 会把行、页和滚轮意图先交给最内层
semantic scroll owner，再回退到普通 Emacs 滚动。

公共命令是 `ebox-scroll-down`、`ebox-scroll-up`、`ebox-scroll-page-down`、
`ebox-scroll-page-up`、`ebox-wheel-scroll-down` 与 `ebox-wheel-scroll-up`。
`ebox-scroll-state` 根据数字 region id 返回只读快照。

## 7. 测量、缓存与构建工具

| 函数 | 契约 |
| --- | --- |
| `ebox-string-pixel-width` | 测量字符串第一行的 display width。 |
| `ebox-display-signature` | 返回 measurement cache invalidation 使用的 display 输入。 |
| `ebox-clear-cache` | 清理 Ebox measurement/render cache。 |
| `ebox-byte-compile` | 编译 Ebox 活跃 Elisp 源码；重启 Emacs 后加载新 bytecode。 |
| `ebox-native-status` | 报告 native toolchain、module、ABI 与加载状态。 |
| `ebox-native-build` | 异步构建并安装可选 native 模块。 |

native 模块只是加速器，不是正确性依赖。加载包不会构建它。

## 8. Facade 清单

`ebox-public-api` 保存稳定 facade 入口。下面的分组列出其中每一个名称：

- 构造：`ebox-build`、`ebox-text-create`、`ebox-normal-layout-create`、
  `ebox-row-layout-create`、`ebox-column-layout-create`、
  `ebox-flex-layout-create`、`ebox-grid-layout-create`、`ebox-box-create`、
  `ebox-child-range`；
- 渲染/发布：`ebox-render`、`ebox-render-to-buffer`、`ebox-display-buffer`、
  `ebox-commit`、`ebox-buffer-set-observer`、`ebox-buffer-update-report`、
  `ebox-rerender-buffer-with-context`、`ebox-viewport-window-width`、
  `ebox-call-with-render-burst`、`ebox-render-burst-begin`、
  `ebox-render-burst-end`；
- Candidate/identity：`ebox-candidate-begin`、`ebox-candidate-replace`、
  `ebox-candidate-replace-range-ref`、`ebox-candidate-replace-root`、
  `ebox-candidate-replace-host-ref`、`ebox-candidate-patch-host-paint`、
  `ebox-region-ids`、`ebox-region-resolve`、`ebox-region-update`、
  `ebox-host-ref-bounds`、`ebox-host-ref-position`；
- Selector：`ebox-selector-parse`、`ebox-selector-match-node-p`、
  `ebox-selector-query-all`、`ebox-selector-query-buffer`、
  `ebox-selector-update-buffer`、`ebox-select-all`、`ebox-update-selector`；
- 滚动：`ebox-buffer-mode`、`ebox-scroll-map`、`ebox-scroll-down`、
  `ebox-scroll-up`、`ebox-scroll-page-down`、`ebox-scroll-page-up`、
  `ebox-wheel-scroll-down`、`ebox-wheel-scroll-up`、`ebox-scroll-state`；
- 测量/构建：`ebox-string-pixel-width`、`ebox-display-signature`、
  `ebox-clear-cache`、`ebox-byte-compile`、`ebox-native-status`、
  `ebox-native-build`。

## 9. 验证

```sh
make load EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make compile EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make docs-contract-tests EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make dsl-tests EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make check EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
```
