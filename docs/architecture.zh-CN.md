# Ebox 架构

[English](architecture.md)

Ebox 的实现模型是每个 mount 拥有一棵可变 retained 节点树。Public 调用方构建树、把它
挂载到 Emacs buffer，然后修改节点。Ebox 在受影响节点上记录 style、layout 与 paint dirt，
找到最小安全布局边界，只组合 damaged root lines，并只重写发生变化的 buffer 行内片段。

Public 合同是 [`../ebox.el`](../ebox.el) 的 Commentary。`lisp/` 下的文件是私有实现模块。

## 模块与依赖方向

`ebox.el` 是包入口。它把 `lisp/` 加入 `load-path`，require 实现模块，并维护 public API 清单。

实现模块按职责划分：

| 模块 | 职责 |
| --- | --- |
| `ebox-size.el` | 纯验证与解析 `(unit number)` 长度和尺寸函数。 |
| `ebox-style.el` | Ebox style schema、alias、validator、shorthand expansion、ECSS scope 创建与样式编译。 |
| `ebox-measure.el` | 像素测量、文本单元分段、display-space 构造、属性比较与 pad twin。 |
| `ebox-node.el` | Retained node record、child sequence、author 属性解析、author DSL、selector adapter 与 computed-style record。 |
| `ebox-layout.el` | Text、box、row、column 与 positioned layout；line composition；damage range；root-line edit planning。 |
| `ebox-flex.el` | `ebox-layout.el` 使用的 flex 与 grid 算法。 |
| `ebox-buffer.el` | Mount、dirty queue、batching、flush 编排、viewport 测量、buffer diff 写入与几何查询。 |
| `ebox-interaction.el` | Keymap、help/pointer/hover decoration、focus、activation、drag tracking、input session、scrolling 与 selector query。 |
| `ebox-viewport.el` | Window-size event 桥接和稳定后的 viewport refit 调度。 |
| `ebox-image.el` | 图片准备、converter 协议、不可变 raster cache 与图片内容访问。 |
| `ebox-file.el` | `.ebox` source 读取、companion 加载、preview mode 与包 byte compilation helper。 |

底层纯模块不知道 mount。node 依赖 size、style 与 measurement。layout 依赖 retained node，并通过
private function 调用 flex/grid。buffer flushing 依赖 node 与 layout。interaction 位于 mounted buffer 之上。
viewport delivery 只请求 `ebox-refit`。图片在 layout 之外准备，随后成为节点内容。

## 核心 record

### Node

`ebox-node` 是 retained tree record。它存储：

- author identity 与 selector facts：tag、id、classes、attributes、states、key 和用户数据；
- 编译后的 declaration、default rule、本地/共享 ECSS scope 与活动 scope environment；
- help、pointer、hover、keymap、tab index、disabled state 等交互属性；
- text 或已准备图片内容；
- chunked sequence 中的 parent/child 链接；
- computed style、measurement cache、intrinsic-size cache 与最后一次 layout；
- dirty bits、dirty children、structural operations 与 overlay registration；
- scroll offset，以及 root 的 owning mount pointer。

children 与 stacked layout items 使用 chunked sequence。每个元素记录自己的 run 和位置，因此插入、
删除和 index lookup 的成本受 run size 与 run count 限制，而不是移动 flat vector 中所有后续元素。

### Computed style

`ebox-cs` 是由 ECSS computed values、parent style 和 node tag 生成的 hash-consed
computed-style record。它保存完整 normalized values，以及 face、继承 paint、dimensions、edges、
borders、overflow、positioning、flex/row/column facts、z order、viewport-unit dependencies
和 layout key 等热路径布局字段。相同局部输入共享同一个 style 对象，因此几何比较可以使用对象 identity
或 interned layout key。

style environment 保存在 node 上。内联 rule 和 default 变为 scope；shared scope 只通过显式 root
和 member 生效。subject-local scope style 可以进入 style cache key；结构 selector 回退到 ECSS 计算。

### Layout 与 mount record

`ebox-geo` 保存已解析 margin、border、padding、border-box size、content-box size、visible height、
scroll offset、content height 和 layout items。stacked layout 使用 chunked item sequence；positioned
layout 使用 vector。匿名 inline paragraph 是所属 box 的 `ebox-para` record。

`ebox-mount` 将一个 root 绑定到一个 buffer。它存储 viewport 尺寸、line anchors、已写 line parts、
update reports、observer、focus、active 与 hover state、input session、queue flag、flush count 和
保存的 display settings。

