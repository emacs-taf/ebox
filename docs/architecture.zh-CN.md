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

局部内容槽位复用要求父布局分配独立于变化的内容。仅有相同的父节点声明和保留
坐标不能证明这一点：内在宽度可能变大或变小，改变兄弟节点的对齐和填充。
这类更新在发布前提升到负责分配的包含布局。

带 ECSS 语义标记的声明值及 custom property 保留在 source facts 中，直到
层叠计算。候选规范节点只填入具体 engine 值，带标记的尺寸不直接进入布局。
完整渲染和保留的 source 更新都会为这类声明请求样式计算。仅绘制变化的
快捷路径要求具体输入；子节点即使显式声明了属性，其中的 `var()` 或
`inherit` 仍可能依赖父节点。

局部 stylesheet facts 可以携带明确的 source 身份目标集合。候选 source index
把身份解析为自身的选择器 subject，作为集合快照传给 ECSS 作用域。保留的 source
重绑定和规范导出保留目标事实，作用域缓存以候选 source index 为键。因此样式
所有权独立于物理父子关系和 live buffer 坐标；ECSS 继续拥有结构匹配与继承。

选择器 subject 保存不可变本地元数据及稳定的父子关系键。每个 source generation
通过自己的持久索引和 ECSS subject adapter 解析这些键。候选树路径复制只更新
受影响 subject，不需要修补未变化子节点的父对象引用，也不修改已发布的树。
查询条目和查找表可以延迟更新；样式计算已经拥有一致的候选关系，不因查询缓存
过期而重建关系树。

层叠复用比较挂载 source 身份、规则、目标成员资格和继承值。只依赖 subject
自身的选择器按每个绑定的有序规则输入、成员资格和祖先身份链判断复用；增加或
移除其他成员不会让未受影响的绑定失效。Subject 元数据、作用域根、适用规则
版本和父样式绑定仍参与校验。ECSS 分类选择器依赖，Ebox 证明宿主关系和作用域
事实；结构选择器仍完整失效。这减少普通投影中重复的样式工作，不代表所有原生
属性或混合更新都已经采用局部投影。

原生结构更新可以复用显示对象，同时仍需完整样式投影。此时，候选重建选择器
关系，并在原生布局消费节点前为所有节点应用当前样式。对象身份保留本身不构成
样式复用证明；结构稳定的原生更新仍需满足规划器的预计算样式契约。

Canonical 输入的选择器元数据变化会准备完整候选样式树，包括仅由规则设置
样式的节点。两种渲染器都在规划前接收完整的计算结果变化，包括 source delta
之外因样式而改变的节点；检查只访问 Style Adapter 本次准备的节点。
原生续用读取已发布 fragment ledger 中确认的 frame 及其根几何；
临时渲染字段只承载当前尚未发布的结果。原生计划必须具备可执行的 viewport，
才能跳过普通投影。

局部样式预计算读取候选的挂载作用域，并在复用前比较已发布上下文。依赖树关系
的匹配交给完整投影；未完成的 author 样式转换在局部几何探测之前确定这一边界，
避免探测过程中把子树当作完整样式树渲染。每次成功的局部投影仍保留完整样式表
签名，供下一次更新使用；计算范围缩小不意味着可以丢弃已发布的上下文。保留样式绑定时，绘制 owner 同样
需要检查选择器事实：结果分类为绘制变化，仍可能来自 class 或交互状态变化。

局部 owner 证明从候选 source index 解析作用域签名，包含不可变规则版本与成员
身份，不依赖当前动态渲染环境。保留祖先原生 keymap 时使用 TP 的属性相等策略：
绑定相同的防御性副本仍然等价，命令、前缀映射或继承绑定变化则必须发布。

规范构造者与 DSL 通过 Ebox 拥有的统一声明投影取得临时 LayoutConfig 和 outer
字段。该投影排除延迟值并缓存具体配置，不取得 source 声明所有权；完整声明仍是
层叠计算输入。

