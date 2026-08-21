# Ebox 性能架构诊断与重构方向

> 状态：架构诊断与实现 checkpoint。本文记录 current refactored Ebox 相比历史 Ebox checkout 的性能差异、证据边界和高层重构方向。五个范围很窄的 slice 已经实现；mounted retained-update 架构尚不能认为已经普遍修复。
>
> 日期：2026-08-07
>
> 修订：2026-08-08。根据独立架构审查，本文将 style cascade、projection、candidate、pure render 和 retained TP coupling 拆为不同问题，降低未被阶段计时直接证明的结论置信度，并记录隔离 pure materialization、candidate handoff、partial-line scoped projection、严格 retained viewport-reflow 和 fixed-footprint copy-on-write 五个 checkpoint。

## 问题

为什么 current refactored Ebox 在动态内容更新、viewport resize 和纯 `ebox-render` 场景下，性能达不到历史 Ebox checkout？需要先确定数据流和 ownership 层面的主因，而不是继续优化某个具体函数。

## 结论

性能回退的主因不是某个函数单独变慢，而是在 baseline retained 数据流中，computation scope 被错误地绑定到一条全树路径：current Ebox 把“生成最终带文本属性的字符串”和“维护一个 retained、可增量更新、带稳定 identity 的 TP surface”连接在同一条路径上，并在尚未收窄 scope 的路径中触发全树 style cascade、projection 和 candidate preparation。

因此，在 scoped slice 之前，即使一次更新最终只需要一个 owner、一个 text operation，current 仍然会先支付全树 style computation、node projection、candidate preparation 和 ownership/range 构造的成本。修复前的路径还会重复 identity reconciliation。partial-row checkpoint 已经移除了一个稳定 owner 形状上不必要的 projection/layout 扩张，但未解决的路径仍可能扩大；现有阶段数据直接证明 style cascade 和 baseline projection 是主要可测成本，但还没有单独证明 TP identity、retain 或最终 publication 本身是最大瓶颈。

关键判断是：current 的“局部 patch”只是 publication 粒度，不是 computation 粒度。legacy 的局部更新在大多数情况下同时是局部计算和局部 publication；current 只在最后一步变成局部。Retained TP boundary 应被视为造成这种 scope coupling 的架构边界，而不是未经拆分计时证明的单一底层瓶颈。现在已经为一个可测场景建立严格的 retained `viewport-reflow` slice：复用 retained node-object subtree、重新执行 viewport layout，并把 cascade、inheritance、scroll、visible-overflow 和 topology 场景拒绝到普通安全路径。

## 比较范围与术语

- “current”指独立重构版 `ebox` 仓库。
- “legacy”指同级历史 Ebox checkout。
- “pure materialization”指从 source tree 产生带文本属性的渲染字符串，不需要 live buffer、稳定 retained identity 或 rollback。
- “retained publication”指向已挂载 TP surface 发布候选状态，包含稳定 identity、ownership、scope proof、revision 和 rollback 语义。
- 文中的绝对耗时来自同一个本地测量环境；架构判断依赖阶段占比、调用次数和相同输出结果，不依赖某一个绝对时间阈值。

## 阶段级证据

### 动态 content update

使用同一个约 1712 节点的 `dynamic-update-reference.ebox` fixture，current parser 能构造相同规模的节点树。该 fixture 没有 stylesheet rule，但存在 inline inherited style。

| 项目 | Current | Legacy | 直接观察到的事实 |
| --- | ---: | ---: | --- |
| 总耗时 | 12.127969s | 0.073844s | 输出长度为 1177，SHA-256 完全一致 |
| projection 起始阶段 | 10.882838s | 不存在 | current 调用 `ensure-node-tree` 1712 次；区间边界仍需在探针合同中定义 |
| style computation | 1262 次，约 8.99s | 无等价阶段 | `ecss-compute-style` 1262 次，约 8.95s |
| 最终文本操作 | 1 次 | 局部 patch | current report 仍是 `span-patch`，dirty 只有 1 个 owner |
| TP 结构统计 | reconciled objects 1716；property operations 378 | 直接 buffer/region 路径 | TP 最终 publication 不是主要耗时来源 |

current 在完成全树 projection 和 style computation 后，最终只需要一个局部 owner 的 patch；legacy 只格式化目标内容并执行局部 patch。这排除了输出文本长度和当前探针记录的文本 SHA-256 差异作为主要解释，但 SHA-256 是否包含完整 text properties 仍需确认，不能把它直接当作 `equal-including-properties` 证明。

### Viewport resize

对同一 fixture 做 `900 → 720` resize：

- current 总耗时为 `12.447619s`，projection 起始阶段为 `11.305584s`，仍然调用 `ensure-node-tree` 1712 次并计算 1262 个 style。
- current 的 TP 统计只有 1 个 text operation、361 个 property operations，Ebox report 是 `owner-rerender`，dirty 为 1、scope 为 1。
- legacy 总耗时为 `0.404387s`，只渲染约 51 个局部节点；输出长度和 SHA-256 与 current 一致。

