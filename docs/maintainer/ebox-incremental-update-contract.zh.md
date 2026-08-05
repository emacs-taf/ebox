# Ebox 增量更新合同

本文定义底层发布合同。它独立于 ETAF 应用状态，直接使用 Ebox 的调用者和上层包都必须遵守。

## 所有权

1. 调用者拥有新的 source tree。
2. `ebox-tree.el` 拥有 identity、key、遍历和 snapshot。
3. `ebox-style.el`、`ebox-measure.el` 与布局模块拥有归一化、测量和几何。
4. `ebox-incremental.el` 拥有 dirty 分类、patch 规划、候选发布和更新报告。
5. `ebox-buffer-backend.el` 是 text property 与 buffer 变更的唯一 owner。

任何层都不能从可见 buffer 文本推断应用状态；公共调用者不能原地修改已经发布的树。

## Commit 生命周期

```text
新的根树
  -> 校验与归一化
  -> reconciliation key 与 identity
  -> 测量/布局候选
  -> 分类 dirty owner
  -> 渲染候选 span
  -> 原子发布
  -> 刷新 snapshot 与报告
```

候选要么完整发布，要么丢弃。候选失败时必须保留之前的 buffer 文本、属性、runtime identity、滚动状态和最近一次成功报告。

## Patch 顺序

规划器优先使用 `paint-patch`，再使用 `span-patch`、`owner-rerender`，最后在几何或 identity 使小操作不安全时使用 `root-rerender`。Patch 不得静默扩大范围；报告要记录策略、dirty key、owner 和 patch 操作。

## Identity 与坐标

Key 只在同级兄弟集合内有效。Region 与 host-ref 位置绑定于 generation；buffer 变更后调用者必须通过公共 accessor 重新获得位置。Buffer marker、display span 和 text property 是 backend 事实，不是 source tree identity。

## 验证

每条更新路径都要验证：

- 发布后的可见文本和属性完全正确；
- 兄弟节点重排时 keyed identity 稳定；
- rollback 后没有候选数据残留；
- 可以局部更新时 patch 范围受控；
- native reflow 不可用时 fallback 正确。

聚焦测试使用 `tests/ebox-commit-tests.el`、`tests/ebox-core-render-tests.el` 和 `tests/ebox-grid-tests.el`，然后运行 `make check`。
