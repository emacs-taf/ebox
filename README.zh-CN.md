# Ebox

Ebox 是一个独立的 Emacs 像素级 Box 与布局引擎。它是同级 [ETAF](../etaf/README.zh-CN.md) 文本应用框架使用的底层渲染基座；也可以脱离 Component、应用状态和 ETAF 单独使用。

## 安装与使用

ECSS 与 TP 是互相独立的包，安装顺序任意。两者都安装后再安装 Ebox，或直接让包管理器解析 Ebox 声明的两个依赖。使用同级源码 checkout 时，把三个目录都加入 `load-path`：

```elisp
(add-to-list 'load-path "/path/to/github/ecss")
(add-to-list 'load-path "/path/to/github/tp")
(add-to-list 'load-path "/path/to/github/ebox")
(require 'ebox)

(ebox-render-to-buffer
 "*Ebox Example*"
 (ebox-column
  (ebox-create :content "Hello Ebox"
               :padding '(1 2)
               :border '((1) solid "#8A93A6")
               :color "#263244"
               :bgcolor "#F4F6FB")))
```

公共模型是一棵 Ebox 节点树。`ebox-create` 构造叶子或包装节点；`ebox-column`、`ebox-row`、`ebox-flex` 和 `ebox-grid` 组合节点；`ebox-render` 生成带属性文本但不发布 buffer state（没有 cascade/inheritance 依赖时使用隔离的 pure materialization）；`ebox-render-to-buffer` 挂载 retained TP surface；`ebox-display-buffer` 展示同一条 retained-surface 路径；`ebox-commit` 使用新的根树原子更新该 mount。Ebox 会在分配 runtime identity 前复制声明式输入，因此同一 source tree 可以挂载到多个 buffer，而不转移所有权。公共 API 不再提供另一套擦除 live buffer 后执行任意 BODY 的宏。

CSS-like selector 字符串会编译为 ECSS 的 structured selector AST。Ebox 提供逻辑节点关系与索引候选；对于 tree query、rendered-buffer query 和样式规则，ECSS 是唯一 selector matcher 与 cascade engine。

## 本包负责什么

- box 创建、padding、margin、border、颜色、face、overflow 与文本测量；
- row、column、flex 和二维 Grid 布局；
- selector、稳定节点 identity、key reconciliation、buffer 渲染与增量发布；
- 可选 Rust native reflow，以及完全等价的 Elisp fallback；
- 底层 Ebox DSL 文件与渲染器测试。

ETAF 属于同级独立包。当你需要统一 View 语法、Component、响应式状态、behavior、Context、Data Controller 或应用生命周期时，单独安装 ETAF。两个独立的示例包是 [ebox-playground](../ebox-playground/README.md) 与 [etaf-playground](../etaf-playground/README.md)。

## 仓库结构

| 路径 | 职责 |
| --- | --- |
| `ebox.el` | 公共门面与包入口。 |
| `ebox-cache.el`、`ebox-style.el`、`ebox-tree.el`、`ebox-measure.el` | 缓存、样式、树和测量模型。 |
| `ebox-fragment.el`、`ebox-render-context.el` | 布局事实与 render-local context。 |
| `ebox-layout.el`、`ebox-flex.el`、`ebox-grid.el` | Formatting Context 与布局算法。 |
| `ebox-surface.el` | 将 Ebox runtime/layout 投影为 TP surface plan，并负责 retained mount/update 与原子 runtime-state 参与。 |
| `ebox-buffer-backend.el`、`ebox-incremental.el` | Render-string backend 与 Ebox 增量规划。 |
| `ebox-dsl.el`、`ebox-selector.el` | 独立 DSL 与基于 ECSS 的树/runtime 查询。 |
| `ebox-native-reflow.el`、`native/` | 可选 native reflow 边界。 |
| `tests/` | 只属于 Ebox 的回归与契约测试。 |
| `docs/user/`、`docs/maintainer/` | 长期维护的中英文文档。 |

## 验证

```sh
make load EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make compile EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make check EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make native-rust-tests
```

小范围修改先运行对应目标（例如 `make grid-tests`、`make surface-tests`、`make dsl-tests` 或 `make visual-check-tests`）；共享渲染或公共 API 修改后运行完整的 `make check`。默认从 `../new-architecture/ecss` 与 `../tp` 查找同级 ECSS 和 TP checkout；若路径不同可覆盖 `ECSS_DIR` 或 `TP_DIR`。

入门构造示例见 [Ebox 用户指南](docs/user/ebox-user-guide.zh.md)，完整函数/property/配置清单见 [公共 API 参考](docs/user/ebox-api-reference.zh.md)，职责边界与不变量见 [当前实现参考](docs/maintainer/ebox-current-implementation-reference.zh.md)。