所以 `owner-rerender` 这个名称描述了最终 publication scope，不能证明前面的 layout、style、candidate 和 projection 也只处理了该 owner。严格 retained viewport checkpoint 在 evaluator fixture 上测得 `node-projection=2`、`TP-object-preparation=5` 和 `reconciled-objects=4`；这只是已经证明安全的子集，不代表所有 resize 路径都具有同样的 closure。

### 纯 `ebox-render`

在同一个 full fixture 上：

- current 总耗时为 `12.420715s`，其中 `ebox-surface--project` 为 `12.293075s`，projection 起始阶段为 `11.556190s`，`ecss-compute-style` 调用 1262 次、约 `9.34s`。
- current 的 `tp-surface-materialize-string` 本身几乎覆盖了整个总耗时，因为它调用了 retained surface 的构造路径。
- legacy 总耗时为 `0.710261s`，直接执行 layout/render，不建立等价的 TP surface projection。
- 两套实现的输出长度为 1183，SHA-256 完全一致。

这说明 current 的 `ebox-render` 虽然对调用者表现为“返回字符串”，内部却进入了 retained surface 构造路径。它证明了边界耦合存在，但不能仅凭聚合阶段证明 retained identity、binding 或 ownership graph 各自的独立成本。

### Stylesheet A/B

在一个没有 inline inheritance 的 300-box 树上：

| 条件 | 总耗时 | Ebox style calls | ECSS calls | 输出 |
| --- | ---: | ---: | ---: | --- |
| 无 stylesheet | 0.481574s | 0 | 0 | 与另一组长度和 SHA-256 一致 |
| 添加一条 `box` rule | 2.973969s | 301 | 301 | 与另一组长度和 SHA-256 一致 |

一条没有改变最终视觉输出的 stylesheet rule，就足以把静态树切换到 per-node cascade 计算路径。这表明 stylesheet active 是当前 style computation 扩散的重要开关，而不是只有实际样式变化时才付费。

动态 fixture 的触发条件是 inline inherited style，A/B fixture 的触发条件是 stylesheet rule；两者不是同一条触发路径。文档目前证明了两条路径都会进入 style computation，但还没有证明对两条路径使用同一种 snapshot/invalidation 修复就能得到相同收益。

当前三个 current 场景的总耗时为 `12.127969s`、`12.447619s` 和 `12.420715s`，变化小于 3%；legacy 对应为 `0.073844s`、`0.404387s` 和 `0.710261s`。这支持“current 存在与操作类型弱相关、与树规模强相关的固定全树成本”，但不能单独指出该成本来自 style、projection、candidate 还是 retained 构造。

## 已实现 checkpoint：隔离静态 materialization

第一个可逆的架构 slice 已经在一个窄场景下实现：source 没有 active stylesheet，且不需要 inline inherited-style 计算。此时 `ebox-render` 创建隔离的 candidate 和 render-side tables，然后直接运行 raw layout/materialization 路径，不再构造 retained TP object tree。需要 stylesheet 的 pure render，以及所有 mounted 路径，仍然使用 retained surface 路径。

声明的 evaluator 同时确认了优化结果和边界：

| 场景 | 耗时 | 相关阶段证据 | 正确性证据 |
| --- | ---: | --- | --- |
| Pure static | `0.047611s` | 没有 node-projection、TP-object-preparation 或 publication 阶段 | 隔离输出通过 `equal-including-properties` 与 TP-backed reference 相等 |
| Stylesheet pure | `0.171233s` | cascade 被执行；`ecss-compute-style` 调用 21 次 | TP-backed 输出等价性保持 |
| Mounted content update | `0.061124s` | node-projection 3 次，TP-object-preparation 5 次 | mounted identity 保持；`full-root=nil`，scope count 为 `2`；TP reconciles 4 个 object |
| Viewport resize | `0.044602s` | node-projection 28 次，TP-object-preparation 58 次 | root identity 保持；`full-root=nil`，scope count 为 `1`；TP reconciles 30 个 object |

同一个 evaluator 的较早对照是：slice 前 `0.037040s`，slice 后 `0.025286s`，约下降 32%。上表的新鲜数值是环境采样，不能替代相对 checkpoint。这个 slice 证明 pure static boundary 可以移除 retained projection 成本而不改变输出；它不能证明 mounted scoped update 的计算已经局部化。candidate handoff 边界已经在下节单独处理，但 projection 和 layout 仍需要继续收窄。

## 已实现 checkpoint：隔离 candidate handoff

Region 和 scroll update 现在会把已经隔离的 runtime candidate 继续传过 incremental planner 和 surface producer。这个内部 handoff 会跳过第二次 structural copy、declarative-root validation 和 runtime-identity reconciliation；viewport update 刻意不使用该标志，因为它从已发布 root 开始，仍需要普通 candidate 策略。

最新 evaluator 和 focused regression 的证据如下：

| 场景 | Candidate 证据 | 仍然存在的计算范围 | 正确性证据 |
| --- | --- | --- | --- |
| Mounted content update | 只进行一次 candidate structural copy；没有重复 validation 或 reconciliation | `ensure-node-tree` 0 次，node-projection 3 次，layout/fragment/ownership 4 次，TP-object-preparation 5 次 | surface tests 32/32；commit tests 4/4；带属性输出精确相等；mounted identity 保持；`full-root=nil`，scope count 为 `2`；TP reconciles 4 个 object |
| Scroll update | 隔离 candidate handoff 被接受，TP 合同未改变 | 尚无独立 scroll 阶段拆分 | surface regression 通过；TP revision/publication 行为保持有效 |
| Viewport resize | 已发布 root 的普通 candidate 路径保持不变 | `ensure-node-tree` 26 次，layout/fragment/ownership 7 次，TP-object-preparation 58 次 | 输出精确相等；root identity 保持；`full-root=nil`，scope count 为 `1`；TP reconciles 30 个 object |

