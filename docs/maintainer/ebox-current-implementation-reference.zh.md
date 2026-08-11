# Ebox 当前实现参考

本文是独立 Ebox 仓库的维护者入口，描述包边界、active 文件、运行时模型、不变量和验证命令。历史 `emacs-box` 是另一个旧架构源码树，不是本包依赖。ETAF 是同级高层包。

## 阅读顺序

1. 先读 `AGENTS.md` 了解仓库规则。
2. 读 `README.md` 了解安装和公共边界。
3. 读 `docs/user/ebox-user-guide.zh.md` 了解公共构造方式。
4. 读 `docs/user/ebox-api-reference.zh.md` 了解完整的公共函数/property/配置清单。
5. 读本文了解所有权和验证方式。
6. 修改发布或 patch 规划前，读 `docs/maintainer/ebox-incremental-update-contract.zh.md`。
7. 修改性能、retained surface 或增量数据流前，读 `docs/maintainer/ebox-performance-architecture-analysis.zh.md`。

## Active 源码清单

| 文件 | 负责内容 |
| --- | --- |
| `ebox.el` | 公共门面、构造辅助函数、渲染、基于 TP 的 buffer 入口、滚动、commit 与 byte compile。 |
| `ebox-cache.el` | 测量/渲染缓存记录、失效和缓存报告。 |
| `ebox-style.el` | ECSS property schema、declaration 与 cascade、shorthand 展开、computed style、颜色、border 和 dirty effect。 |
| `ebox-tree.el` | 节点遍历、逻辑子节点访问、ECSS subject 适配、identity、父路径、key 和树 snapshot。 |
| `ebox-measure.el` | display 敏感的字符、face、像素测量与测量缓存。 |
| `ebox-fragment.el` | 布局 fragment、signature、snapshot、span 和 dirty kind 事实。 |
| `ebox-render-context.el` | render-local context 与发布输入。 |
| `ebox-layout.el` | box、row、column、stack、concat、spacer、换行和通用 formatting context。 |
| `ebox-flex.el` | flex 归一化、line、剩余空间分配和 flex 渲染。 |
| `ebox-grid.el` | 轨道、隐式轨道、分数、minmax/repeat、gap、placement、span 和对齐。 |
| `ebox-surface.el` | 候选 identity、向 TP surface plan 的投影、retained mount/update，以及支持 rollback 的 Ebox runtime-state participant。 |
| `ebox-buffer-backend.el` | 带文本属性的渲染字符串构造、display space/border 与既有 slot 整形。 |
| `ebox-incremental.el` | runtime、snapshot、dirty 规划、owner 提升、纯 commit 准备和报告。 |
| `ebox-dsl.el` | 数据型 `.ebox` form，以及向公共节点的 lowering。 |
| `ebox-selector.el` | 把 CSS-like 字符串解析为 ECSS structured selector AST，利用索引缩小候选，并返回 tree/runtime query handle。 |
| `ebox-native-reflow.el` | 可选 native 模块加载/构建、ABI 校验、受限 session 和 Elisp fallback。 |

本包有意不包含应用 Component、UI control、响应式 data 或 playground 实现；它们属于同级包。历史应用性能记录器和 native reflow 评估器也不属于独立 Ebox 的发布边界；Ebox 只保留 native 模块本身、Rust 构建输入和可重复的构建检查。

active 合同还覆盖 `Makefile`、`.github/workflows/ci.yml`、`tests/ebox-core-render-tests.el`、`tests/ebox-grid-tests.el`、`tests/ebox-commit-tests.el`、`tests/ebox-surface-tests.el`、`tests/ebox-dsl-tests.el`、`tests/ebox-flex-tests.el`、`tests/ebox-selector-tests.el`、`tests/ebox-package-tests.el`、`tests/ebox-visual-check-tests.el`、`tests/ebox-docs-contract-tests.el`、`tests/ebox-ci-contract-tests.el`、`native/Cargo.toml`、`native/Cargo.lock`、`native/build.rs`、`native/vendor/emacs-30/emacs-module.h`、`native/src/lib.rs`、`native/src/layout.rs`、`native/c/ebox_module.c`、`scripts/ebox-package-lint.el`、`scripts/ebox-visual-check.el` 和 `scripts/ebox-performance-evaluator.el`。

## 运行时模型

正常数据流是：

```text
调用者拥有的 Source Tree
  -> Surface 拥有的 Runtime Copy
  -> TP Candidate Objects
  -> Element Tree
  -> Computed Style
  -> Box/Formatting Context
  -> Measurement + Render Context
  -> Layout Fragment/Snapshot
  -> Ebox Dirty/Patch Plan
  -> TP Surface Plan
  -> TP 原子发布
  -> Ebox Runtime-State Participant
```

