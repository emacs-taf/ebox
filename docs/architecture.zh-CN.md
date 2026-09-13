# Ebox 增量更新合同

本文定义底层发布合同。它独立于 ETAF 应用状态，直接使用 Ebox 的调用者和上层包都必须遵守。

## 所有权

1. 调用者拥有新的 source tree。
2. `ebox-tree.el` 拥有 identity、key、遍历和 snapshot。
3. `ebox-style.el`、`ebox-measure.el` 与布局模块拥有归一化、测量和几何。
4. `ebox-incremental.el` 拥有 dirty 分类、live fact 适配、纯声明式 commit 准备和 Ebox 报告语义；`ebox-patch-plan.el` 只用不可变 parent fact 归并 tentative operation。
5. `ebox-surface.el` 投影 retained candidate，并让 Ebox runtime-state 发布加入 TP transaction。
6. TP 拥有首次 mount、声明式 commit、handle 更新、viewport/theme 更新和 scroll 更新的通用 retained-surface reconciliation、mount/index 状态、全部 live buffer diff 执行、revision 变更和 rollback。
7. `ebox-buffer-backend.el` 只构造和整形带文本属性的渲染字符串，不拥有 live marker 或 buffer mutation executor。

任何层都不能从可见 buffer 文本推断应用状态；公共调用者不能原地修改已经发布的树。每条公共 live 发布路径，包括 `ebox-render-to-buffer`、其展示包装 `ebox-display-buffer` 以及 commit/update 入口，都使用 retained TP surface；公共门面不再提供擦除 buffer 后执行任意 BODY 的 writer。

带 ECSS 语义标记的声明值及 custom property 保留在 source facts 中，直到
层叠计算。候选规范节点只填入具体 engine 值，带标记的尺寸不直接进入布局。
完整渲染和保留的 source 更新都会为这类声明请求样式计算。仅绘制变化的
快捷路径要求具体输入；子节点即使显式声明了属性，其中的 `var()` 或
`inherit` 仍可能依赖父节点。

局部 stylesheet facts 可以携带明确的 source 身份目标集合。候选 source index
把身份解析为自身的选择器 subject，作为集合快照传给 ECSS 作用域。保留的 source
重绑定和规范导出保留目标事实，作用域缓存以候选 source index 为键。因此样式
所有权独立于物理父子关系和 live buffer 坐标；ECSS 继续拥有结构匹配与继承。

层叠复用比较挂载 source 身份、规则和目标集合。仅元数据发布可以保留延迟更新
的选择器视图；树查询在匹配前根据当前 source facts 重建过期视图。

## Commit 生命周期

```text
新的根树
  -> 校验与归一化
  -> 复制到 surface-owned candidate state
  -> reconciliation TP object、key 与 Ebox identity
  -> 测量/布局候选
  -> 分类 dirty owner
  -> 生成 TP surface plan 与 Ebox report base
  -> TP 准备并原子发布 buffer 变更
  -> Ebox transaction participant 发布匹配的 runtime index/report
  -> 成功后退役 Ebox timer，并预热已提交的 scroll state
```

候选要么完整发布，要么丢弃。render、TP 写入、Ebox participant 或发布回调失败时，必须保留之前的 buffer 文本、属性、TP revision、Ebox runtime identity、滚动状态和最近一次成功报告。如果目标 buffer 在发布期间被 kill，teardown 是最终状态，rollback 绝不能把它复活。

## Patch 顺序

规划器优先使用 `paint-patch`，再使用 `span-patch`、`owner-rerender`，最后在几何或 identity 使小操作不安全时使用 `root-rerender`。incremental adapter 从 live generation fact 推导 tentative owner；pure patch port 随后只接收这些 artifact 与不可变 parent table。这些名称描述的是 Ebox 的语义 owner 范围；只有 TP 负责计算并执行物理文本/属性 diff。Patch 不得静默扩大语义范围。报告保留 Ebox strategy 与 planned scope，同时单独记录 TP 的实际 surface operation 和 revision。