这个 checkpoint 消除了重复的 candidate 生命周期。下面的 partial-line slice 又把一个稳定 owner 形状的 projection 和 layout 收窄了；更宽的 mounted 路径仍可能在最终 publication scope 之外建立 index、执行 projection、layout 和 ownership 构造。下一步实现必须推广 affected layout/projection closure，而不是回到 candidate helper 微优化。

## 已实现 checkpoint：partial-line scoped projection

Mounted span-patch 现在把 partial-line owner 视为一组已有的 parent slots，而不再要求该 owner 的 spans 连续。每个 slot 独立塑形；whole-line spans 仍保留 contiguous-span 安全证明。如果 span proof 失败，TP fallback 会复用已经准备好的 surface root、node root 和 object table，不再构造第二个 surface context。Paint-only update 会先确认 paint patch，再进行 span proof 和文本测量，因此仍留在 paint 路径。

span proof 成功后，mounted producer 会对已经证明不变的 node-object subtree 使用 TP 的 `tp-object-reuse-subtree`。candidate 仍携带完整 output plan 和 content-range attachments，但不变 subtree 不再进入 TP 的 touched/reconcile 集合。这不是通用的省略：如果 candidate topology、output footprint、parent slots、roles 或 overflow signature 变化，仍会回退到普通 projection/reconciliation 路径。

最新 evaluator 和 focused regression 的证据如下：

| 场景 | 范围证据 | 正确性证据 |
| --- | --- | --- |
| Mounted partial-row content update | `ensure-node-tree=0`，node-projection `3`，layout/fragment/ownership `4`，TP-object-preparation `5` | 耗时 `0.061124s`；`equal-including-properties`；mounted identity 保持；`full-root=nil`、scope count 为 `2`；策略为 `span-patch` |
| Mounted partial-row 路径的 TP retained bookkeeping | `reconciled-objects=4`，`created-objects=0`，`removed-objects=0` | 已证明不变的 subtree 被保留且不进入通用 reconciliation；scoped TP transaction 仍有效；没有 full-root fallback |
| Viewport resize 路径的 TP retained bookkeeping | `reconciled-objects=30`，`created-objects=0`，`removed-objects=0` | 普通 owner-rerender 路径正确且 publication 仍 scoped，但 retained closure 尚未收窄 |

这证明对于一个 partial-row update，affected-owner projection/layout 边界和 retained-object bookkeeping 都可以局部化。但它不证明所有 structural、flex、overflow、viewport 或 rollback-sensitive update 都能使用同样的 closure：当前 viewport owner-rerender 路径仍然 reconciles 30 个 objects。

## 已实现 checkpoint：严格 retained viewport reflow

Viewport change 现在有独立的 retained projection kind：`viewport-reflow`，但只在一个刻意收窄的 proof boundary 内启用。candidate 保留已发布 root，并复用 retained TP node-object table；producer 重新执行完整的 viewport-sensitive layout 和 surface plan，不调用 `ensure-node-tree`，也不把该操作伪装成 `span-patch`。之后仍由 TP 通过 retained root scope 发布变化后的输出。

Planner 只有在以下条件全部满足时才授权该路径：owner plan 是一个 root-owned geometry rerender；没有 dirty entry 修改 children；root、node-key set、region-id set 和 parent table 不变；旧 runtime 和当前 runtime 都不需要 ECSS cascade；没有 scroll state；整棵树没有 visible overflow；并且旧 surface 存在 retained node-object table。height-only 与 width-plus-height 变化使用同一套 proof。active stylesheet rule、inline inheritance、scroll state、visible overflow 和 publication failure 都有明确 regression case；这些情况会回退，或通过普通 TP transaction 回滚。

当前 evaluator 与 focused tests 给出的 checkpoint 如下：

| 场景 | 范围证据 | 正确性证据 |
| --- | --- | --- |
| evaluator fixture 的 viewport resize | `node-projection=2`、`layout/fragment/ownership=7`、`TP-object-preparation=5`、`ensure-node-tree=0`、`reconciled-objects=4` | 耗时 `0.080036s`；runtime output 精确相等；root identity 保持；`full-root=nil`、scope count 为 `1`；1 个 text operation |
| Height-only 与 both-axis resize | 使用 retained `viewport-reflow`；没有 node-tree ensure | `:viewport-axes` 分别为 `height` 和 `both`；输出宽度及 publication 正确 |
| 不安全 viewport 场景 | active stylesheet、inline inheritance、scroll 和 visible overflow 使用普通 projection | surface suite `39/39`；commit suite `4/4`；没有不安全场景被误标为 `viewport-reflow` |
| Viewport publication 失败 | 在 candidate preparation 后注入 TP publication failure | surface revision、signal values、client state、Ebox state 和 buffer text 都保持旧 generation |