| 模型 | Owner | 不得拥有 |
| --- | --- | --- |
| Source/Element Tree | `ebox-tree.el`、`ebox-dsl.el` | 已发布 buffer 的变更。 |
| Computed Style | `ebox-style.el` | 布局 identity 或 patch 执行。 |
| Measurement | `ebox-measure.el` | 应用状态或 dirty 策略。 |
| Formatting Context | `ebox-layout.el`、`ebox-flex.el`、`ebox-grid.el` | Buffer 编辑。 |
| Fragment/Snapshot | `ebox-fragment.el`、`ebox-incremental.el` | Source parsing 或 identity 分配。 |
| Surface 投影与 Runtime 发布 | `ebox-surface.el` 加公共 TP surface API | Ebox 布局决策或通用 diff 执行。 |
| Dirty/Patch 语义 | `ebox-incremental.el` | 原始测量或 TP buffer 写入。 |
| 通用 Surface Diff/Commit | TP | Ebox 几何、dirty 策略或应用状态。 |
| 渲染字符串 Backend | `ebox-buffer-backend.el` | Live buffer 写入、retained marker、样式语义或应用状态。 |

## 不变量

- 公共 Ebox 节点是数据；`ebox--*` 名称是私有实现。
- `'(420)` 这样的单元素横向 list 表示像素；普通横向数字表示字符列。
- `ebox-render` 使用临时 TP surface，不发布到 buffer；`ebox-render-to-buffer` 挂载 retained TP surface；`ebox-display-buffer` 展示的也是这条 retained-surface 路径；`ebox-commit` 准备 Ebox 语义后通过 TP 更新该 mount。Ebox 不再公开另一套擦除 live buffer 后执行任意 BODY 的宏。
- 声明式输入始终由调用者拥有。live mount/commit 只在 surface-owned copy 上分配 identity，因此同一 source 可以挂载到多个 buffer。
- 逻辑 `:id` 通过 `ebox-region-resolve` 解析为不透明、surface-scoped 的 handle；同一逻辑 region 挂载到多个 buffer 时，由 handle 而不是 source-tree 数字 id 区分。
- 候选失败时必须保留之前的 buffer、runtime identity 和报告。
- Key 只在兄弟节点中有效；不能用可见字符串作为 identity。
- Ebox 只拥有逻辑 node-to-subject 适配与 id/class/type 候选索引；ECSS 的公共结构化 matcher 是唯一 selector 真相源。subject 只暴露内建 id/key 和显式 `:selector-attributes`，绝不暴露可见 content、布局状态或 runtime 容器。
- `owner-rerender` 范围大于 `span-patch`，`span-patch` 大于 `paint-patch`。
- Buffer 坐标属于生成它的 generation，变更后必须重新获取。
- Grid 使用普通测量与渲染流水线；native reflow 可以拒绝不适合的树并回退到 Elisp，正确性不变。
- 加载 Ebox 不会构建或安装可选 Rust 模块。
- Phase 9 已完成：首次 mount、声明式 commit、handle/selector 更新、viewport/theme 更新、batch flush 与 scroll 更新全部通过 TP surface 发布。Phase 10 已把 selector 解析、匹配与 cascade 统一到 ECSS；Ebox 只计算 dirty/layout owner，并让不透明 runtime state 参与 TP 的可 rollback transaction，不存在第二个 live buffer executor。
- 成功报告会保留 Ebox 语义 strategy 与 planned publication scope，再加入 `:publication-scope tp-surface`、TP 物理 operation 数、surface revision、scoped/full-root 事实和 retained-object reconciliation 统计。

## Grid 合同

当前 Grid 支持固定和像素轨道、`auto`、分数轨道、`minmax`、`repeat`、隐式行列、行列 gap、auto-flow、从 1 开始的 placement、正整数 span、item/content 对齐，以及普通 buffer 渲染和更新。Ebox 支持有限 typography 子集（`:font`、`:font-family`、`:font-height`/`:font-size`、`:font-weight` 和 `:font-slant`）；完整浏览器 typography 不在合同内。百分比、绝对定位、z-index、圆角、阴影和浏览器级 bidi 也不在合同内。

## Active 示例与测试

独立 Ebox 包不再内置 playground fixture。迁移后的 `.ebox` 参考文件及其运行器位于同级 `ebox-playground` 包；本仓库直接测试 DSL 与布局原语。回归边界是 `tests/` 下由文档合同列出的 ERT 文件。本包测试不得加载历史全栈源码树或应用框架。

## 验证矩阵

```sh
make check
make core-tests
make grid-tests
make ebox-commit-tests
make surface-tests
make visual-check-tests
make package-tests
make selector-tests
make dsl-tests
make flex-tests
make docs-contract-tests
make ci-contract-tests
make performance-evaluator
make visual-check
make native-rust-tests
make native-build
make package-lint
make diff-check
```

先运行聚焦测试；修改共享渲染、Grid、公共构造器或文档后运行 `make check`。修改 native 后必须运行 Rust 检查与 native 构建。