共享样式描述是不可变 stylesheet 快照。规则更新保留成员身份，各根选择自身的
规则版本，旧输入保持不变。Source record 携带成员与根标记，候选 source index
将标记归并为 ECSS 挂载；多根无需合成可见节点。成员归属属于候选版本，slot
插入与移除通过普通 source delta 改变归属。层叠签名包含描述身份、stylesheet
版本、挂载 source 和成员身份；没有根的描述在组合到根之前不贡献规则。

原生 Box 将解析后的确定内容高度（包括父 Flex 分配及高度上下限约束）传给
内部 Flex 排版上下文，子布局求值请求保留该分配。未确定的自动高度仍由内容
决定，不能把环境 viewport 高度当作分配值。

同一原生 frame 内，按 source 地址和完整约束共享已完成的布局请求，包括两个
viewport 轴、内在尺寸模式、尺寸覆盖和滚动效果模式。Flex 的不同测量阶段可以
复用相同子树结果，不再重复执行其布局。此 memo 属于不可变 frame 的本次事务，
结束后丢弃。每个调用者保留自己的使用边，并相对自己的上一结果计算变化；最终
滚动所有权仍与测量探测区分。跨 frame 复用继续由 source 失效和保留求值树负责。

自动高度的单行 Grid 原生布局支持固定及 `fr` 轨道。单元格为自动放置的 Text，
或没有竞争尺寸约束和外边距、填满并裁剪轨道的 Box。轨道分配保留文本的最小
内容宽度；未确定宽度时按内容测量比例轨道，并在累计像素边界取整。单元格保留
source 所有权、边框、内边距、绘制和溢出行为；内容和 viewport 变化通过共享的
保留源及布局求值路径重新分配。其余 Grid 配置保留完整 Elisp 实现。

原生布局上下文独立保留原始 frame viewport 的两个轴，不随包含块或 Flex 元素
分配而改变。`vw` 宽度与行向 basis、`vh` 高度及其上下限与列向 basis 在 IR 中
保留相对值，每个 frame（包括保留请求）重新解析。高度 `calc` 的加减法保留
操作数符号；字体度量将 viewport 像素换算为所属节点的行高单位。小数或越界
操作数在发布前拒绝原生候选，由普通布局路径处理。其他依赖上下文的表达式
保留完整 Elisp 实现。

## Commit 生命周期

框架候选把节点自身属性更新与子树、子 Range 替换区分开来。属性输入比较
前后两代作者声明，不能以计算后的布局或继承样式作为旧输入。属性操作保留
内容与子树结构，再进入 Ebox 原有的样式计算、布局、影响分类与发布流程。
消费者不判断变化是否仅涉及绘制，也不负责选择子树回退。

属性更新在结构组合后作用于仍保留的节点。被移除的节点不再接收更新，
完整根替换吸收全部操作。source index 与最终路径复制记录描述同一棵结果树。

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

投影规划在多个局部证明之间共享 TP 挂载范围的数值快照。该只读视图只存在于
一次规划过程，在 TP 发布新坐标之前丢弃；它不替代 TP 的权威挂载状态，也不
改变 Ebox 公共查询返回防御性快照的契约。

重叠替换在合并后代写入前，先从最近的候选祖先解析中间节点。若从已提交树
复制中间路径，会覆盖该祖先对兄弟内容的修改。查询仅覆盖受影响路径，未变
子树继续共享；拒绝发布时保留已提交代和焦点。

Range 更新按祖先到后代解析，与记录顺序无关。后代地址从当前候选父节点解析，
祖先已移除的后代更新被吸收。Range delta 描述受影响的内容，owner 与内容节点
均从最终路径复制记录中进入索引；后续后代更新可能再次复制它们。大范围索引
重建同时接收最终源节点先序，包含插入和删除。两条准备路径都发布相互匹配的
树与索引代。

Runtime 身份转移保留节点与 region 身份，不复制子序列坐标。坐标属于特定的
父树；keyed 插入或重排后，按当前树重新解析或建立位置索引。
子树与 Range 替换共用同一个兄弟身份匹配器。
兄弟节点先按 author key 匹配；无 key 时，先按相同的源身份匹配。位置回退排除
新兄弟列表中仍然保留的身份，避免插入内容占用存活节点的身份、使嵌套 Host 更新失效。

