# Ebox

安装包保留根目录入口、`lisp/` 实现目录和原生资源，与源码布局一致。

源码布局：将仓库根目录加入 `load-path`，然后 require 与包同名的入口。
入口 Commentary 列出公共 API 及用法；内部实现位于 `lisp/`。

Ebox 是一个独立的 Emacs Text/Box 布局引擎，负责文本测量、Box 几何、
row/column/flex/Grid 布局、retained 渲染和增量 buffer 发布。应用还需要
Component、响应式状态、behavior 或生命周期时，使用同级 ETAF 包。

## 安装

源码仓库为 [geekinney/ebox](https://gitea.gklazycat.heiyu.space/geekinney/ebox)。
当前 `3.0.0` 更新日志仍标记为未发布；源码 checkout 不代表已经发布的包归档或稳定版本 tag。

| 依赖 | 使用条件 |
| --- | --- |
| Emacs 29.1 或更高版本 | 所有 Ebox 使用场景。 |
| ECSS 0.1.0 或更高版本 | 样式计算和选择器语义；即使不使用样式表也需要。 |
| [EKP 1.0.0 或更高版本](https://gitea.gklazycat.heiyu.space/geekinney/ekp) | 可选，仅使用 `:wrap-mode kp` 时需要。 |

ECSS 是包声明的必需依赖。EKP 保持可选，普通 `word`、`char`、`none` 换行不需要它。
使用同级源码 checkout 时，把必需的目录加入 `load-path` 后加载 Ebox：

```elisp
(add-to-list 'load-path "/path/to/ecss")
(add-to-list 'load-path "/path/to/ebox")
(require 'ebox)
```

加载 Ebox 不会创建 buffer，也不会构建 native 模块。

使用 Knuth–Plass 段落排版时，先额外将 EKP 源码目录加入 `load-path`，或安装它的包，
然后在 Box 上设置 `:wrap-mode kp`：

```elisp
(add-to-list 'load-path "/path/to/ekp")
(ebox-render
 (ebox-build '(box :width (ch 40) :wrap-mode kp :overflow hidden
                   "A paragraph laid out with Knuth–Plass line breaking.")))
```

Ebox 在使用该换行模式时加载 EKP。EKP 缺失或不兼容时会提示安装或更新；请安装 EKP，
或显式选择其他换行模式。Ebox 不会静默改用 `word`。EKP 自己的可选加速器与
Ebox 的可选 Rust 模块是两回事。

### 构建并验证可安装归档

在本仓库中运行：

```sh
make release-check EMACS=emacs RELEASE_DIR=/tmp/ebox-release-3.0.0
```

该入口按 [`release-dependencies.json`](release-dependencies.json) 获取精确的依赖提交，
构建可重复的 `package.el` 源码归档，在临时干净配置中安装并验证渲染、更新和选择器。
归档目录与 `manifest.json` 会保留，其中记录校验和、源码提交及工作区是否有修改；
它不会发布归档或修改你的 Emacs 配置。每次使用新的输出目录，不覆盖已有目录。

需要同时包含并测试可选 KP 排版时，换一个输出目录并加上 `RELEASE_OPTIONS=--with-ekp`。
归档验证通过后，可以作为本地包归档安装：

```elisp
(require 'package)
(add-to-list 'package-archives '("ebox-local" . "/tmp/ebox-release-3.0.0/"))
(package-refresh-contents)
(package-install 'ebox)
;; 可选，仅当归档构建时使用了 --with-ekp：
;; (package-install 'ekp)
```

发布工具选项见 `python3 scripts/ebox-release.py --help`。

## 第一次渲染

普通用户只需理解七个 author 入口：字符串、`text`、`box`、`row`、`column`、
`flex` 和 `grid`。子节点直接嵌套，不存在第二套 field-based child 语法。

```elisp
(require 'ebox)

(ebox-render-to-buffer
 "*Ebox Example*"
 (ebox-build
  '(column :padding ((lh 1) (ch 2))
           :border ((px 1) solid "#8A93A6")
           (text :color "#263244" "Hello Ebox")
           (row :item-gap (ch 1)
                (box "Left")
                (box "Right")))))
```

普通 author DSL 统一通过 `ebox-build`。框架集成可以用一个
`ebox-source-builder` 组合 typed node，再把 forest 与同一代 source facts 封装为一个
`CanonicalEboxInput`；这个 evaluated API 不是第二套 author 语法。

已求值的 Box 构造包含 `ebox-child-range` 时，通过 `:source-builder`
显式传入开放的 builder。它必须拥有 Box 及所有直接子节点的 source handle；
空 Range 同样需要开放的 builder。builder 只参与构造，不保留在节点中。
组合已有 canonical input 时，使用 `ebox-canonical-input-roots` 与
`ebox-canonical-input-import-roots`，框架不应读取私有字段或绑定私有动态上下文。

## 如何选择布局

- `box` 创建普通视觉盒子；
- `row` 和 `column` 用于简单的一维组合；
- `flex` 用于空间分配和换行；
- `grid` 用于二维轨道与放置；
- 裸字符串是 `(text "...")` 的简写。

Flex/Grid participation property 直接属于子 `box`，不需要额外 wrapper 节点。

Box 几何统一写成 `(单位 数值)`，支持 `px`、`%`、`vw`、`vh`、`ch`、`lh`。
例如 `:width (ch 80)` 表示 80 个 `0` 字形的前进宽度，
`:height (calc (- (vh 100) (lh 1)))` 表示视口高度减一个行高。
`calc`、`min`、`max`、`clamp` 在布局时组合长度；`auto`、裸 `fit-content` 等
尺寸关键词仍直接写符号。旧的裸长度、单元素像素列表和视口关键词会报错。
构造时按属性方向检查单位，包括尺寸函数的所有分支。允许的组合、关键词默认值、
百分比参照及纵向行粒度限制见[统一单位约束表](docs/manual.zh-CN.md#size-unit-constraints)。
空 Box 的自动内容高度为零；需要一行空白时写 `(box :height (lh 1))`。

## 原生交互

Text 与所有 Box form 都接受七种显式节点能力：`:help-echo` 提供字符串或原生帮助
函数，`:pointer` 选择原生鼠标指针形状，`:hover-style` 设置受限的颜色与文本装饰
绘制，`:hover-content` 在指针进入时替换 Text 内容，`:keymap` 接收原生 Emacs keymap，
`:drag-lock-modifier` 为主按钮拖拽提供可选的锁定修饰键，`:hover-group` 让相关
hover-content 在一次增量发布中同时更新。Box 的帮助、指针和 keymap 范围包含内容、
padding 和 border，不包含该 Box 的 margin 和结构性换行符。悬停在文字与 padding
间共享声明节点的绘制，不包含物理左右边框。嵌套节点的显式值覆盖外层能力；
显式 `nil` 清除对应能力。

`:hover-content` 通过保留的 `ebox-region-update` 内容发布进入和离开；值可以是字符串或
返回字符串的零参数函数。需要保持行高时请使用同一行的替代内容。只有声明该能力的
buffer 才会启用本地鼠标移动跟踪；Ebox 不创建 overlay，也不把 hover 放进主按钮拖拽循环。
使用 `ebox-help-create` 将零参数业务函数适配为原生帮助，并提供悬停 buffer 上下文。
使用 `ebox-keymap-create` 将普通零参数回调绑定到激活键或自定义按键；鼠标命令会
自动在被点击窗口的 buffer 中运行。配合 `:drag` 和 `:drag-lock-modifier` 时，初次按下
修饰键会在释放按钮后继续锁定拖拽；再次按主按钮结束，ESC 取消，状态只属于该挂载目标。
`ebox-region-update` 可以使用当前已挂载 buffer
中的语义 ID，或显式 region handle，替换或清除节点能力。原生 keymap 可用于
独立的 Ebox 交互；可选的 `ebox-next-interaction`、`ebox-previous-interaction` 命令
在渲染后的 keymap owner 之间移动 point，不添加默认按键绑定。应用状态与命令行为
由作者管理。参见
[交互指南](docs/manual.zh-CN.md#native-node-interaction)和 Playground 的
[交互实验室](https://gitea.gklazycat.heiyu.space/geekinney/ebox-playground/src/branch/main/README.zh-CN.md#native-interaction-lab)。

节点可以声明 `:tab-index` 与 `:disabled`；`ebox-focus` 系列接口由 Ebox 管理 buffer
逻辑焦点、可选循环导航、更新保持与回滚。挂载的 `ebox-buffer-mode` 通过
`ebox-buffer-mode-map` 提供 TAB/backtab 循环导航和 RET/return 激活。生成的键盘
激活命令尊重焦点，鼠标使用点击目标；point 和生命周期规则见交互指南。

## 渲染与更新

- `ebox-render` 返回带属性文本，不发布 live buffer；
- `ebox-render-to-buffer` 挂载 retained surface；
- `ebox-display-buffer` 先完成渲染，再按 Emacs 显示规则与可选 action 显示结果，返回 buffer；
- `ebox-commit` 原子发布重新构建的 canonical input；
- `ebox-buffer-update-report` 返回最近一次成功更新报告；
- `ebox-rerender-buffer-with-context` 应用显式 viewport 变化。
- `ebox-surface-buffer-snapshot` 显式导出当前提交的 `:input`、`:revision`
  与 `:mount-id`，以一个 plist 返回。

Ebox 会在分配 runtime identity 前复制 canonical input，因此同一个 built value 可以
挂载到多个 buffer，而不会共享 live ownership。

快照只在显式查询时遍历导出数据和 Ebox publication 最近的诊断报告，普通更新不会创建快照。其 canonical input 在后续
更新、卸载后仍可使用；节点中的可变数据与交互 keymap 独立复制，不可变 source facts
与不透明能力（回调、record）保留身份。快照不冻结显示环境或外部能力。Ebox publication 事务期间、
卸载后查询会报错。识别提交版本时同时比较 mount ID 与 revision，避免重新挂载后
revision 从头计数导致混淆。

Ebox 内部持有发布与回滚。框架通过 SPI v3 与 `ebox-publication/v1` 注册成对状态
操作和有界 final-accept marker；旧版框架 SPI 记录会在初始化时被拒绝。

## 可选 native 模块

Rust 模块加速符合条件的 reflow 和图层合成；它不是正确性的依赖，并有完全等价的 Elisp
fallback。Ebox 加载时不会自动构建它。

```elisp
(ebox-native-status)
(ebox-native-build)
```

## 显示与文本边界

每个已挂载 buffer 只有一套视口布局。同一个 buffer 同时出现在不同宽度的两个窗口中，
不会产生两套独立布局。需要各自宽度时，分别挂载到不同 buffer；同一份 canonical input
可以挂载多次。

纵向几何按完整行生成。文本处理保留常见组合音标、变体选择符、Emoji 修饰符、ZWJ 与
旗帜序列，但不实现完整 Unicode 字素分段，也不承诺浏览器级字体排版和双向布局。
可用字体、原生指针和帮助显示由 Emacs 与窗口系统决定；终端输出无法复现全部 GUI
像素或指针效果。

`:overflow hidden` 将内容限制在盒子测量后的宽度与完整行高度内，保留自身 padding 和
边框。横向裁剪保留完整的受支持文本簇，用空白补齐剩余像素，不显示半个字形，也不
添加省略号。`scroll` 仍是纵向滚动。

仓库提供结构检查 CI 配置。运行时与 native 验证使用本地 Make 入口；
平台支持情况应以实际验证结果为准。

## 验证

```sh
make load EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make compile EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make test EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make check EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make test
```

在同级源码检出环境中，用以下命令诊断增量更新：

```sh
EBOX_UPDATE_EFFECTS_OUTPUT=/tmp/ebox-effects.json make update-effects-performance
```

工具覆盖文本、颜色、原生交互与宽度变化的全部 15 种组合，分别使用内联和局部作用域样式。
每个候选替换两个相邻控件，包括未变化的邻居。先用全新渲染校验输入，再在每次计时之外
检查文本、显示几何、颜色、keymap 和激活行为。JSON 记录候选构建至提交的原始样本、
p50/p95/max、投影种类计数，以及源码和评估器身份。`ordinary` 表示没有报告局部投影种类，
不能据此认定曾尝试局部投影并失败。
额外两次开启观察的更新不计入延迟样本；`rejection_counts` 按投影种类和原因
汇总这两次记录的局部拒绝。它不是完整追踪，
解释这些诊断前请参阅[报告语义](docs/manual.zh-CN.md)。

默认分别保留 20、100 个不变兄弟节点，每组预热三次、采样十次。可设置
`EBOX_UPDATE_EFFECTS_SIZES=20,100`、`EBOX_UPDATE_EFFECTS_WARMUPS=3` 和
`EBOX_UPDATE_EFFECTS_SAMPLES=10`。每次使用新的输出路径。工具获取共享性能测试锁，
锁被占用时立即失败，退出时释放自己获取的锁。单组功能失败会记录到报告，继续运行
其余组合，最终以非零状态退出。`completed` 只表示检查成功完成，不代表满足耗时门槛
或通过 GUI 验收。比较时保持负载和环境一致；应用和 GUI 验收仍需分别执行。

继续阅读[用户指南](docs/manual.zh-CN.md)、[公共 API
参考](docs/manual.zh-CN.md)，以及同级
[ebox-playground](https://gitea.gklazycat.heiyu.space/geekinney/ebox-playground/src/branch/main/README.md) 示例。

## 许可证

Ebox 自有代码按 GPL-3.0-or-later 分发，详见 [LICENSE](LICENSE)。第三方文件保留各自的
许可证声明。

## 开发

克隆后运行 `make setup-hooks`。提交变更前运行 `make check`；`make structure-check` 用于快速检查目录、命名和引用。

[docs/manual.zh-CN.md](docs/manual.zh-CN.md) · [docs/architecture.zh-CN.md](docs/architecture.zh-CN.md) · [CHANGELOG.zh-CN.md](CHANGELOG.zh-CN.md)

`make check` 运行规范检查、编译及 [tests/acceptance.json](tests/acceptance.json) 中的公共验收场景。`make test` 运行同一套公共 API 测试。清单涵盖全部维护的 Lisp 测试。GUI 与性能验收使用独立入口。