这关闭了 evaluator fixture 上此前测得的 viewport 过度计算，但只在上述 proof boundary 内成立。更广的架构目标仍是为 flex、scroll、cascade、overflow 和 structural 场景建立 dependency-driven viewport damage closure，而不是凭猜测扩大这个 fast path。

## 已实现 checkpoint：fixed-footprint copy-on-write region candidate

Mounted content-only update 现在增加了一条刻意收窄的 candidate 路径。当更新是在固定 numeric width、没有 content child node、没有 active cascade、没有 scroll state 的 box 上替换字符串内容时，incremental layer 只复制 region owner 及其 ancestor path。Retained runtime table 通过 local index delta 准备，surface 收到显式的 path-copied 标记。这样 candidate preparation 仍由 Ebox 的 planning layer 负责，而 TP 继续拥有 mounted identity、scoped publication、revision 和 rollback。

这条路径只有在既有 span-patch identity/footprint proof 以及针对格式化替换内容的 line-count preflight 都通过后才会进入 surface。多行或可能 wrapping 的替换会在 surface projection 之前升级为普通 private structural copy。因此 surface 不会清除共享的 published node attachment，也不负责 emergency fallback copy。

| 场景 | 范围证据 | 正确性证据 |
| --- | --- | --- |
| Fixed-footprint mounted content update | 没有完整 `ebox--runtime-index`；evaluator 报告 node-projection `1`、layout/fragment/ownership `4`、TP-object-preparation `5`；focused regression 证明没有第二次完整 structural copy | `equal-including-properties`；target mounted identity 保持；`full-root=nil`、scope count 为 `2`；策略为 `span-patch`；evaluator 与 commit suite 通过 |
| 多行或扩宽替换 | line-count preflight 拒绝 path sharing，并在进入 surface projection 前升级为 private candidate | rollback regression 观察到 private copy，注入 publication failure 后旧 Ebox state、output 和 published content 均保持不变 |

这是 proof-bounded COW slice，不是通用 candidate policy。Structural、flex、overflow、cascade、scroll、viewport 以及其他会改变 footprint 的 update，在各自的 affected closure 和 rollback depth 被单独证明前，继续使用普通正确性路径。

## 当前验证边界

声明的 evaluator 在 2026-08-08 通过：`make performance-evaluator` 运行 surface tests 39/39、commit tests 4/4，四个场景的输出、identity、scoped publication 和不重叠阶段检查全部通过。Fixed-footprint mounted 场景保持了 `equal-including-properties`，保留 target object，并以 `full-root=nil`、scope count `2` 发布；viewport 场景以 `full-root=nil`、scope count `1` 和 `reconciled-objects=4` 发布。

较晚 COW checkpoint 之前的更宽 `make check` baseline 已通过：core 457/457、grid 15、commit 4、surface 32、visual-check 4、package 11、selector 22、DSL 25、flex 60、文档合约 4、CI 合约 4。当前 focused surface suite 为 39/39，覆盖 fixed-footprint COW fallback、height/both-axis 和 rollback。此前的回归已经关闭；performance goal 仍不能完成，因为更广的 viewport 和 mounted affected-closure proof 尚未完成。

## 已解决的验证回归

完整测试暴露的是两个生命周期边界错误，而不是测试期望值错误。第一，`ebox--render-ephemeral-static` 曾在函数内部把 `ebox--defer-scroll-content-index` 强制绑定为 nil，覆盖调用者的 deferred-scroll 合同并额外产生 sentinel/lookahead 行；现在已移除该局部覆盖，由调用者拥有这个模式。第二，`ebox-incremental-surface-batch-root` 在 batch flush 后仍返回最后一个 batch candidate，后续非 batch update 因而原地修改已发布 root；old/new box 发生别名，declarative dirty set 变空，scoped publication 最终拿不到 retained owner。现在只有 active batch 才能通过该 accessor 取得 candidate。两个回归都已通过，且没有增加 scope fallback 或改变既有行为期望。

## 测量口径与等价性限制

- `projection-start` 的起点和终点尚未定义；目前不能安全地用 projection 总时间减去 style 时间来计算“非 style projection 成本”。后续探针必须明确 candidate copy、style、layout、fragment、owner range、ledger、identity reconcile、retain 和 publication 各自的边界。
- `1712` 个节点、`1716` 个 reconciled objects、`1262` 个 style calls 和 300-box fixture 的 `301` 个 calls 的计数口径尚未解释；需要确认 root、wrapper、text leaf、跳过节点、缓存命中等是否包含在内。
- 较早的 partial-row checkpoint 报告 `ensure-node-tree=0`、node-projection `3`、layout/fragment/ownership `4` 和 TP `reconciled-objects=4`；当前 fixed-footprint mounted evaluator 报告 node-projection `1`、layout/fragment/ownership `4` 和 TP-object-preparation `5`，严格 retained viewport checkpoint 也报告 node-projection `1`、TP-object-preparation `5` 和 `reconciled-objects=4`。更广的 fallback 路径仍可能报告较旧的全树计数，因此必须把 Ebox projection scope 和 TP retained bookkeeping 分开测量。
- 历史 baseline probe 只记录了长度和 SHA-256，没有证明完整 text properties。当前 evaluator 已对 isolated 与 mounted 比较使用 `equal-including-properties`；后续 scope 变化必须保留这个断言。