完整和增量 surface 投影均把已协调的 runtime 节点身份用作 TP key，不再次按
author key 或兄弟位置判断身份。因此，插入状态标签时，后续保留的兄弟节点仍
使用原来的 TP object、样式绑定和可编辑 handle。

## Patch 顺序

完整层叠投影重新建立渲染签名、viewport 高度依赖与内在宽度的派生缓存。
仅按源修改路径失效不足以证明这些缓存有效：源未变的后代仍可能继承新样式。
渲染输出继续按新计算的签名复用；已证明的局部投影保留其准备阶段的缓存失效结果。

规划器优先使用 `paint-patch`，再使用 `span-patch`、`owner-rerender`，最后在几何或 identity 使小操作不安全时使用 `root-rerender`。incremental adapter 从 live generation fact 推导 tentative owner；pure patch port 随后只接收这些 artifact 与不可变 parent table。这些名称描述的是 Ebox 的语义 owner 范围；只有 TP 负责计算并执行物理文本/属性 diff。Patch 不得静默扩大语义范围。报告保留 Ebox strategy 与 planned scope，同时单独记录 TP 的实际 surface operation 和 revision。

仅选择器状态变化时，完整计算样式闭包若证明没有绘制变化，且身份、父子关系和显示
约束不变，可复用已有 paint 投影。这覆盖没有视觉规则命中的焦点和按下状态切换：
非滚动 surface 会进一步提交坐标不变的空 TP batch，只提升 runtime 与选择器索引，
不重新协调挂载对象；滚动或稀疏 candidate context 则保留普通 paint 投影。滚动内容
和覆盖层像素仍被保留。任何计算样式中的绘制或几何变化继续使用普通增量规划。

span、owner-scoped、formatting-context 或 mixed 局部输出被拒绝时，producer 先重建普通 candidate state，再渲染完整 root。被拒绝的尝试留下的临时坐标、fragment 和 paint layer 不能授权发布。报告保留 planned strategy 与 scope；普通 fallback 的 `:projection-kind` 为 `nil`。因此，planned mixed strategy 不能证明计算始终局限在局部。

## 严格 retained viewport reflow

`viewport-reflow` 是一个明确的 retained projection kind，只用于范围很窄、由 proof 驱动的 viewport resize 路径。只有以下条件全部满足时，规划器才能选择它：plan 是一个 root-owned geometry `owner-rerender`；旧 root 与 candidate root 是同一个 retained root；没有 dirty entry 修改 children；node-key set、region-id set 和 parent table 都不变；旧 surface 和当前 style environment 都不需要 cascade 或 inline-inheritance 重新计算；没有 scroll state；root 没有 visible-overflow scope；旧 surface 存在非空 retained node-object table。仅改变 width、仅改变 height 以及同时改变两个轴使用同一套 proof。 样式稳定性比较当前全局 stylesheet 及从已挂载 source index 解析的作用域与已发布签名。

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

原生 frame 按所属 region 交付完整 scroll producer 集合，支持并列和嵌套容器。
保留求值树只收集最终布局使用，排除内在尺寸及 Flex/Grid 测量探测。各 producer
保留完整内容、可见高度和实际 offset，未变化的内容计划可以分别复用。Ebox 将
集合安装到普通滚动状态，通过候选路径复制修正 offset。从普通发布切回原生时
重新建立原生 source 基线。原生 producer 目前要求顶部对齐、无容器边框内外边距
及 surface template；其余几何在发布前使用 Elisp。

Scroll publication 仍经过 TP 与 Ebox participant。发布失败时，旧文本、属性、offset、
raw/rendered cache、source node、index、object、mount 和 report 均保持不变。
`make test` 覆盖独立嵌套容器、拒绝移除、内容缩短后的 offset 修正和卸载清理；
playground scroll evaluator 验证 fresh-render parity，并区分缓存滚动与实际 prefix 扩展。

## Identity 与坐标