## Dirty bits 与 queueing

每个 mutation 都通过 `ebox--mutation`，先执行变更，再在没有 batch 或 flush 时 flush queued mounts。

Dirty bits 包括：

- `ebox--d-style`：style 或 selector 输入变化。
- `ebox--d-layout`：geometry 或内容尺寸可能变化。
- `ebox--d-paint`：geometry 不变但 paint 可能变化。
- `ebox--d-desc`：descendant 变化。
- `ebox--d-queued`：该节点已列入 parent 的 dirty children。

`ebox--mark` 在变更节点设置 bit、清除 intrinsic cache、把 dirty path 记录到 ancestor，并将 root 的
mount 入队。结构 mutation 还会把简短 operation 描述压入 parent，使 stacked layout 能在可能时记录精确
insert/remove damage。

`ebox-with-batch` 增加动态 batch depth。最外层 unwind path 调用 `ebox-flush`，因此所有 queued mount
会以最终树状态写入一次。

## Flush pipeline

`ebox--flush-mount` 是 retained engine 的中心 pass：

1. 绑定 mount viewport 与 current mount。
2. 在 dirty paths 上运行 style pass。
3. 用当前 viewport 对 root 运行 layout。
4. 放置 anchored absolute boxes 直到稳定。
5. 剪除被更大范围覆盖的 damage records。
6. 将 damage 转成有序 root-line edits。
7. 第一次 flush 重写整个 buffer；之后只重写 edit ranges。
8. 保存并发送 update report。

带 active input session 的 mount 保持 queued，但不会写入；结束 session 会重新入队，并由同一 pipeline 追赶。

## Style pass

`ebox--style-pass` 在节点 style bit 已设置、没有 computed style，或 ancestor computed style 改变时访问节点。
它根据节点 declarations、active scopes 与 parent style 计算新的 `ebox-cs`。

如果新 style 通过 object identity 相等，则无需更多工作。如果只有 layout key 不变，Ebox 标记 paint dirt。
否则标记 layout dirt、清除 intrinsic cache，并在 flex/grid item facts、outer participation 或 absolute positioning
影响 container 时标记 parent layout。

viewport-unit dependencies 记录在 weak table 中。`ebox-refit` 使用该表，在 mounted viewport 变化时只标记实际读取
`vw` 或 `vh` 的节点。

## Layout pass 与 relayout boundary

`ebox--layout` 接收节点、可用 inline 像素、mode（`stretch`、`shrink` 或 `exact`）、containing block height
和可选 forced height。最后一次 constraint vector 保存在节点上。如果 constraint 与相关 dirty bits 都未变化，
layout 会跳过。

当 descendant dirty 时，`ebox--relayout-partial` 尝试只结算记录的 dirty children。stacked container 可以通过移动
后续 stack items 并调整自身 content height 来吸收 child height change。这就是常见 relayout boundary：当 ancestor
的 outer size 与 child placements 仍兼容时，damage 保持局部。如果 container 不能吸收变化，Ebox relayout 该 container。
如果 full relayout 后 container size 和 child places 不变，则保留 inner damage；否则该 container 的整个 margin box
成为 damage，ancestor 只看到它的新 outer size。

文本测量按 text node、font face 与 wrap mode 缓存。paragraph layout 将文本拆成 pixel-width units，保留受支持
cluster 与 fixed display space。box 在横向解析为像素、纵向解析为行。row 与 column 沿一个轴定位直接子节点。
flex 使用 min/max freezing、wrapping 与 alignment 做 main-size grow/shrink。grid 展开 track、解析 fixed/intrinsic/
fractional size，并按一基 grid position 放置 item。

absolute box 注册到 positioning host（最近的非 inline 父节点；`:layer root` 时为根）。本地 overlay 在 host 内组合；root-targeted overlay 仍保留逻辑 parent 供 style
与 selector 使用。anchored overlay 从唯一 target 计算 placement，并在 normal layout 后放置，使 target 移动无需触发
无关 relayout。

## Paint 与 parts cache

layout 产生 geometry；paint 按 root line 懒组合。node line 是由 margin、border、padding、content、overlay 与交互属性
组成的 string parts tree。节点在高度限制内缓存已组合 line parts；paragraph 缓存 wrapped line strings。
damage 会使 changed node 以及已经组合过它 line 的 ancestor 失效。

