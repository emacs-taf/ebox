# Ebox

Ebox 是一个独立的 Emacs Text/Box 布局引擎，负责文本测量、Box 几何、
row/column/flex/Grid 布局、retained 渲染和增量 buffer 发布。应用还需要
Component、响应式状态、behavior 或生命周期时，使用同级 ETAF 包。

## 安装

Ebox 需要 Emacs 29.1 或更高版本、ECSS 0.1.0 或更高版本，以及 TP 1.0.1 或
更高版本。包管理器应自动安装声明的依赖。使用同级源码 checkout 时，把三个目录
加入 `load-path` 后加载 Ebox：

```elisp
(add-to-list 'load-path "/path/to/ecss")
(add-to-list 'load-path "/path/to/tp")
(add-to-list 'load-path "/path/to/ebox")
(require 'ebox)
```

加载 Ebox 不会创建 buffer，也不会构建 native 模块。

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
百分比参照及纵向行粒度限制见[统一单位约束表](docs/user/ebox-user-guide.zh.md#size-unit-constraints)。
空 Box 的自动内容高度为零；需要一行空白时写 `(box :height (lh 1))`。

## 原生交互

Text 与所有 Box form 都接受四种显式节点能力：`:help-echo` 提供字符串或原生帮助
函数，`:pointer` 选择原生鼠标指针形状，`:hover-style` 设置受限的颜色与文本装饰
绘制，`:keymap` 接收原生 Emacs keymap。Box 的帮助、指针和 keymap 范围包含内容、
padding 和 border，不包含该 Box 的 margin 和结构性换行符。悬停在文字与 padding
间共享声明节点的绘制，不包含物理左右边框。嵌套节点的显式值覆盖外层能力；
显式 `nil` 清除对应能力。

使用 `ebox-help-create` 将零参数业务函数适配为原生帮助，并提供悬停 buffer 上下文。
使用 `ebox-keymap-create` 将普通零参数回调绑定到激活键或自定义按键；鼠标命令会
自动在被点击窗口的 buffer 中运行。`ebox-region-update` 可以使用当前已挂载 buffer
中的语义 ID，或显式 region handle，替换或清除节点能力。原生 keymap 可用于
独立的 Ebox 交互；应用状态、焦点导航和命令行为由作者管理。参见
[交互指南](docs/user/ebox-user-guide.zh.md#native-node-interaction)和 Playground 的
[交互实验室](../ebox-playground/README.zh-CN.md#native-interaction-lab)。

## 渲染与更新

- `ebox-render` 返回带属性文本，不发布 live buffer；
- `ebox-render-to-buffer` 挂载 retained surface；
- `ebox-commit` 原子发布重新构建的 canonical input；
- `ebox-buffer-update-report` 返回最近一次成功更新报告；
- `ebox-rerender-buffer-with-context` 应用显式 viewport 变化。
- `ebox-surface-buffer-snapshot` 显式导出当前提交的 `:input`、`:revision`
  与 `:mount-id`，以一个 plist 返回。

Ebox 会在分配 runtime identity 前复制 canonical input，因此同一个 built value 可以
挂载到多个 buffer，而不会共享 live ownership。

快照只在显式查询时遍历导出数据和 TP 最近的诊断报告，普通更新不会创建快照。其 canonical input 在后续
更新、卸载后仍可使用；节点中的可变数据与交互 keymap 独立复制，不可变 source facts
与不透明能力（回调、record）保留身份。快照不冻结显示环境或外部能力。TP 事务期间、
卸载后查询会报错。识别提交版本时同时比较 mount ID 与 revision，避免重新挂载后
revision 从头计数导致混淆。

Ebox 只通过 TP 的公开 structured participant API 注册可回滚状态。TP 1.0.1
支持 consumer-first 迁移协议；TP 2.0.0 发布最终的 v2-only 协议。structured
participant capability 缺失或格式错误时，Ebox 会停止加载，不会选择兼容 writer。

## 可选 native 模块

Rust 模块只加速符合条件的 reflow；它不是正确性的依赖，并有完全等价的 Elisp
fallback。Ebox 加载时不会自动构建它。

```elisp
(ebox-native-status)
(ebox-native-build)
```

## 验证

```sh
make load EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make compile EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make docs-contract-tests EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make interaction-tests EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make c1b-contract-tests EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make check EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make native-rust-tests
```

继续阅读[用户指南](docs/user/ebox-user-guide.zh.md)、[公共 API
参考](docs/user/ebox-api-reference.zh.md)，以及同级
[ebox-playground](../ebox-playground/README.md) 示例。
