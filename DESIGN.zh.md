# Ebox 设计

Ebox 是底层渲染引擎。它负责把声明式节点树转换为经过测量的布局 fragment，再发布到 Emacs buffer。它有意小于应用框架。

## 设计原则

- 一棵 source tree、一套样式归一化、一条布局流水线、一个 buffer owner。
- 公共节点是数据；只有显式入口负责渲染与变更。
- 稳定 identity 来自节点 identity 和显式 key，不来自可见文本或 selector 字符串。
- 布局变化先测量再发布；候选发布失败时保留上一个 buffer 状态。
- native 模块只是可选加速器，必须有完全等价的 Elisp fallback。
- 新抽象必须消除重复，或让已有的公共工作流更简单。

## 流水线

```text
节点树
  -> 归一化样式
  -> 经过测量的 formatting context
  -> 布局 fragment 与 snapshot
  -> render context
  -> buffer patch/发布
```

各层 owner 是：`ebox-tree.el` 负责 identity 与遍历，`ebox-style.el` 负责样式语义，`ebox-measure.el` 负责 display 敏感测量，`ebox-layout.el`、`ebox-flex.el`、`ebox-grid.el` 负责几何，`ebox-fragment.el` 负责 fragment 事实，`ebox-buffer-backend.el` 负责 text property 与 buffer 编辑，`ebox-incremental.el` 负责 dirty 规划与发布。

## 公共边界

使用 `ebox-create`、`ebox-column`、`ebox-row`、`ebox-flex`、`ebox-grid`、`ebox-build`、`ebox-render`、`ebox-render-to-buffer`、`ebox-commit` 以及 selector 入口。应用和同级包不得调用 `ebox--*` 私有名称。更高层的 Component、响应式、behavior、data 和 control 概念属于 ETAF。

## 布局范围

Ebox 支持字符和像素尺寸、padding、margin、border、颜色、face、overflow、换行、row/column/flex formatting，以及固定、分数、隐式、gap、放置、span 和对齐等 Grid 能力。CSS 兼容性有意是部分实现：浏览器 cascade、百分比、绝对定位、z-index、阴影、完整 typography 和浏览器级 bidi 不属于本包。

## 验证规则

每个行为修改都要补充聚焦的 ERT 测试，并运行新的 `make check`。修改 native 源码还要运行 `make native-rust-tests`；修改文档或 active 文件集合还要运行 `make docs-contract-tests`。