span、owner-scoped、formatting-context 或 mixed 局部输出被拒绝时，producer 先重建普通 candidate state，再渲染完整 root。被拒绝的尝试留下的临时坐标、fragment 和 paint layer 不能授权发布。报告保留 planned strategy 与 scope；普通 fallback 的 `:projection-kind` 为 `nil`。因此，planned mixed strategy 不能证明计算始终局限在局部。

## 严格 retained viewport reflow

`viewport-reflow` 是一个明确的 retained projection kind，只用于范围很窄、由 proof 驱动的 viewport resize 路径。只有以下条件全部满足时，规划器才能选择它：plan 是一个 root-owned geometry `owner-rerender`；旧 root 与 candidate root 是同一个 retained root；没有 dirty entry 修改 children；node-key set、region-id set 和 parent table 都不变；旧 surface 和当前 style environment 都不需要 cascade 或 inline-inheritance 重新计算；没有 scroll state；root 没有 visible-overflow scope；旧 surface 存在非空 retained node-object table。仅改变 width、仅改变 height 以及同时改变两个轴使用同一套 proof。

选择该路径后，candidate 保留已发布的 Ebox topology，并复用 retained TP node-object subtree。Producer 仍会重新执行 viewport-sensitive layout 并生成新的 surface plan；TP 继续负责 scoped buffer diff、revision、stable identity 和原子 rollback。即使最终文本 patch 很小，topology、cascade、inheritance、scroll、overflow 或 display-signature 变化也不能报告为 `viewport-reflow`。

任意 proof 条件失败时，更新必须使用普通安全 projection 路径。该 fallback 可以执行更宽的 node projection 和 TP reconciliation，但必须保持相同的输出、identity、publication 和 rollback 合同。`tests/ebox-surface-tests.el` 覆盖 retained width/height/both-axis 路径、每个不安全 fallback 触发条件，以及 candidate preparation 之后的 publication failure。

## 保留式 scroll window

缓存滚动在可见窗口和 display context 的稳定性得到证明后，复用已发布的 cascade、
viewport axes 与未变化的 runtime index。Chrome-free root 直接拼接 rendered lines；
layered 或带 chrome 的 root 可以复用完整合成内容，只渲染 wrapper。纯 root offset
变化保留已经合成的 portal 和 anchor 内容；style、placement、content 或 display
context 变化必须使该证明失效。

通过证明的纯滚动变更从已发布状态与局部不可变 index delta 构造完整 candidate，
跳过通用声明式准备。Surface 提前生成带属性的替换文本及精确的新旧字符范围，
再通过带完整目标 mount specs 的认证 TP commit batch 发布，不构造 surface plan。
文本等长不能证明旧 mount 可复用：新进入视口的行可能具有不同 owner 与交互 tag。
Topology 与 TP object index 有效时，可复用私有 owner 解析缓存。属性更新与布局
重排仍使用各自的准备路径，只共享最终发布与回滚边界。

Nested owner 在 allocation 不变且通过证明时，可以只替换自己的 viewport，避免渲染
无关兄弟节点。若存在一个 offset 不变的 root scroll ancestor，还必须更新该祖先的
保留内容、ownership membership 和 line index，并将 producer 重新绑定到 candidate
树。缓存内容坐标与 mounted buffer 坐标分别验证。不支持的祖先链、部分可见的 owner，
以及 footprint 或 wrapper 证明失败的情况，保留普通 fallback。

必须在 staging 前区分 cache hit 与真实 prefix miss。Miss 使用复制的目标子树和祖先
路径、私有 index 与 registry、复制的缓存行，以及重新绑定的 producer；producer
不得在 TP commit 前修改已发布的 continuation。该隔离可能在 miss 时重建目标 prefix，
因此 cached-hit 耗时不能代表 miss 的代价。

预备的 viewport batch 在现有 scoped TP transaction 中只消费一次。后续 signal
触发的求值读取当前已提交 source，使用普通 projection。证明失败在发布前选择普通
路径；发布错误直接进入 rollback，不换另一个 renderer 重试。共享 evaluator 的
通用准备与 surface-plan 计数分别验证这两项工作已跳过；TP bookkeeping 与实际
buffer 写入另行测量。该路径并不保证耗时与总 object 数无关。

