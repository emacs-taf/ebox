# Ebox 设计

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

使用 `docs/user/ebox-api-reference.zh.md` 中的函数与 property；门面清单是 `ebox-public-api`。应用和同级包不得调用 `ebox--*` 私有名称。更高层的 Component、响应式、behavior、data 和 control 概念属于 ETAF。

## 布局范围

Ebox 支持显式 `px`、`%`、`vw`、`vh`、`ch`、`lh` 尺寸、padding、margin、border、颜色、overflow、换行、row/column/flex formatting，以及固定、分数、隐式、gap、放置、span 和对齐等 Grid 能力。公共 typography 子集是 `:font-family`、以 CSS reference pixel 表示的 `:font-size`、`:font-weight` 和 `:font-style`；`:font-slant` 只是 `:font-style` 的精确 parse-time alias。Emacs face 与文本属性只属于最终 adapter，不是 Ebox 作者属性。CSS 兼容性有意是部分实现：绝对定位、z-index、阴影、border radius、完整浏览器 typography 和浏览器级 bidi 不属于本包。

## 尺寸组合

`ebox-size.el` 负责长度验证、依赖识别、浮点像素换算，并提供累计量化的纯函数，
供布局在选定的显示边界调用。上下文显式传入视口两轴、
该属性的百分比参照、`0` 字形前进宽度和行高；模块不读取窗口或节点，不求值任意
Lisp，不选择属性默认值，也不发布 buffer。Normal、Flex、Grid、间距和边框几何
由此复用同一套单位运算。

作者格式为 `(单位 数值)`，可组合函数是 `calc`、`min`、`max`、`clamp`。
property schema 负责允许的单位、关键词和值域。[统一单位约束表](docs/user/ebox-user-guide.zh.md#size-unit-constraints)
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

每个行为修改都要补充聚焦的 ERT 测试，并运行新的 `make check`。修改 native 源码还要运行 `make native-rust-tests`；修改文档或 active 文件集合还要运行 `make docs-contract-tests`。