Key 只在同级兄弟集合内有效。声明式 source tree 不拥有 live TP object、marker 或 buffer 坐标。live 逻辑 `:id` 通过 `ebox-region-resolve` 解析为绑定某个 TP surface object 的不透明 handle；同一 source 挂载到两个 buffer 时会得到不同 handle。Region 与 host-ref 位置绑定于 generation；buffer 变更后调用者必须通过公共 accessor 重新获得位置。Buffer marker、display span 和 text property 是发布事实，不是 source tree identity。

原生输入边界只在 reader 调用期间保留当前 surface 与目标身份，接受结果和恢复
焦点时复用已提交的归属索引、可见性与焦点校验。它不增加目标注册表、编辑状态
或文本写入方。原生 Emacs 持有输入过程，消费者在边界返回后应用已接受的值。

主按钮拖动也由 Ebox 跟踪。生成的 keymap 在按下时确定声明节点，并在发布重排后
复用焦点的 source identity／key 解析保持目标。原生跟踪循环提供 start、变化的
移动位置和一次 end／cancel；不保存应用位置、不增加目标注册表或独立发布路径。
消费者在每次回调中使用普通公共更新操作。原生 reader 空闲时定期检查目标和窗口
是否存续，无关输入交回 Emacs 命令循环。

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
调用方。原生激活同样读取已提交 surface 与绘制祖先中的 keymap owner，显式 nil
阻止祖先激活。不可访问、不可见和结构文本不能成为目标；归属校验后才执行命令，
回调错误保持可观察，不另建目标注册表。

逻辑焦点只有一个 buffer-local retained node owner。公共焦点变更拒绝加入活动中的
TP 事务，只有发布内部 participant 可以协调候选焦点并在拒绝时恢复。事务接受后的
回调可以发起新的焦点操作，只读查询仍可使用。发布后的 source interaction facts
提供 tab 顺序与禁用状态。Source record 分别保存作者状态与交互事实，subject 构造从
交互事实派生 `disabled`。查询、cascade 和增量失效读取同一派生视图；rebind 保留原始
作者状态，禁用变化会使 subject 失效。挂载焦点在候选 source record 中形成不可变
派生视图，作者不能声明此状态。焦点请求绑定发起时的已提交代，观察回调中的新提交
不会重放旧请求。候选阶段通过 ECSS 检查目标与祖先，最终渲染再校验绘制归属；裁剪
使已有焦点不可用时，复用同一 TP 对象清除状态并重算，之后才进行一次接受发布。
新请求的目标不可访问时原子拒绝。纯输入不保留挂载焦点。按下归属复用同一不可变
source 交互状态投影与发布 participant：生成的主按钮跟踪在回调前设置 `active`，
结束时清除；普通更新按存续 source identity 与可见性协调归属。选择器查询、ECSS
与绘制读取相同状态，消费者不保存镜像。激活接管释放事件，在清除状态后读取已接受的
原生绑定。悬停状态接入 cascade 仍待完成。
每次发布后延迟重建导航向量与 rank
索引，使用时检查可见性；每次导航不再扫描、排序全部 Host。稳定 runtime identity
加上非 nil 兄弟 key，连接 keyed DSL commit 中新生成的 source handle；仍存在的显式
source identity 优先于复用的绘制节点。Region 更新同时比较 source interaction facts
和原生投影，因此 tab 顺序或禁用节点的 keymap 更换不会被误判成 no-op。

Ebox 的可回滚 participant 随候选提升焦点，拒绝时恢复。TP 在 final accept 恢复原生
视图 marker，因此 Ebox 在受控 after-commit 回调中重新应用 point，且只作用于仍为
当前代的候选。手动 point 保留受可访问范围限制的数值位置。卸载清理焦点与派生索引；
该状态不管理应用值，也不选择窗口。

挂载 buffer mode 拥有共享导航与激活绑定。生成的原生键盘激活命令查询 point 上的
有效焦点，显式位置激活和鼠标回调则保持物理目标选择。有效 map 沿 source 归属与
祖先 nil 屏障解析。动态分派标记避免生成命令在 `ebox-activate` 选定已提交命令后
再次进入目标选择。自定义原生命令保持原生行为；重叠控件的正确激活不需要消费者
再实现焦点或输入模式。

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