Scroll publication 仍经过 TP 与 Ebox participant。发布失败时，旧文本、属性、offset、
raw/rendered cache、source node、index、object、mount 和 report 均保持不变。聚焦回归
入口为 `make test`、`make test`、`make test`
和 `make test`；playground scroll evaluator 验证 fresh-render parity，
并区分缓存滚动与实际 prefix 扩展。

## Identity 与坐标

Key 只在同级兄弟集合内有效。声明式 source tree 不拥有 live TP object、marker 或 buffer 坐标。live 逻辑 `:id` 通过 `ebox-region-resolve` 解析为绑定某个 TP surface object 的不透明 handle；同一 source 挂载到两个 buffer 时会得到不同 handle。Region 与 host-ref 位置绑定于 generation；buffer 变更后调用者必须通过公共 accessor 重新获得位置。Buffer marker、display span 和 text property 是发布事实，不是 source tree identity。

## 验证

每条更新路径都要验证：

- 发布后的可见文本和属性完全正确；
- 兄弟节点重排时 keyed identity 稳定；
- rollback 后没有候选数据残留；
- 可以局部更新时 patch 范围受控；
- native reflow 不可用时 fallback 正确。

更新行为的聚焦测试使用 `tests/ebox-commit-tests.el`、`tests/ebox-core-render-tests.el` 和 `tests/ebox-grid-tests.el`；`tests/ebox-package-tests.el` 守护 live-buffer 发布边界；然后运行 `make check`。


## 设计与模块边界

Ebox 是底层空间渲染引擎。它负责把声明式节点树转换为经过测量的布局 fragment 与通用 TP surface plan。它有意小于应用框架。

## 设计原则

- 一棵 source tree、一套样式归一化、一条布局流水线、一个 buffer owner。
- 公共节点是数据；只有显式入口负责渲染与变更。
- 稳定 identity 来自节点 identity 和显式 key，不来自可见文本或 selector 字符串。
- 布局变化先测量再发布；候选发布失败时保留上一个 buffer 状态。
- native 模块只是可选加速器，必须有完全等价的 Elisp fallback。
- 新抽象必须消除重复，或让已有的公共工作流更简单。
- 公共 property schema、ECSS metadata 与 used engine projection 都从同一 property definition record 派生。
- 跨包 framework integration 只发布 additive versioned provider；consumer selection 与 fallback policy 不属于 Ebox。

## 流水线

```text
节点树
  -> 归一化样式
  -> 经过测量的 formatting context
  -> 布局 fragment 与 snapshot
  -> render context
  -> 纯 TP surface plan
```

各层 owner 是：`ebox-child-range.el` 负责不可变 child sequence 与 key index，`ebox-tree.el` 负责 Ebox identity 与遍历，`ebox-style.el` 负责样式语义，`ebox-measure.el` 负责 display 敏感测量，`ebox-layout.el`、`ebox-flex.el`、`ebox-grid.el` 负责几何，`ebox-fragment.el` 负责 fragment 事实，`ebox-render-context.el` 负责 candidate/materialization 输入 port，`ebox-patch-plan.el` 负责纯 operation-antichain artifact，`ebox-surface.el` 负责纯 TP plan 投影与 retained 发布，`ebox-incremental.el` 负责 dirty 分类与 live fact 适配。`ebox-layout.el` 不再 load 或调用 surface/TP 层；门面把 surface operation 接入已校验的 render-context port。patch planner 不读取 buffer 或 surface；incremental adapter 只传入不可变 parent fact 与 tentative operation。`ebox-buffer-backend.el` 只构造和整形带文本属性的 render string；所有公共 live buffer 发布路径都经过 TP surface 边界。

## 公共边界

使用 `docs/manual.zh-CN.md` 中的函数与 property；公共 API 清单位于根目录 `ebox.el` 的 Commentary。应用和同级包只能调用清单内的接口。更高层的 Component、响应式、behavior、data 和 control 概念属于 ETAF。

ECSS 与 TP 是必需的包依赖，即使作者没有写选择器或样式表也需要。EKP 是独立的可选
排版依赖：选择 `:wrap-mode kp` 时需要它的公开段落排版 API。EKP 不可用或不兼容时
会报错，不会擅自替换换行算法。它的加速器与 Ebox Rust reflow 模块相互独立。

