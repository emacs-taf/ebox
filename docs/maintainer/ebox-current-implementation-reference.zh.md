# Ebox 当前实现参考

本文是独立 Ebox 仓库的维护者入口，描述包边界、active 文件、运行时模型、不变量和验证命令。历史 Ebox checkout 是另一个旧架构源码树，不是本包依赖。ETAF 是同级高层包。

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
| `ebox-source.el` | opaque source handle、不可变 author source record 与 candidate source index。 |
| `ebox-state-contract.el` | 封闭的 retained-state 所有权清单与只读 compatibility-mirror 重建探针。 |
| `ebox-style.el` | ECSS property schema、declaration 与 cascade、shorthand 展开、computed style、颜色、border 和 dirty effect。 |
| `ebox-tree.el` | 节点遍历、逻辑子节点访问、ECSS subject 适配、identity、父路径、key 和树 snapshot。 |
| `ebox-child-range.el` | 不可变 weighted segment trie、稀疏持久 key trie、Range replacement 与 Gate A metrics。 |
| `ebox-measure.el` | display 敏感的字符、face、像素测量与测量缓存。 |
| `ebox-fragment.el` | 布局 fragment、signature、snapshot、span 和 dirty kind 事实。 |
| `ebox-render-context.el` | render-local 值与注入的 candidate/materialization 输入 port。 |
| `ebox-layout.el` | box、row、column、stack、concat、spacer、换行和通用 formatting context。 |
| `ebox-flex.el` | flex 归一化、line、剩余空间分配和 flex 渲染。 |
| `ebox-grid.el` | 轨道、隐式轨道、分数、minmax/repeat、gap、placement、span 和对齐。 |
| `ebox-surface.el` | 候选 identity、向 TP surface plan 的投影、retained mount/update，以及支持 rollback 的 Ebox runtime-state participant。 |
| `ebox-buffer-backend.el` | 带文本属性的渲染字符串构造、display space/border 与既有 slot 整形。 |
| `ebox-patch-plan.el` | 从不可变 parent fact 生成 tentative operation antichain 的纯规划。 |
| `ebox-incremental.el` | runtime、snapshot、dirty 规划、owner 提升、纯 commit 准备和报告。 |
| `ebox-dsl.el` | 数据型 `.ebox` form，以及向公共节点的 lowering。 |
| `ebox-selector.el` | 把 CSS-like 字符串解析为 ECSS structured selector AST，利用索引缩小候选，并返回 tree/runtime query handle。 |
| `ebox-spi.el` | Additive immutable framework SPI v2 provider 及 initial/update operation descriptor。 |
| `ebox-native-reflow.el` | 可选 native 模块加载/构建、ABI 校验、受限 session 和 Elisp fallback。 |

本包有意不包含应用 Component、UI control、响应式 data 或 playground 实现；它们属于同级包。历史应用性能记录器和 native reflow 评估器也不属于独立 Ebox 的发布边界；Ebox 只保留 native 模块本身、Rust 构建输入和可重复的构建检查。