## 根因排序

| 排名 | 根因 | 置信度 | 证据基础 |
| --- | --- | --- | --- |
| 1 | ECSS/reactive style cascade 按节点 eager recomputation | 高 | 动态更新中 `ecss-compute-style` 1262 次、约 8.99s；纯 render 约 9.34s；一条无视觉影响的 rule 触发 301 次 ECSS computation |
| 2 | Projection/`ensure-node-tree` 经常宽于 publication scope | 高 | 基线探针显示 projection 起始区间为 10.88s、11.31s、11.56s，并调用 `ensure-node-tree` 1712 次；partial-row 和严格 viewport checkpoint 已证明两个安全 closure 可以达到 `ensure-node-tree=0`，更广 fallback 路径仍未解决 |
| 3 | `ebox-render` 抽象边界错误 | 高 | [ebox-layout.el:1444](../../ebox-layout.el#L1444) 默认通过 `tp-surface-materialize-string`；纯字符串调用者仍支付 retained surface projection 成本 |
| 4 | 已证明路径之外的 candidate copy/index preparation 仍然宽于 publication scope | 中 | region/scroll 的重复 handoff 已移除，fixed-footprint region path 避免了完整 runtime index；更广的 content、structural 和 viewport 路径仍需要各自的 closure proof |
| 5 | Retained TP boundary 将 pure render、style、projection 和 mounted update 耦合到共同路径 | 中高 | 纯 render 进入 retained path 是事实；但现有数据不能把 coupling 等同于 TP identity/retain/publication 本身的最大耗时 |
| 6 | Ownership 被多层表示并重复扫描 | 中低 | fragments、owner ranges、TP plan、property ledger 和 text properties 都存在，但没有 ownership 构造/扫描的独立耗时证据 |
| 7 | 原始 layout 算法全面变慢 | 低 | 没有 stylesheet 的部分 flex fixture 中，current 首次 mount 约 1.4–1.5s，legacy 约 1.61–1.63s；不能支持“全面变慢” |

## 不能从现有证据推出的结论

- `ebox-surface--project` 和 `tp-surface-materialize-string` 是聚合阶段；它们覆盖 style、projection、fragment、ownership 和 TP 相关工作，不能直接当作 TP intrinsic cost。
- `property operations` 的数量（content update 为 378、resize 为 361）不是耗时；必须补充对应阶段计时后才能判断其性能贡献。
- legacy 只处理约 51 个 resize 节点，说明 current 的 scope 可能过大，但不能单独证明 51 是正确的最小受影响闭包。
- ownership 多层结构是值得验证的设计风险，但当前没有证明它们都被重复扫描，也没有证明它们可以安全合并。
- full-tree candidate/index preparation 可能是保守的正确性策略；只有建立 dependency closure、identity 和 rollback 证据后，才能确定哪些剩余全树工作是多余的。隔离 region 和 scroll candidate 的重复 copy/validation/reconciliation handoff 已经移除。

## 代码路径证据

current 的 retained 数据流由以下边界组成：

- [ebox-surface.el:535](../../ebox-surface.el#L535) 为整棵树建立 TP projection。
- [ebox-surface.el:712](../../ebox-surface.el#L712) 对 candidate root 做结构复制，[ebox-surface.el:725](../../ebox-surface.el#L725) 做 identity reconciliation。
- [ebox-surface.el:760](../../ebox-surface.el#L760) 为节点安装 style binding，[ebox-surface.el:775](../../ebox-surface.el#L775) 读取/应用 computed style。
- [ebox-surface.el:785](../../ebox-surface.el#L785) 递归执行 `tp-object-ensure` 和 `tp-object-retain`。
- [ebox-surface.el:1236](../../ebox-surface.el#L1236) 从 fragments 构造并 attach owner ranges。
- [ebox-surface.el:1269](../../ebox-surface.el#L1269) 把 fragments 转为 shared text leaf 和 TP surface plan。
- [ebox-surface.el:1627](../../ebox-surface.el#L1627) 根据 stylesheet active、inline inheritance 和 previous cascade state 决定是否进入 style-required 路径。
- [ebox-incremental.el:5235](../../ebox-incremental.el#L5235) 准备 candidate runtime、runtime index 和 dirty set。
- [ebox-incremental.el:5933](../../ebox-incremental.el#L5933) 的 scoped commit 有 isolated-candidate 分支复用已准备的 root，剩余 owner plan 决定下游 projection scope。
- [ebox.el:3486](../../ebox.el#L3486) 的 region update 最终通过 surface-scoped TP publication 发布。
- [ebox.el:3694](../../ebox.el#L3694) 的 buffer render 进入 surface mount；[ebox-surface.el:381](../../ebox-surface.el#L381) 创建 signals、producer 和 TP transaction。

legacy 的对应路径更接近“计算范围等于修改范围”：

- 历史 checkout 的 `ebox.el:7195` 直接修改目标 region box，并进入局部 dirty/patch 路径。
- 历史 checkout 的 `ebox.el:7399` 只格式化目标内容后执行局部 patch。
- 历史 checkout 的 `ebox.el:7578` 直接 render、insert 并刷新 marker/span。
- legacy 的 `ebox-style.el` 主要做本地属性展开和 dirty 分类，没有 current 的 ECSS stylesheet/reactive per-node cascade。

## Evidence 与 Inference 的边界

### Evidence

- current 的 projection、style、candidate 和 ownership 阶段在动态探针中占据绝大多数时间。
- current 与 legacy 在 content update、resize 和 pure render 的输出长度及 SHA-256 相同。
- current 的最终 TP text operation 数和 Ebox dirty owner 数很小，但全树前置阶段调用次数很大。
- stylesheet A/B 在输出不变时仍产生每节点 style/ECSS 调用。
- current 代码路径确实把 materialization、retained identity、style binding 和 TP publication 连接在同一条调用链上。
- current 三个场景总耗时近似恒定，而 legacy 随操作类型变化明显；这是全树固定成本存在的旁证，但不是某个内部阶段的独立计时。
- isolated candidate handoff 回归以一次 structural copy、零次重复 validation/reconciliation 通过；较早 partial-row checkpoint 把 mounted 场景降到 node-projection `3`，fixed-footprint COW checkpoint 现在测得 node-projection `1`、layout/fragment/ownership `4` 和 TP-object-preparation `5`；严格 viewport checkpoint 也测得 node-projection `1`、TP-object-preparation `5` 和 `reconciled-objects=4`。

### Inference

- 性能回退的主要问题是 computation scope 大于 publication scope，而不是最终 TP diff 本身效率不足。
- 当前 surface 已经 cascade-required 或需要 retained identity 时，静态/局部路径仍然承担了不必要的全树成本；其中 style cascade 和 projection 是目前最直接的测量瓶颈。
- pure render 和 mounted update 都受 retained coupling 影响，但它们不是同一个问题：前者应绕开 retained publication，后者应保留 identity/rollback 但缩小计算闭包。
- 只优化 `ecss-compute-style`、`tp-bind`、`ensure-node-tree` 或单个 helper，不会改变全树工作被安排在每条路径上的事实。
- 移除重复 candidate handoff 改善了生命周期边界，partial-row slice 又证明了 affected layout/projection closure 与 proof-driven TP subtree reuse；但 viewport 和更广 structural 路径仍然更宽，mounted 全面 scope proof 尚未完成。
- TP publication 仍然是正确性、identity、revision 和 rollback 的必要边界；证据支持的是延迟和缩小进入该边界的工作，而不是删除 TP。最终 publication 不是主要可观察瓶颈，但 TP retained 构造内部各阶段的独立贡献仍属 Unknown。

## 高层重构方向

目标是把数据流拆成两个有明确 ownership 的路径：

```text
Pure materialization
Source Tree
  -> style snapshot
  -> layout
  -> fragments
  -> propertized string

Mounted update
State mutation
  -> affected owner closure
  -> selective style/layout/paint
  -> reuse retained fragments/ranges
  -> TP publication
```

### 1. 分离 pure materialization 与 retained publication

当调用者只需要渲染字符串时，`ebox-render` 不应创建 TP identity graph、reactive binding、owner publication graph 或 rollback participant。只有 mounted surface 需要稳定 identity、scope proof、revision 或 rollback 时，才进入 retained publication 边界。

分离点应位于 publication boundary 之后、fragment/layout 的单一实现之后；pure path 和 retained path 必须共享 style snapshot、layout 和 fragment 生成逻辑，避免为了性能形成两套渲染语义。若存在“先 pure render 预览、后 mount”的流程，mount 时必须明确 identity promotion 或允许一次完整 attach，不能隐式复用 ephemeral object。

### 2. 把 style/cascade 变成 snapshot，而不是默认 per-node reactive binding

静态 inline style 应直接进入 computed-style snapshot。只有真正依赖外部动态值的节点才安装 reactive binding。继承样式失效应由 ancestor/subtree dependency 定位受影响范围，而不是因为某个 surface 进入 cascade-required 状态就让整棵树重新计算。

style snapshot 的正式实施必须先通过 dependency correctness gate：对 stylesheet 和 inline inheritance 两条触发路径分别记录真实读取的 style inputs，并比较预测 affected set 与全量重算结果，既检查欠失效也检查过失效。snapshot 化本身不会自动带来局部性；dependency graph 若仍按全树保守建立，收益仍会被全树失效抵消。

### 3. 统一 ownership 表示

layout 阶段应生成结构化 fragment/owner map，并让 unchanged fragments、ranges 和属性状态可以复用。局部 patch 不应重新扫描完整 rendered string，也不应为未变化节点重新构造 owner ranges、shared leaves 和 property ledger。

### 4. Candidate 采用 copy-on-write

fixed-footprint mounted content slice 已经在一个经过证明的字符串替换形状上实现了这条策略：只复制受影响的 owner path，并把 sharing 决策显式传给 surface。普通 content/paint update 只有在同样的 proof 存在时才能沿用这一模式。结构变化、几何变化、identity 变化或确实需要扩大 rollback/scope proof 时，才构造更大的 candidate。rollback 应保留在 publication boundary，而不是让所有更新提前支付全树隔离成本。

scoped candidate 的 closure 不能等同于语法上的 owner 子树；文本变长、flex 兄弟、百分比和容器约束可能使 layout context closure 更大。COW 还需要明确 rollback depth 和旧 root 的生命周期，避免长期编辑会话因保留每一代 root 而产生无界内存增长。

### 5. 保留 TP 的正确性职责，但收窄其进入条件

TP 继续负责 live buffer publication、diff、revision、stable retained identity 和 rollback。架构修复不是绕过 TP，而是让 pure render 不进入 TP，让 mounted update 只把受影响的结构和 ownership 交给 TP。

## 问题拆分与推荐顺序

| 阶段 | 应解决的问题 | 不应混入的问题 |
| --- | --- | --- |
| Pure render | 字符串 materialization 不应创建 retained identity、binding 或 publication graph | mounted update 的 rollback 和 stable identity |
| Mounted content update | dirty owner 的 computation closure 不应扩张为全树 | viewport damage 的特殊几何依赖 |
| Style cascade | 只重算真实受影响的 style dependency closure | TP property publication 优化 |
| Viewport resize | 建立 viewport damage region 和 affected layout closure | 把 legacy 的 51 个节点直接当作正确答案 |
| Candidate/ownership | 在 dependency closure 稳定后复用 unchanged state | 尚未计时就假定所有 ownership 结构都重复 |

建议按以下顺序推进：

1. P0a：保留 evaluator 和阶段探针作为合同。当前探针已经确认 text-property 级输出等价性和不重叠的聚合阶段；candidate preparation 已单独计时，isolated handoff slice 也证明可以在不改变 publication 语义的情况下移除重复 copy/validation/reconciliation。
2. P0b：建立 style dependency correctness gate，分别覆盖 stylesheet 和 inline inheritance；在契约测试通过前，不正式缩小 style invalidation。
3. P0c：无 stylesheet、无 inline-inheritance 的 slice 已完成：隔离 pure materialization 已实现并通过 evaluator。需要 stylesheet 的 pure render 仍应作为独立未解决路径，直到 style snapshot 的依赖合同得到证明。
4. P0d：在 dependency gate 和 pure spike 有结果后运行完整 2×2 实验，再决定 style snapshot、retained 瘦身和 scoped projection 的正式顺序。
5. P1：将已经实现的 partial-line scoped projection、fixed-footprint COW region candidate、严格 retained viewport reflow、affected-layout closure 和 proof-driven TP subtree reuse 推广到 stable content、flex、overflow、cascade 及 rollback-sensitive 路径。Fixed-footprint evaluator 记录 node-projection `1`、layout/fragment/ownership `4` 和 TP-object-preparation `5`；严格 viewport fixture 记录 node-projection `1`、TP-object-preparation `5` 和 TP `reconciled-objects=4`，更广 fallback 路径仍待测量。
6. P1：在严格 proof subset 之外，为 viewport resize 建立独立 damage region 和 affected layout closure，并逆向记录 legacy 的局部 dirty/布局闭包作为参照。
7. P2：只有在 dependency、identity、scope proof 和 rollback 合同稳定后，才能把 COW 和 ownership reuse 推广到 fixed-footprint proof 之外，并明确 rollback depth/内存策略。
8. P2：最后评估 TP property operations；不要在 pre-publication 成本未下降前把它作为主攻方向。

## 最小判别性实验：2×2 根因分离

这是进入正式实现前最有价值的实验，但需要先完成 P0c 的只读 pure-materialization spike。两个因子分别是 retained path 和 style 计算模式：

| | Reactive style | Style snapshot |
| --- | --- | --- |
| Retained path on | 当前 mounted 基线 | 只替换 style 计算策略 |
| Retained path off | pure materialization 基线 | pure materialization + snapshot |

在 `dynamic-update-reference.ebox` 和 300-box stylesheet A/B fixture 上，每组记录总耗时、style calls、`ensure-node-tree` 次数、reconciled objects、TP identity/retain 次数、owner range 构造耗时、text/property operations、输出长度和 SHA-256。

- 如果关闭 retained path 后 pure render 大幅下降，说明 `ebox-render` 边界错误是重要原因。
- 如果关闭 retained path 后 style calls 仍为 1262，说明 style cascade 是独立根因。
- 如果 snapshot 使 style calls 和总耗时显著下降，说明 cascade invalidation 是主因之一。
- 如果两者都降低后仍远高于 legacy，继续拆分 projection、candidate、ownership 和 layout。

该实验中的“关闭 retained path”只适用于 pure materialization 或只读实验路径；mounted update 不能删除 stable identity、rollback 或 scope proof。

建议的最小执行序列是：先完成纯测量阶段拆分；再用 read-tracking 验证 stylesheet/inline inheritance 的 dependency closure；然后只切换 reactive style 下的 retained on/off；最后在 dependency gate 通过后运行完整四格矩阵。这样不会把实验基础设施和正式重构互相循环依赖。

## 目标架构的验证边界

在实现任何重构前，目标架构至少应满足以下可观测性质：

- pure `ebox-render` 不创建 TP retained identity、surface binding 或 publication graph。
- 没有结构、几何或样式依赖变化的 content/paint update，不重新投影整棵树。
- stylesheet active 不再自动等价于所有节点都必须重新计算；只有受影响的 cascade dependency 才失效。
- 局部 update 的 `ensure-node-tree`、reconciled objects 和 style calls 应随 affected closure 变化，而不是固定等于全树规模。
- `owner-rerender`、`span-patch` 和 `paint-patch` 的 computation scope 与 publication scope 不再背离到全树级别。
- 结构变化、viewport geometry 变化和需要 rollback 的更新仍能扩大 scope，并保留现有 stable identity、TP transaction 和失败回滚语义。
- retained `viewport-reflow` 只有在 topology、cascade、scroll、overflow 和 owner-scope proof 全部通过后才会选择；其他 viewport change 使用普通正确性路径。
- scoped style 必须与全量重算在 computed-style 结果（包含 text properties 相关输入）上等价，且同时覆盖 stylesheet 与 inline inheritance 触发器。
- scoped candidate 必须有明确的 affected-closure proof、旧 root rollback 语义和有限的 rollback/memory retention 策略。

## Unknowns 与限制

- legacy 没有等价的 ECSS stylesheet/reactive cascade，因此目前不能把两套实现的全部耗时严格按 cascade、layout、ownership 进行一一归因。
- scroll offset、paint-only update 和 batch update 尚未完成同等阶段拆分；当前结论主要由 content update、viewport resize、pure render 和 stylesheet A/B 支撑。
- 哪些 ownership/index 结构可以合并，同时不破坏 stable identity、rollback 和 TP scope proof，需要后续通过只读阶段探针和契约测试确认。
- style snapshot 必须覆盖 theme、ancestor、selector、viewport、face 和其他动态输入的 dependency closure；否则会以性能换取错误渲染。
- COW candidate 是否安全取决于 stable identity 不依赖对象地址、commit 前 retained state 不可变，以及旧 root/旧 ledger 可用于 rollback。
- content update 的 closure 可能包含 layout context 和兄弟节点，不能只按 dirty owner 子树裁剪；legacy 的 dirty 传播应作为参照证据逆向记录。
- scope proof 当前是检查驱动还是构造驱动尚未确定；若原先依靠全树 candidate 获得安全性，scoped/COW 后必须补显式 proof 机制。
- 绝对耗时受本地 Emacs、显示环境和电源状态影响；本记录使用相同环境下的相对阶段结构和相同输出校验作为主要依据。

## 2026-08-09 flex resize checkpoint

在撤销一次 viewport-dependent generic-cache override 实验后，重新运行了唯一的 public GUI evaluator：`ebox-playground/examples/flex-reference.ebox`。一次真实 `window-resize` 将 preview viewport 从 `256` 改为 `186` 像素，端到端耗时 `1.202837s`，其中 `ebox-rerender-buffer-with-context` 为 `0.748485s`。Preview mount、恰好一次 update、scoped publication、保留的 `viewport-reflow-mixed-scroll`（`reconciled=4`、`full-root=nil`、`scope-fallback=nil`）、与 fresh render 的视觉/text-property 等价性，以及 canvas background 检查全部通过；声明的 `0.5s` 门槛失败。这是当前验收结果，不能称为毫秒级。

同一条路径的阶段探针会因 advice 产生测量开销，因此数值只用于方向判断，但已经明确了成本中心：最干净的一次样本中 candidate rendering/materialization 约 `0.38s`，root path 调用了 `142` 次 `ebox--render-layout`。探针观察到 `80` 次 generic cache probe，其中只有 `2` 次命中、`78` 次 no-context；fragment retention 为 `8` 次命中、`37` 次 rerender、`15` 次 store。该样本中 TP 的 snapshot/render/publication 不是独立的主耗时（`tp-text-snapshot` 约 `0.06s`）；TP 仍然是必须保留的 identity/publication/rollback 边界。

Sol xhigh 的架构审查否决了扩大 generic viewport cacheability 或修改现有 fragment key 作为安全修复：retention lookup 发生在 child measurement 和 Flex reflow 之后，即使命中也不能跳过父级 reflow 或最终 owner/range materialization。下一步真正的 owning boundary 是结构化的 `layout -> fragment/owner result` handoff。可复用结果需要携带 dimensions、owner/property runs，以及局部 containing-block/display signature；之后 `ebox-surface` 才能直接消费这些 runs，不再扫描完整的 propertized string。更大的 slice 必须继续保留 candidate COW、rollback、scoped publication 和与 fresh render 的精确等价性。

当前 focused checks 仍然有价值，但不能关闭门槛：Ebox Flex `62/62`、Ebox surface `49/49`，且唯一 evaluator 的正确性检查通过。更广的 core run 在已经很脏的 worktree 中仍有两个已知失败（shrunk definite-item slot count 与 underfilled chrome mapline count）；这里将它们记录为回归缺口，不把它们悄悄归因于本 checkpoint。临时 probe daemon 和生产 cache override 都已清理。

## 记录边界

本文固定根因模型和高层数据流方向，记录了五个已验证的窄实现 slice，但不授权 benchmark 特判、timing hack、松动性能门槛或针对单一 fixture 的缓存分支。剩余 ownership 和 publication 边界仍必须转成可验证的设计合同，再逐步修改代码。