`ebox-display-buffer` 先渲染，再把窗口放置交给原生 `display-buffer`。它接受调用方的
display action、返回 buffer，不选择独占窗口布局，也不选中结果窗口。一个 buffer
拥有一套挂载布局与视口；需要独立尺寸的视图应使用不同 buffer，不在同一段文本上
维护互相竞争的布局。

## 布局范围

Ebox 支持显式 `px`、`%`、`vw`、`vh`、`ch`、`lh` 尺寸、padding、margin、border、颜色、overflow、换行、row/column/flex formatting，以及固定、分数、隐式、gap、放置、span 和对齐等 Grid 能力。公共 typography 子集是 `:font-family`、以 CSS reference pixel 表示的 `:font-size`、`:font-weight` 和 `:font-style`；`:font-slant` 只是 `:font-style` 的精确 parse-time alias。任意 Emacs face 和文本属性 plist 属于最终 adapter，不是 Ebox 作者输入；四种显式原生能力 `:help-echo`、`:pointer`、`:hover-style`、`:keymap` 单独受支持。CSS 兼容性有意是部分实现：绝对定位、z-index、阴影、border radius、完整浏览器 typography 和浏览器级 bidi 不属于本包。

文本簇模型覆盖常见组合音标、变体选择符、Emoji 修饰符、ZWJ 序列和区域指示符配对。
它的范围小于完整 Unicode 字素分段；字符数量或这个有限的分段模型，都不能保证任意
字体塑造结果相同。

可选交互导航在当前渲染的 keymap owner 之间移动 point，读取已提交 surface，尊重
narrowing 与不可见性，不安装按键绑定、焦点注册表或应用状态。action 与状态仍属于
调用方。

横向 `:overflow hidden` 在内容组合后、自身 padding 和 border 添加前执行。它选取
测量后能容纳的完整受支持文本簇前缀，再用空白补齐剩余像素。固定 display space 可以
缩短，字形与图像不做局部位图裁剪；裁掉的子节点属性不会残留在中性填充上。
算法按 GPL-3.0-or-later 复用了
[s-pixel](https://github.com/Kinneyzhang/s-pixel/tree/a2a0d6ae6b3bd71c1a70084d0ea37f56463e5fe0)
的前缀加空白补齐思路，适配 Ebox 的文本簇与属性模型，不增加 `s` 或 `s-pixel` 依赖，
也不引入层叠或重叠组合。

## 尺寸组合

`ebox-size.el` 负责长度验证、依赖识别、浮点像素换算，并提供累计量化的纯函数，
供布局在选定的显示边界调用。上下文显式传入视口两轴、
该属性的百分比参照、`0` 字形前进宽度和行高；模块不读取窗口或节点，不求值任意
Lisp，不选择属性默认值，也不发布 buffer。Normal、Flex、Grid、间距和边框几何
由此复用同一套单位运算。

作者格式为 `(单位 数值)`，可组合函数是 `calc`、`min`、`max`、`clamp`。
property schema 负责允许的单位、关键词和值域。[统一单位约束表](manual.zh-CN.md#size-unit-constraints)
是作者契约：inline 几何、block 几何和边框绘制采用不同单位集合。验证递归遍历
所有函数分支和轨道参数；Flex basis 使用所在父布局主轴。无效单位组合在构造阶段
就报错，不延后到布局或显示。

布局负责提供包含块及字体测量，并解析固有/自动尺寸。`fit-content` 只接受裸关键词。
旧的裸长度、单元素像素列表、视口
关键词和 `contain` 不保留兼容执行路径。

参照尺寸缺失时延后解析，不当作零；中间运算保留小数，到格式化/显示边界才量化。
buffer 后端按完整行生成 block 几何，与收窄后的纵向单位契约一致。空 Box 的自动
内容高度为零；需要占位时由显式高度、padding 或 border 提供对应尺寸。

## 验证规则

每个行为修改都要补充聚焦的 ERT 测试，并运行新的 `make check`。修改 native 源码还要运行 `make test`；修改文档或 active 文件集合还要运行 `make test`。