active 合同还覆盖 `Makefile`、`.github/workflows/ci.yml`、`tests/ebox-core-render-tests.el`、`tests/ebox-state-contract-tests.el`、`tests/ebox-layout-boundary-tests.el`、`tests/ebox-patch-plan-tests.el`、`tests/ebox-style-schema-tests.el`、`tests/ebox-spi-tests.el`、`tests/ebox-child-range-tests.el`、`tests/ebox-grid-tests.el`、`tests/ebox-commit-tests.el`、`tests/ebox-surface-tests.el`、`tests/ebox-dsl-tests.el`、`tests/ebox-flex-tests.el`、`tests/ebox-selector-tests.el`、`tests/ebox-package-tests.el`、`tests/ebox-visual-check-tests.el`、`tests/ebox-docs-contract-tests.el`、`tests/ebox-ci-contract-tests.el`、`native/Cargo.toml`、`native/Cargo.lock`、`native/build.rs`、`native/vendor/emacs-30/emacs-module.h`、`native/src/lib.rs`、`native/src/layout.rs`、`native/c/ebox_module.c`、`scripts/ebox-package-lint.el`、`scripts/ebox-visual-check.el` 和 `scripts/ebox-performance-evaluator.el`。

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
| Source/Element Tree | `ebox-child-range.el`、`ebox-tree.el`、`ebox-dsl.el` | 已发布 buffer 的变更。 |
| 状态所有权合同 | `ebox-state-contract.el` | Live 发布或可变 authority。 |
| Computed Style | `ebox-style.el` | 布局 identity 或 patch 执行。 |
| Measurement | `ebox-measure.el` | 应用状态或 dirty 策略。 |
| Formatting Context | `ebox-layout.el`、`ebox-flex.el`、`ebox-grid.el` | Buffer 编辑。 |
| Fragment/Snapshot | `ebox-fragment.el`、`ebox-incremental.el` | Source parsing 或 identity 分配。 |
| Surface 投影与 Runtime 发布 | `ebox-surface.el` 加公共 TP surface API | Ebox 布局决策或通用 diff 执行。 |
| Dirty/Patch 语义 | `ebox-incremental.el` | 原始测量或 TP buffer 写入。 |
| 纯 Patch Artifact Plan | `ebox-patch-plan.el` | Buffer/surface 读取或发布。 |
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
- `ebox-style--property-definitions` 是 Ebox 作者属性的唯一来源：加载时一次生成 Ebox 自己的只读查询索引与一个不可变 ECSS package schema；surface schema 只组合一次，node 构造和更新不重复注册或复制整份 schema。
- E1 固化封闭的 M2a 目标分类：不可变 generation fact、绑定 generation 的 scroll/native authority、opaque TP client-state custody、单向 compatibility mirror，以及 disposable cache。每一行分别记录 M2a 阶段的存储形态，以及目标 owner、mutation API、generation binding、rollback、rebuild proof 与 cleanup。TP client state 保存完整 Ebox state plist。E1 mirror 探针只重建并比较投影，不修改 live state。
- `ebox-layout.el` 不再 load 或调用 `ebox-surface.el`/TP。candidate isolation、继承 cascade 判定和一次性 materialization 只能通过 `ebox-render-context.el` 拥有的已校验 port 进入 layout；`ebox.el` 在两侧加载后接线 surface 实现。
- `ebox-incremental.el` 同样不再包含任何 `ebox-surface` symbol 或 publication call。`ebox-surface.el` 只安装一个不可变只读 context port，提供 live client state、region mount、cascade proof 与 inline-style preparation；batch observation 留在更高层的 `ebox.el` orchestrator。
- `ebox-patch-plan.el` 只消费 tentative operation plist 与不可变 generation parent table，并返回 deterministic plan artifact；所有 live fact 准备仍由 incremental adapter 拥有。E3 默认使用 pure route，同时保留显式 `legacy` 与执行等价检查的 `shadow` route；三条 route 都不能发布。
- `ebox-style--property-definitions` 同时也是 used-value projection 的唯一真相源。非默认 engine lowering 写在每个 property 的 `:engine-projection` 中；ECSS metadata 暴露派生的 `:engine-targets`，只有非公共 engine 字段可以进入小型 internal exception table。
- `ebox-framework-spi-capabilities` 返回 fresh immutable SPI v2 provider record，声明 paired initial/update stage+rollback、combined participant order、same-object report、initial observation replay，以及实际接受的 TP protocol。`ebox-framework-spi-required-tp-version` 公开最低 TP 1.0.1 依赖，`ebox-framework-spi-supported-tp-protocols` 列出 consumer-first 与最终 v2 protocol identity。initial TP/Ebox timing 在 publication 期间真实测量，以 defensive snapshot 写入 completed report 后再 replay；不生成虚假的零耗时数据，也不携带 mutate authority。Ebox 不创建 selected port 或 consumer bootstrap。
- Ebox 始终通过 TP 的公开 `tp-transaction-participate-v2` API 注册可 rollback 的
  runtime mirror。加载的 manifest 必须用 accepted structured protocol 声明该可调用
  API；capability 缺失或格式错误会在加载时 fail closed。