`ebox--join-parts` 展平嵌套 parts。display space 按 pixel width 与 face intern。Emacs 会合并相邻且 `display` 对象
`eq` 的字符，因此 `ebox-measure.el` 维护 twin pad displays，并在 part 边界替换 alternate。这样既保持精确像素间距，
又允许 line parts 跨 flush 共享。

交互 decoration 在 composition 中发生。Ebox 填充未设置的 `ebox-node`、`keymap`、`help-echo`、`pointer` 和
`mouse-face` property，使最内层显式节点胜出，ancestor keymap 覆盖未 override 的 descendant。

overlay 拼接进它覆盖的行时不做字符串连接。`ebox--split-parts` 在 overlay 的像素列处切分底层 parts；
跨越切点的 string 变为按宽度截取的 substring 加边缘空白，组合出的 string 把像素宽度记录在
`ebox--part-widths` 中，后续拼接无需重新测量。没有边框的 overlay 行保持为 part list，
因此移动 overlay 的成本是覆盖行数乘以各行的 part 数。

## Buffer 写入

第一次 mount flush 会 erase 并写入完整 root。后续 flush 从 damage records 计算 root-line edits。每个 edit 是
`(START OLD NEW)`，其中 `START` 使用 preceding edits 后的 post-layout line 坐标。

每 128 行一个 line anchor，使 Ebox 无需为每一行保留 marker 也能定位 edit start。被重写范围内的 point 与 window start
按 line 和 column 记录，写入后再恢复。

对 changed line，`ebox--write-line` 使用 mount 记忆的 part list。`ebox--rewrite-parts` 去掉前后相等共享 string 对象，
只替换中间部分。如果没有可用 remembered parts，Ebox 回退到 `ebox--rewrite-line`：按 prefix/suffix 比较字符，只设置
变化的 property runs。外部 buffer edit 会通过 buffer tick 使 remembered parts 失效；下一次 flush 从 retained tree
安全重算。

mount 尚无任何行时跳过位置跟踪，因此首次写入空 buffer 的内容保持 point 与 window start 在顶部。
每次 flush 结束时 `ebox--sync-canvas` 把 buffer 的 `default` 背景 remap 为根节点的计算背景，
使最后一行以下与行尾之后的窗口区域与根一致；卸载时移除该 remap。

## Viewport、scrolling 与 input

mount 记录一个 viewport。`ebox-viewport.el` 监听 frame/window-size notification，等待安静间隔，然后对已显示 mount 调用
`ebox-refit`。临时 minibuffer、completion 或 echo-area 高度变化不会强制更小 viewport，除非 frame 自身改变。

scroll offset 存在 node 上。scroll mutation 改变可见 content lines，而非 layout constraints，因此 clean scrollable node
可直接为自身 visible height 入队 line damage。

input session 会临时把一个 painted span 交给用户。Ebox 保存 marker、original text 与 read-only state，暂缓该 mount 的写入，
结束时先恢复 retained text，再 flush queued node changes。

## 不变式

- Retained node tree 是事实来源；buffer text 是输出缓存。
- 节点最多有一个 parent。detached root 可以渲染或挂载；mounted descendant 必须留在自己的 root tree 中。
- 只有 public mutation 改变 retained node。实现 cache 由 dirty bits 失效，不从 buffer text 反推。
- computed style 属于构建它时的 parent style、declarations、selector facts 与 scope environment。
- 纵向 geometry 基于行；横向 geometry 基于像素。
- 同 constraint 下的 clean node 保留 layout 与 composed line cache。dirty node 要么记录精确 damage，要么 damage 最小 shape-changing boundary。
- buffer 写入保留无关 buffer state：read-only、undo list、modified flag、point 与 window start。
- 图片 decoding 与外部 converter 执行只发生在图片准备阶段，绝不发生在 layout 或 buffer 写入中。
- private module 可以变化；consumer 只 require `ebox`，只使用 `ebox.el` 中记录的 symbol。

## 设计理由

retained tree 使小更新无需为每次变化重建完整描述。dirty bits 分类可复用内容。hash-consed computed style 降低继承和
scoped style 复用成本。relayout boundary 将常见编辑（例如垂直 stack 中的文本变化）转成局部 line damage。parts-level
buffer diff 避免替换 Emacs redisplay 可保留的字符和属性。最终 public API 保持简单：build、mount、mutate、flush、query、unmount。
