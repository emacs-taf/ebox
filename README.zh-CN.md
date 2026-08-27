# Ebox

Ebox 是一个独立的 Emacs Text/Box 布局引擎，负责文本测量、Box 几何、
row/column/flex/Grid 布局、retained 渲染和增量 buffer 发布。应用还需要
Component、响应式状态、behavior 或生命周期时，使用同级 ETAF 包。

## 安装

Ebox 需要 Emacs 29.1 或更高版本，并依赖 ECSS 与 TP。包管理器应自动安装声明的
依赖。使用同级源码 checkout 时，把三个目录加入 `load-path` 后加载 Ebox：

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
  '(column :padding (1 2)
           :border ((1) solid "#8A93A6")
           (text :color "#263244" "Hello Ebox")
           (row :item-gap 1
                (box "Left")
                (box "Right")))))
```

普通 author DSL 统一通过 `ebox-build`。框架集成可以直接组合
`ebox-text-create`、typed LayoutConfig constructor 和 `ebox-box-create`；这个
evaluated API 不是第二套 author 语法。

## 如何选择布局

- `box` 创建普通视觉盒子；
- `row` 和 `column` 用于简单的一维组合；
- `flex` 用于空间分配和换行；
- `grid` 用于二维轨道与放置；
- 裸字符串是 `(text "...")` 的简写。

Flex/Grid participation property 直接属于子 `box`，不需要额外 wrapper 节点。

## 渲染与更新

- `ebox-render` 返回带属性文本，不发布 live buffer；
- `ebox-render-to-buffer` 挂载 retained surface；
- `ebox-commit` 原子发布重新构建的 root；
- `ebox-buffer-update-report` 返回最近一次成功更新报告；
- `ebox-rerender-buffer-with-context` 应用显式 viewport 变化。

Ebox 会在分配 runtime identity 前复制 author 输入，因此同一棵已构建树可以挂载到
多个 buffer，而不会共享 live ownership。

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
make check EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make native-rust-tests
```

继续阅读[用户指南](docs/user/ebox-user-guide.zh.md)、[公共 API
参考](docs/user/ebox-api-reference.zh.md)，以及同级
[ebox-playground](../ebox-playground/README.md) 示例。