- SPI initial publication 由 provider 负责 widen，并在 TP transaction 外包一层
  editor change group。任何失败或非局部退出都会恢复原 overlay identity/bounds，
  以及 buffer text、marker identity、point、mark、narrowing、undo history 与
  modified state。
- Framework report finalization 属于 postaccept 且保证不向外抛出。initial、full update 与 scoped update 的 completion fault 都以 `framework-report-finalization` diagnostics 留在同一个 legacy report 中，不能触发 framework rollback，也不能逃逸进 ETAF semantic rollback window。
- `owner-rerender` 范围大于 `span-patch`，`span-patch` 大于 `paint-patch`。
- Buffer 坐标属于生成它的 generation，变更后必须重新获取。
- Grid 使用普通测量与渲染流水线；native reflow 可以拒绝不适合的树并回退到 Elisp，正确性不变。
- 已确认的 retained-native frame 持有不可变布局文档及其精确文档 revision；候选
  session 的 fork 共享该文档。同步 frame 只有在文档 base/target revision 相等且
  命中 confirmed 文档、同时 TP runtime revision 命中 confirmed frame 时，才可
  省略文档。IR 变化必须携带下一 document revision 的完整 replacement document；
  confirm 原子晋升候选文档，失败或取消不修改 parent session。
- 只有继续已提交 native frame 的 full declarative update，才会在 stable native
  eligibility 前为全部 candidate node 计算 selector-local style；生成的
  `:styles-prepared-p` certificate 防止 replacement runtime 丢失 computed style，
  普通 full/local update 仍保持 O(changed)。topology-changing full-frame bootstrap
  继续可用。
- 加载 Ebox 不会构建或安装可选 Rust 模块。
- Phase 9 已完成：首次 mount、声明式 commit、handle/selector 更新、viewport/theme 更新、batch flush 与 scroll 更新全部通过 TP surface 发布。Phase 10 已把 selector 解析、匹配与 cascade 统一到 ECSS；Ebox 只计算 dirty/layout owner，并让不透明 runtime state 参与 TP 的可 rollback transaction，不存在第二个 live buffer executor。
- 成功报告会保留 Ebox 语义 strategy 与 planned publication scope，再加入 `:publication-scope tp-surface`、TP 物理 operation 数、surface revision、scoped/full-root 事实和 retained-object reconciliation 统计。

## Grid 合同

当前 Grid 支持固定和像素轨道、`auto`、分数轨道、`minmax`、`repeat`、隐式行列、行列 gap、auto-flow、从 1 开始的 placement、正整数 span、item/content 对齐，以及普通 buffer 渲染和更新。Ebox 支持规范字体输入（`:font-family`、`:font-size`、`:font-weight`、`:font-style`）与 text-decoration paint；完整浏览器 typography 不在合同内。百分比、绝对定位、z-index、圆角、阴影和浏览器级 bidi 也不在合同内。

## Active 示例与测试

独立 Ebox 包不再内置 playground fixture。迁移后的 `.ebox` 参考文件及其运行器位于同级 `ebox-playground` 包；本仓库直接测试 DSL 与布局原语。回归边界是 `tests/` 下由文档合同列出的 ERT 文件。本包测试不得加载历史全栈源码树或应用框架。

## 验证矩阵

```sh
make check
make core-tests
make child-range-tests
make grid-tests
make ebox-commit-tests
make surface-tests
make visual-check-tests
make package-tests
make selector-tests
make dsl-tests
make flex-tests
make state-contract-tests
make layout-boundary-tests
make layout-boundary-performance
make patch-plan-tests
make patch-plan-performance
make style-schema-tests
make style-schema-performance
make spi-tests
make spi-performance
make c1b-contract-tests
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
