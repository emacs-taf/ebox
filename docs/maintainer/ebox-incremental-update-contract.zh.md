# Ebox 增量更新合同

本文定义底层发布合同。它独立于 ETAF 应用状态，直接使用 Ebox 的调用者和上层包都必须遵守。

## 所有权

1. 调用者拥有新的 source tree。
2. `ebox-tree.el` 拥有 identity、key、遍历和 snapshot。
3. `ebox-style.el`、`ebox-measure.el` 与布局模块拥有归一化、测量和几何。
4. `ebox-incremental.el` 拥有 dirty 分类、patch 规划、纯声明式 commit 准备和 Ebox 报告语义。
5. `ebox-surface.el` 投影 retained candidate，并让 Ebox runtime-state 发布加入 TP transaction。
6. TP 拥有首次 mount、声明式 commit、handle 更新、viewport/theme 更新和 scroll 更新的通用 retained-surface reconciliation、mount/index 状态、全部 live buffer diff 执行、revision 变更和 rollback。
7. `ebox-buffer-backend.el` 只构造和整形带文本属性的渲染字符串，不拥有 live marker 或 buffer mutation executor。

任何层都不能从可见 buffer 文本推断应用状态；公共调用者不能原地修改已经发布的树。每条公共 live 发布路径，包括 `ebox-render-to-buffer`、其展示包装 `ebox-display-buffer` 以及 commit/update 入口，都使用 retained TP surface；公共门面不再提供擦除 buffer 后执行任意 BODY 的 writer。

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

规划器优先使用 `paint-patch`，再使用 `span-patch`、`owner-rerender`，最后在几何或 identity 使小操作不安全时使用 `root-rerender`。这些名称描述的是 Ebox 的语义 owner 范围；只有 TP 负责计算并执行物理文本/属性 diff。Patch 不得静默扩大语义范围。报告保留 Ebox strategy 与 planned scope，同时单独记录 TP 的实际 surface operation 和 revision。

## 严格 retained viewport reflow

`viewport-reflow` 是一个明确的 retained projection kind，只用于范围很窄、由 proof 驱动的 viewport resize 路径。只有以下条件全部满足时，规划器才能选择它：plan 是一个 root-owned geometry `owner-rerender`；旧 root 与 candidate root 是同一个 retained root；没有 dirty entry 修改 children；node-key set、region-id set 和 parent table 都不变；旧 surface 和当前 style environment 都不需要 cascade 或 inline-inheritance 重新计算；没有 scroll state；root 没有 visible-overflow scope；旧 surface 存在非空 retained node-object table。仅改变 width、仅改变 height 以及同时改变两个轴使用同一套 proof。

选择该路径后，candidate 保留已发布的 Ebox topology，并复用 retained TP node-object subtree。Producer 仍会重新执行 viewport-sensitive layout 并生成新的 surface plan；TP 继续负责 scoped buffer diff、revision、stable identity 和原子 rollback。即使最终文本 patch 很小，topology、cascade、inheritance、scroll、overflow 或 display-signature 变化也不能报告为 `viewport-reflow`。

任意 proof 条件失败时，更新必须使用普通安全 projection 路径。该 fallback 可以执行更宽的 node projection 和 TP reconciliation，但必须保持相同的输出、identity、publication 和 rollback 合同。`tests/ebox-surface-tests.el` 覆盖 retained width/height/both-axis 路径、每个不安全 fallback 触发条件，以及 candidate preparation 之后的 publication failure。

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
