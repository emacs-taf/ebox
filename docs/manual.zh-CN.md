# ebox 使用手册

[English](manual.md)

Ebox 是底层 Text/Box 布局与 buffer 渲染包。本指南只使用一套公共 author 语法，
并把框架集成接口单独说明。完整函数清单见[公共 API
参考](manual.zh-CN.md)。

## 1. 加载 Ebox

```elisp
(require 'ebox)
```

加载 Ebox 不会创建 buffer、在当前 buffer 启用 mode，也不会构建 Rust。

## 2. 只学习一个 author 模型

Ebox 文档由 Text 和 Box 节点组成。author 语法只有七个入口：

| 入口 | 含义 |
| --- | --- |
| `"text"` | 一个 Text 节点的简写。 |
| `(text ... "text")` | 带显式文本 property 的 Text。 |
| `(box ... CHILD...)` | 普通视觉 Box。 |
| `(row ... CHILD...)` | 使用简单横向子布局的 Box。 |
| `(column ... CHILD...)` | 使用简单纵向子布局的 Box。 |
| `(flex ... CHILD...)` | 使用 Flex 子布局的 Box。 |
| `(grid ... CHILD...)` | 使用 Grid 子布局的 Box。 |

子节点始终直接嵌套。布局 form 只是选择了子布局算法的 Box，不是另一种视觉对象。

```elisp
(defvar ebox-guide-input
  (ebox-build
   '(column :padding ((lh 1) (ch 2))
            :border ((px 1) solid "#8A93A6")
            (text :color "#263244" "Research notes")
            (row :item-gap (ch 1)
                 (box :id "status" :background-color "#F4F6FB" "Inbox")
                 (box :background-color "#EEF2FF" "Archive")))))
```

`ebox-build` 返回不透明的 `CanonicalEboxInput`，把 canonical forest 与对应的 source
generation 保持为一个整体。普通 author 代码只需把这个值原样传给渲染和发布函数，
不要取出或重新组装其中的内部 node。

需要空矩形区域时，使用只有几何 property、没有子节点的 `box`，不需要额外节点类型。

### 优先利用默认值和继承

默认只写改变预期效果的属性：省略冗余默认值，把共同的文字样式放到已有的共同父节点，
子节点只写差异。参考示例正在讲解的属性仍然显式写出，即使它恰好采用默认值。

eBox 自动继承 `:color`、`:font-family`、`:font-size`、`:font-weight`、
`:font-style`、`:text-align`、`:wrap-mode` 和 `:visibility`。几何属性和背景色不继承；
子节点未绘制背景时，可以透出父节点的背景。例如：

```elisp
(ebox-build
 '(column :width (ch 40) :color "#1F2328" :bgcolor "#FAF7F0"
          (box "Shared text color")
          (box :color "#B45309" "Local accent")
          (box :height (lh 1))))
```

继承不会扩大属性的声明范围。例如 `:text-align` 只能声明在 `box` 上，不能因为它可以继承，
就把它移到 `row`、`column`、`flex` 或 `grid` 上。

在这个普通 Column 中，分隔框会填满可用宽度，并通过 `:height (lh 1)` 明确保留一行，
无需重复设置宽度和背景。空 Box 的 `auto` 内容高度为零；需要一行留白时显式设置
`:height (lh 1)`。padding 和 border 仍可增加各自的外部占用。
这取决于布局上下文：Row 中 auto 宽度的子项按固有宽度排布，Flex/Grid 也有各自的子项尺寸规则。
不要把所有 `stretch` 都替换成 `auto`，也不要删除正在覆盖继承样式、样式表或其他简写的值。
没有其他声明设置对应边距时，可以用 `:padding-inline` 或 `:padding-block` 省去零值轴。

## 3. 用布局名称直接表达意图

普通内容用 `box`；直接的一维组合用 `row` 或 `column`；需要分配剩余空间或换行时
用 `flex`；需要二维轨道或显式放置时用 `grid`。

### Row 与 column

`row` 和 `column` 接受 `:item-gap` 与 `:cross-align`。它们的子节点仍然只是 Text
或 Box。

```elisp
(ebox-build
 '(row :item-gap (ch 2) :cross-align center
       (box :width (ch 12) "Left")
       (box :width (ch 12) "Right")))
```

### Flex

Flex 容器 property 属于 `flex`。participation property 直接属于子 `box`，因为它
描述的是父子关系。

```elisp
(ebox-build
 '(flex :width (px 480)
        :flex-flow (row wrap)
        :gap ((lh 1) (px 12))
        (box :flex (1 1 auto) "Primary")
        (box :flex-grow 2 "Secondary")))
```

### Grid

Grid 放置从 1 开始。轨道可以是固定值、`auto`、分数、`minmax` 或 `repeat`。
placement property 同样直接属于子 `box`。

```elisp
(ebox-build
 '(grid :width (px 640)
        :grid-template-columns ((px 200) (fr 1) (fr 1))
        :grid-template-rows ((lh 1) (lh 1))
        :gap ((lh 1) (px 12))
        (box :grid-column (1 :span 3) "Header")
        (box :grid-column 1 :grid-row 2 "Navigation")
        (box :grid-column 2 :grid-row 2 "Main")
        (box :grid-column 3 :grid-row 2 "Aside")))
```

## 4. 使用几何与绘制 property

Box 几何统一使用 `(单位 数值)`。宽高及其最小/最大值、内外边距、gap、边框宽度、
Flex basis 和 Grid 固定轨道都使用这套格式。Ebox 实现 CSS 尺寸语义的一个子集，
输入是 Elisp 数据，不接受 `"80ch"` 这样的 CSS 字符串。

| 单位 | 含义 |
| --- | --- |
| `(px 240)` | 240 像素。 |
| `(% 50)` | 该属性所参照的包含块尺寸的 50%。 |
| `(vw 100)` | 视口宽度的 100%。 |
| `(vh 100)` | 视口高度的 100%。 |
| `(ch 80)` | 当前有效字体中字符 `0` 的排版前进宽度的 80 倍。 |
| `(lh 3)` | 三个有效行高。 |

`ch` 不表示任意字符或汉字的个数。`1vw`、`1vh` 分别表示视口对应轴的 1%。
显示中的 Ebox 视口是目标窗口的
可用正文区域，不包含 mode-line 和 header-line；因此 Playground 使用预览窗口。

<a id="size-unit-constraints"></a>

### 按属性限制单位

下表是所有 Ebox 作者入口共同遵循的单位契约。Ebox 当前支持的书写模式中，inline
表示横向，block 表示纵向。这是针对 Emacs 收窄后的规则，比 CSS 的通用长度模型严格。

| 值的用途 | 允许单位 | 对应属性 |
| --- | --- | --- |
| Inline 几何 | `px`、`ch`、`vw`、`%` | `width`、`min-width`、`max-width`；左右和 inline padding/margin；`column-gap`；Row 的 `item-gap`；Grid 列轨道。 |
| Block 几何 | `lh`、`vh`、`%` | `height`、`min-height`、`max-height`；上下和 block padding/margin；`row-gap`；Column 的 `item-gap`；Grid 行轨道。 |
| 定位偏移 | `left` 使用 inline 单位；`top` 使用 block 单位 | 有符号长度及尺寸表达式；`%` 参照绘制宿主对应内容轴。 |
| Flex 主轴尺寸 | 所在父 Flex 主轴允许的单位 | `flex-basis` 及 `(grow shrink basis)` 中的 basis；row 方向用 inline 单位，column 方向用 block 单位。 |
| 边框绘制厚度 | `px`、`ch`、`lh`、`vw`、`vh` | `border-width`、各侧边框宽度、border 简写中的宽度；不接受百分比。 |

`calc`、`min`、`max`、`clamp` 的所有分支以及嵌套的 Grid 轨道函数，都递归遵循
对应的单位限制。出现不允许的单位时，`ebox-build` 初次构造树就报错；即使计算会
抵消它，或最终会选中其他分支，也不例外。例如 `:height (px 24)`、`:width (lh 3)`
和 `:height (min (lh 2) (px 24))` 都不接受。边框厚度是独立的绘制值，因此
`:border ((px 1) solid "red")` 可以同时设置四个方向的边框。

样式表和动态更新也遵循同一契约：计算样式确定后、布局开始前，重新检查 Flex
父容器方向与子项 basis。非法更新不会发布到已有 buffer。数字 `:flex 1` 的隐含
basis 为 `(% 0)`，因此可用于两个主轴；显式 basis 仍按父方向验证。

简写展开到各个方向后逐项验证。单值 `padding`、`margin`、`gap` 会同时用于两轴，
因此这种共享长度只能使用 `%`；通常直接分开两轴，例如
`:padding ((lh 1) (ch 2))`、`:gap ((lh 1) (px 12))`。
只设置一轴时，可以写 `:padding-inline (px 12)` 或 `:padding-block (lh 1)`。

百分比宽度参照包含块宽度；百分比高度需要确定的包含块高度，否则按该属性
的尺寸不确定规则处理。四个方向的百分比 padding、margin 都参照包含块宽度。
边框宽度不接受百分比。
此子集暂不支持负 margin 和 `auto` margin；当前 buffer 后端没有实现外边距重叠
所需的几何能力。

| 属性 | 关键词 | 默认值 |
| --- | --- | --- |
| `width`、`height` | `auto`、`min-content`、`max-content`、`fit-content`、`stretch` | `auto` |
| `min-width`、`min-height` | `auto`、`min-content`、`max-content`、`fit-content`、`stretch` | `auto` |
| `max-width`、`max-height` | `none`、`min-content`、`max-content`、`fit-content`、`stretch` | `none` |

普通块级根容器有可用视口时，`auto` 宽度填满可用空间，`auto` 高度由内容决定。
`min-content`、`max-content` 请求内容固有尺寸；`fit-content` 在这两个固有尺寸之间
适应可用空间；`stretch` 让 margin box 填满可用空间。`none` 表示不限制最大尺寸。
自动最小尺寸取决于布局；显式设置横向最小值 `(px 0)` 或纵向最小值 `(lh 0)`，
可允许 item 缩小到其自动内容最小尺寸以下。没有 padding、border 和显式高度的空
Box 高度为零；`(box :height (lh 1))` 明确保留一行空白。

四种尺寸函数可以组合单位，不会在布局阶段执行任意 Lisp：

```elisp
'(column :width (min (% 100) (ch 80))
         :height (calc (- (vh 100) (lh 1)))
         (box :width (max (px 120) (% 25)) "侧栏")
         (box :width (clamp (ch 20) (% 50) (ch 60)) "正文"))
```

`calc` 接受一个算术表达式；`+`、`-` 组合长度，`*` 将长度乘以标量，`/` 将长度
除以非零标量。`min`、`max` 从一个或多个允许的长度中选取最小值、最大值；`clamp` 的三个
参数依次为最小值、首选值、最大值。函数可以嵌套。算术表达式内的裸数字只是标量，
不会隐式变成 `ch` 或 `lh`。

单位和函数一直保留为数据，到布局阶段才解析，因此视口或包含块变化后会重新计算。
中间结果保留小数，例如 853 像素视口的 `33vw` 在显示量化前是 281.49 像素。
当前 buffer 后端按完整行生成 block 几何，小数行目标在这个边界量化。作者接口不
接受纵向 `px` 长度。
`:overflow hidden` 裁掉超出的纵向行，并将每行内容限制在测量后的内容宽度内。
保留放得下的前缀，不拆开受支持的文本簇；放不下的字形或图像整体省去。固定 display
space 可以缩短到精确的剩余像素宽度，被裁字形的剩余空隙保留原 face（含背景色），使 padding 和边框
保持位置。这是按像素宽度截断，不是显示半个字形/图像，也不自动添加省略号。
被省去的子文本不会在填充空白上留下自己的帮助、hover、指针或 keymap。

例如 `(box :width (ch 3) :wrap-mode none :overflow hidden "ABCDEFGHIJ")` 只保留
三个 `0` 字形前进宽度内放得下的前缀；使用 `visible` 时，溢出仍可超出计算宽度。
在哪个容器上设置 `hidden`，就约束哪个容器的内容边界，直接文本和组合后的子节点输出
都受约束。`scroll` 提供纵向滚动，不增加横向滚动。

不再接受几何裸数字、单元素像素列表、`viewport`、`viewport-height`、`contain`，
以及带参数的 `fit-content`。零长度也需要对应轴允许的单位，例如横向 `(px 0)`、
纵向 `(lh 0)`。Grid 的 `(fr n)` 仍表示轨道
份额；Grid 放置索引、Flex grow/shrink 因子仍是无量纲数字。

Text 的样式声明只接受字体、前景/背景和文本装饰 property；此外，Text 还接受下文
介绍的原生节点能力。padding、margin、border、
尺寸、`:outer`、overflow、可见性和换行策略只属于 Box。Box 上的字体与颜色可以
作为其 Text 子树的继承来源，但不会让 Text 获得 Box 几何。

```elisp
(ebox-build
 '(box :width (px 420)
       :padding ((lh 1) (ch 2))
       :margin ((lh 0) (ch 1))
       :border ((px 1) solid "#8A93A6")
       :color "#263244"
       :background-color "#FFFFFF"
       "A readable panel"))
```

用 `:outer inline` 或 `:outer block` 表达 Box 如何参与父布局。子布局算法仍由 form
名称决定。

<a id="retained-layers"></a>

### 保留式图层

在现有 Box form 上设置定位属性即可重叠内容。绝对定位子节点不增加普通流的自动
尺寸，需要预留画布时，为宿主声明明确的高度。

```elisp
(ebox-build
 '(box :width (ch 12) :height (lh 3)
       "ABCDEFGHIJKL\nabcdefghijkl\n0123456789ab"
       (box :position absolute :left (ch 2) :top (lh 1)
            :width (ch 5) :height (lh 1)
            :background-color "#334155" :color "#FFFFFF"
            "Panel")))
```

`:position relative` 保留普通流中的占位，只移动绘制。`:position absolute`
从 normal、Row、Column、Flex 或 Grid 流中移除子节点，并从父内容原点放置。
有符号 `:left` 使用 inline 单位；有符号 `:top` 使用 block 单位，最终放置时
向下取整到宿主的完整行。两者都接受尺寸表达式。局部宿主把合成输出裁剪到自身
画布。嵌套局部分组自动建立：子节点再高的 `:z-index` 也无法越过宿主的兄弟。
整数深度从低到高绘制；同深度的普通内容先于定位内容，定位节点按文档顺序绘制。

上层 Box 的内容、padding 和 border 都遮挡下层，空白也不例外；margin 则保留
下层可见性。可见文本保留原生 help、pointer、hover 和 keymap 属性，被覆盖的
文本不贡献这些交互。下层 retained 节点及语义 ID 仍然存在；遮挡期间更新后，
上层移动或隐藏时会显示下层最新的内容与属性。

使用根图层可把面板绘制到局部裁剪容器之外，同时保留逻辑父节点和继承样式：

```elisp
(ebox-build
 '(box :width (ch 20) :height (lh 4)
       (box :height (lh 1) :overflow hidden
            (box :id "trigger" :width (ch 6) "Open")
            (box :id "panel" :position absolute :layer root
                 :anchor "trigger" :placement bottom-start
                 :width (ch 8) :height (lh 2)
                 "Choice A\nChoice B"))))
```

`:layer root` 选择根内容画布作为绘制目标，不改变 selector、继承或 region 更新
所依据的父子关系。`:anchor` 使用绘制宿主逻辑子树中的唯一语义 ID；两者都要求
绝对定位。placement 支持 `bottom-start`、`bottom-end`、`top-start`、`top-end`，
偏移调整请求的原点。对侧能容纳时，面板纵向翻转，再平移到宿主画布内。anchor
缺失或不可见时不绘制面板；ID 歧义及放置依赖循环会报错。

合成横向使用像素，纵向共享一套文本行网格。定位子树的有效字体行高必须与宿主
相同。裁剪保留完整的受支持文本簇，不完整字形或图像以保留原 face（含背景色）的
非交互空白替代；源内容之外的画布空白仍保持中性。固定 display
space 可以缩短。不提供 alpha 混合、半字形遮罩或 child frame。native reflow
无法表示图层时回退到 Elisp。

包括隐藏节点更新和 rollback 在内的发布仍通过 Ebox publication transaction。固定外部尺寸的
局部修改可以只重新合成受影响的宿主；几何变化或根图层依赖可能需要扩大范围。
不保证每次更新的耗时或所有更新都保持局部。用 `make test` 运行聚焦契约。
独立的 `ebox-playground` 包提供 `layer-minimal.ebox`、`layer-reference.ebox`；
batch 测试不证明 GUI 视觉一致性或远程 CI 成功。

### Box 几何的增量更新

`ebox-region-update-geometry` 是挂载 Box 的底层类型化接口，用于修改位置、尺寸、
边界和堆叠事实。它接受 `:box-sizing`、`:position`、`:left`、`:top`、`:z-index`、
`:layer`、`:anchor`、`:placement`，以及带 min/max 边界的 width/height 属性。
Ebox 按普通单位语法校验值，构造隔离 candidate，并通过与 `ebox-region-update` 相同的
保留式事务发布：

```elisp
(ebox-region-update-geometry
 "panel"
 :left (px 12) :top (lh 2)
 :width (ch 24) :height (lh 4)
 :z-index 3)
(ebox-region-geometry "panel")
;; => (:box-sizing border-box :position absolute :left (px 12) ...)
```

`ebox-region-geometry` 返回当前 Box 有效几何事实的脱离式 plist；省略的声明会使用已
注册的初始值。在显式 update batch 中，它在 flush 前报告上一次已接纳的发布。过期、已
卸载或 Text handle 会报错。padding、margin、border 及其他样式属性仍通过通用的
`ebox-region-update` 更新，因为它们属于样式/布局细节，而不是框架行为共同需要的位置、
尺寸和图层原语。

这个类型化接口不实现指针跟踪、resize handle、focus、最大化/最小化模式或窗口管理策略。
框架行为或应用可以通过 `ebox-keymap-create` 接收手势，再用本接口提交下一组声明式几何。
Ebox 负责校验、保留式布局、遮挡重组、增量发布和回滚；调用方负责交互状态和策略。

### 换行与可选 EKP 依赖

`:wrap-mode word` 按普通单词换行，并允许 CJK 字符换行；`char` 按 Ebox 支持的常见
文本簇边界换行；`none` 保留显式换行符，不添加软换行。`kp` 将段落交给独立的
[EKP 包](https://gitea.gklazycat.heiyu.space/geekinney/ekp)，使用 Knuth–Plass 算法排版。
换行模式属于 Box，并由其中的文本继承。

使用 `:wrap-mode kp` 前，安装 EKP 1.0.0 或更高版本，或将其源码目录加入 `load-path`。
它是按需加载的可选依赖，普通 Ebox 布局只需要 ECSS 和 Ebox publication。选择 `kp` 而没有兼容的
EKP 时，会提示安装或更新；请安装 EKP，或显式选择其他换行模式，不会静默改用单词换行。
EKP 加速器与 Ebox Rust reflow 模块是两个独立的可选模块，启用一个不会安装另一个。

```elisp
(add-to-list 'load-path "/path/to/ekp")
(ebox-render
 (ebox-build '(box :width (ch 40) :wrap-mode kp :overflow hidden
                   "Knuth–Plass considers the paragraph when choosing line breaks.")))
```

Ebox 的文本簇处理会保留常见组合音标、变体选择符、Emoji 修饰符、ZWJ 序列和区域指示符
配对，但不实现完整 Unicode 字素分段或浏览器级双向布局。字形塑造和字形是否可用，
仍取决于 Emacs、所选字体和窗口系统。

<a id="native-node-interaction"></a>
### 原生节点交互

原生编辑或选择回调可以用 `ebox-call-with-input` 包裹输入过程，再应用其返回值。
reader 在所属挂载 buffer 中运行，但编辑由原生 minibuffer／编辑 buffer 持有，
不能直接修改 Ebox 渲染内容：

```elisp
(require 'ebox)
(with-current-buffer (get-buffer-create "*ebox-input*")
  (let ((map (ebox-keymap-create
              :activate
              (lambda ()
                (interactive)
                (let* ((target (ebox-focused-host-ref))
                       (value (ebox-call-with-input
                               target (lambda () (read-string "标题：")))))
                  (message "已接受：%s" value))))))
    (ebox-render-to-buffer
     (current-buffer) (ebox-build `(box :keymap ,map :tab-index 0 "编辑标题")))
    (ebox-focus-first)))
```

该边界不选择窗口；正常返回、错误或取消后，尽可能恢复存续入口的逻辑焦点。
只有原挂载目标仍存在、启用且可访问时才返回 reader 的值，否则抛出 `quit`
子类 `ebox-input-cancelled`。带 key 的重排保留目标；卸载、替换、删除、禁用或
不可访问的入口不会接受结果。reader 错误与用户 quit 继续传播。调用必须在
Ebox publication 事务之外；Ebox 不持有业务值或原生输入 buffer，也不实现第二套文本编辑器。


Text 与所有 Box form 都接受 `:help-echo`、`:pointer`、`:hover-style` 和
`:keymap`，以及节点自身的焦点输入 `:tab-index` 和 `:disabled`。它们是 CSS cascade
之外的显式节点能力。例如，下面的 Box 组合了
动态帮助、手形指针、悬停绘制，以及供鼠标和键盘激活共用的回调：

```elisp
(ebox-render-to-buffer
 "*Ebox Interaction*"
 (ebox-build
  `(box :id "action" :padding ((lh 1) (ch 2))
        :border ((px 1) solid "#5893A3")
        :help-echo ,(ebox-help-create
                     (lambda ()
                       (format-time-string "Help requested at %H:%M:%S")))
        :pointer hand
        :hover-style (:color "#FFFFFF" :background-color "#286477"
                      :text-decoration-line underline)
        :keymap ,(ebox-keymap-create :activate #'describe-mode)
        "Click or press RET / SPC here to describe this buffer's mode.")))
```

`:help-echo` 接受字符串、参数为 `(WINDOW OBJECT POSITION)` 的原生函数或 `nil`。
推荐通过 `ebox-help-create` 适配返回字符串或 `nil` 的零参数业务函数，由 Ebox 提供
悬停 buffer 的上下文。Emacs 在请求帮助时调用函数，DSL 构造树时不会调用它。
`:pointer` 接受 `text`、
`arrow`、`vdrag`、`modeline`、`hand`、`hdrag`、`nhdrag`、`hourglass` 或 `nil`。
帮助的显示方式和指针的具体外观由用户的 Emacs 设置及窗口系统决定。

`:hover-style` 接受 `nil`，或仅包含 `:color`、`:background-color`、
`:text-decoration-line`、`:text-decoration-color`、`:text-decoration-style` 的
Ebox 绘制 plist。同一渲染行中，一个声明节点覆盖的文字与 padding 共享原生
`mouse-face`，未指定属性采用该节点的基础样式；被该悬停覆盖的不同色子文本也使用
同一悬停基础样式。物理左右边框不参与悬停，水平边框线条保持完整；字体度量与几何
不改变。允许的值见
[API 参考](manual.zh-CN.md)。Ebox 将这个 plist 编译为原生
`mouse-face`，不提供任意原生 property 透传。

Box 的帮助、指针和 keymap 覆盖渲染内容、padding 和 border，不包含该 Box 自身的
margin 及结构性换行符；悬停遵循上面的规则。嵌套的 Text 或 Box 可通过显式值替换
每项能力；显式 `nil` 阻止外层值覆盖，
省略属性则保留外层交互范围的覆盖。

`:keymap` 接受原生 Emacs keymap 或 `nil`。推荐使用 `ebox-keymap-create`：
`:activate` 的回调不带参数，处理 `RET`、`[return]`、`SPC` 和 `[mouse-1]`。
挂载界面上的主按钮按下会接管移动与释放事件，按住时将 `:active` 发布给选择器与样式。
在同一存续目标上释放时，先清除状态再激活一次；在其他目标释放则取消激活。
快速双击、三击也各激活一次。在当前选中窗口内释放时，先聚焦被激活的目标，再调用
回调，让回调打开的面板能返回正确入口。为其他窗口分发事件时保留其 point 和选区。
纯渲染文本仍通过原生释放事件激活，
不产生挂载状态。
`:bindings` 接受 alist，按键描述字符串或事件向量对应零参数回调。
辅助函数让鼠标回调在事件窗口的 buffer 中运行，因此回调可以直接按语义 ID 更新：
`(ebox-region-update "action" :help-echo "Activated")`。
显式绑定可以覆盖连击、按下和拖动事件的默认行为。

直接操纵界面时，在相同的 keymap 工厂上提供 `:drag`。下面使用普通 Elisp
保存应用位置，并水平移动已挂载的 Box：

```elisp
(let ((x 0) (origin 0))
  (ebox-render-to-buffer
   "*Ebox drag*"
   (ebox-build
    `(column :width (ch 60)
      (box :id "handle" :position relative :left (px 0)
           :keymap ,(ebox-keymap-create
                     :drag (lambda (gesture)
                             (pcase (plist-get gesture :phase)
                               ('start (setq origin x))
                               ((or 'move 'end)
                                (setq x (+ origin (car (plist-get gesture :delta))))
                                (ebox-region-update "handle" :left (list 'px x))))))
           "水平拖动")))))
```

Ebox 在 keyed 重排后保持初始目标，每次事件前检查当前已发布的归属。
回调完成并 redisplay 后再读取输入，释放事件提供最终位置。离开原文本窗口、
目标或窗口失效会结束跟踪；`C-g` 取消并继续传播 quit。已接受的位置仍由应用持有。
可以同时提供 `:activate` 处理键盘激活，主鼠标按钮序列归 `:drag`。
手势字段和生命周期见[入口文件](../ebox.el)。本接口面向同一 GUI 窗口，
跨窗口／frame 和终端鼠标拖动尚未验证。

使用 `M-x ebox-activate` 调用当前节点的 RET 命令，或通过 `(ebox-activate position)`
指定可访问位置。它只使用已提交节点的 keymap，遵循继承与显式 nil 屏蔽；overlay/global
map、结构换行和不可见文本不构成目标。框架不移动 point 或选择窗口。目标缺失时报
`user-error`；`(ebox-activate position t)` 在无目标时返回 nil，但不吞掉回调错误。
每次调用读取最新发布状态，替换、回滚和卸载无需另建激活注册表。

使用键盘绑定时，先把 point 移到交互范围内。可选命令 `ebox-next-interaction` 与
`ebox-previous-interaction` 在当前渲染了可用 keymap 的声明节点之间移动。每个 owner
只有一个停靠点，即使其 map 覆盖 padding 或多行；显式子 map 单独形成停靠点。
空 map、显式 `nil`、不可见或被裁掉的内容不产生停靠点。导航读取当前已提交 buffer，
更新后不需要额外刷新。到达边界时报用户错误，不循环跳转，也不移动 point。
这些命令不会自动添加按键绑定。要把共享按键改为 keymap-owner 导航，可以配置：

```elisp
(keymap-set ebox-buffer-mode-map "TAB" #'ebox-next-interaction)
(keymap-set ebox-buffer-mode-map "<backtab>" #'ebox-previous-interaction)
```

仍可直接传入原生 keymap，其鼠标命令需要自行处理事件的目标 buffer。Ebox 使用原生
命令分派，不创建应用状态。单独设置手形指针不会绑定点击命令。

`:tab-index` 的非负整数值声明逻辑焦点导航停靠点，按数值、buffer 起点和终点升序排列。
负整数允许显式设置焦点，但跳过导航；nil 或省略不创建停靠点。`:disabled t` 排除该节点
的焦点，并阻断自身或继承的 keymap。两个输入仅约束声明节点；子节点仍可独立声明
启用的 keymap。用 `:disabled nil` 恢复原来声明的 keymap，通过普通 `ebox-region-update`
或 canonical commit 发布。同一禁用事实派生供选择器查询与 cascade 使用的 `:disabled`，
包括后代与兄弟规则；禁用父节点不会将子节点标记为禁用。作者 `:states`（typed 输入的
`:selector-state`）可以声明自定义状态，但拒绝 `disabled`、`focus` 与 `active`，分别
应使用 `:disabled t`、挂载后的焦点操作和生成的主按钮手势。
例如 `("#action:active" :color "#ff0000")` 使用普通 cascade。按下状态跟随存续目标
的更新，跟踪结束或目标不可用时清除；拖动回调在跟踪期间可以观察它，激活回调在清除后
运行。按下样式必须让新请求的目标保持可见且启用，否则按下失败并保留原画面。键盘
激活不产生此状态。悬停状态接入 cascade 仍待完成。

焦点变更在同一次事务中发布 `:focus` 选择器状态、绘制与布局。局部规则
`(("box:focus" :color "#ff0000"))` 只匹配获得焦点的 Box，后代与兄弟选择器也使用同一
cascade。焦点属于具体 buffer；同一输入的纯渲染和其他挂载不会继承它。作者状态
不能声明 `focus`。焦点规则让新请求的目标隐藏或完全被裁剪时，设置失败并保留旧画面。
普通更新隐藏或裁剪已有焦点时，在发布前清除焦点并重新计算样式；拒绝更新则恢复旧状态
与绘制。清空焦点保留数值 point，新布局变短时限制到可访问范围。发布观察者也会收到
焦点变更的报告。

菜单和对话框可将面板的 Host 引用传给 `ebox-focus-within`。省略步数时选择
已提交子树中的首个有效停靠点；步数为 1／-1 且循环参数为 t 时，在区域内
前进／后退。隐藏、禁用和被遮挡的控件复用普通焦点导航的绘制可用性判断。
零步查询当前焦点是否属于该区域。它不安装按键或持续的模态限制；上层负责
打开、关闭及按键策略，并通过 `ebox-focus` 恢复仍有效的入口。

`ebox-focus-next` / `ebox-focus-previous` 操作逻辑焦点，第二个可选参数允许循环。
`ebox-focus-first` 选择第一个有效停靠点；没有停靠点时保持原焦点和 point。
焦点变更不能加入尚未接受的 Ebox publication 事务：设置、清空或移动焦点会在修改焦点与 point 前
抛出错误。应在事务接受后调用，也可使用 `after-commit` 回调。只读的
`ebox-focused-host-ref` 和零步导航仍可使用，避免外层回滚遗留未被接受的焦点变更。
它们返回不透明 Host 引用，供 `ebox-focus` 和 `ebox-focused-host-ref` 使用；框架也可以
传入自己的 source-builder identity。`ebox-focus` 接受 nil 清空焦点；显式设置允许任何
已启用且可见的节点，不要求 tab index 或 keymap。完整签名和错误约束见
[ebox.el](../ebox.el)。

```elisp
(ebox-render-to-buffer
 "*Ebox Focus*"
 (ebox-build '(column (text :key first :tab-index 0 "First")
                     (text :key second :tab-index 0 "Second"))))
(with-current-buffer "*Ebox Focus*"
  (let ((first (ebox-focus-next)))
    (ebox-focus-next 1 t)
    (ebox-focus first)))
```

焦点首先跟随仍存在的显式 source identity；旧引用失效时，只有保留节点中相同的非 nil
兄弟 key 可以维持焦点，无 key 的替换节点不会接管被移除的焦点。

焦点属于已挂载 buffer，不选择窗口，也不为同一个 buffer 的每个窗口维护独立焦点。
Keyed 重排跟随保留节点，即使新输入给出新的 source handle；发布后应查询当前引用，
不要继续使用上一代自动生成的引用。point 仍位于焦点节点首个可见字符时，发布跟随它
的新位置；手动移开 point 后，保留其数值位置，并限制在当前可访问范围内。发布删除、
隐藏或禁用会清空焦点并保留这个受限位置，随后导航从首个／末个有效停靠点开始。
发布被拒绝时恢复原焦点和 point；卸载和 buffer 关闭释放焦点。导航和显式设置还检查
narrowing 与不可见 overlay。

`ebox-activate` 不传位置时，若 point 仍位于焦点首个可见字符，优先选择该逻辑焦点的
自身或继承 keymap，即使子节点的 map 覆盖同一字符；传入显式位置则始终按位置选择。
`ebox-keymap-create :activate` 生成的 RET、return 与 SPC 使用相同的焦点优先级。
鼠标始终执行点击位置的绑定。自定义按键及直接传入的原生 keymap 命令保持其原生行为。

挂载后的 `ebox-buffer-mode` 通过 `ebox-buffer-mode-map` 提供循环 TAB 与
Shift-TAB/backtab 导航及 RET/return 激活。独立 Ebox 与框架调用方都在成功挂载后
启用它，卸载时禁用，不要求额外的应用输入模式。手动禁用该 mode 移除 buffer 绑定，
节点自身的原生 keymap 仍有效。

Playground 的[交互实验室](https://gitea.gklazycat.heiyu.space/geekinney/ebox-playground/src/branch/main/README.zh-CN.md#native-interaction-lab)
把业务函数与状态放在 `interaction-reference.el`，把布局放在
`interaction-reference.ebox`，展示回调、嵌套覆盖，以及通过公共 region 更新替换或
清除四种能力。

## 5. 渲染与发布

`ebox-render` 返回带属性文本，不修改 live buffer；`ebox-render-to-buffer` 挂载
retained Ebox publication surface 并返回 buffer。它们和 `ebox-display-buffer` 都接收
`ebox-build` 返回的不透明值。

```elisp
(ebox-render ebox-guide-input)
(ebox-render-to-buffer "*Ebox Guide*" ebox-guide-input)
```

需要同时显示结果时，使用 `ebox-display-buffer`。它先完成渲染，再让 Emacs 放置
buffer，遵循 `display-buffer-alist`，并接受与原生 `display-buffer` 相同的可选 action：

```elisp
(ebox-display-buffer "*Ebox Guide*" ebox-guide-input
                     '(display-buffer-pop-up-window))
```

它返回 buffer，不选中结果窗口，也不删除其他窗口。渲染报错不会改变窗口布局。
自定义 display action 仍可能产生自己的窗口效果；如果 action 在发布后报错，
已经成功渲染的 buffer 仍然保留。调用方完全管理显示位置时，使用 `ebox-render-to-buffer`。

重新构建 canonical input 后，用 `ebox-commit` 原子更新：

```elisp
(ebox-commit
 "*Ebox Guide*"
 (ebox-build
  '(column :padding ((lh 1) (ch 2))
           (text "Updated notes")
           (box :key body "The new input is caller-owned."))))
```

验证、渲染或发布失败时，旧 buffer 与 runtime 状态保持不变。
`ebox-buffer-update-report` 返回最近一次成功更新报告的防御性副本。

通过 `ebox-buffer-set-observer` 开启观察时，`:phase-duration-ms` 按 source、style、
plan、layout、projection、transaction 给出独占毫秒数。嵌套阶段只记一次，总和等于
Ebox 的观测总时长；transaction 包含其余提交／Ebox publication 工作，与 Ebox publication 的单独报告重叠。
工作区通用工具在 trace pass 消费这些字段，CPU 与分配采样分别执行。

`:native-declined-reason` 说明原生执行前缺少的输入能力，例如视口尺寸未确定或存在
定位节点；`:native-fallback-reason` 说明原生执行尝试未能生成受支持结果的原因。
两者均保留正常的 Elisp 渲染。模块已经加载，不代表某次交互实际使用了原生布局。

可选字段 `:projection-rejections` 以
`(:projection KIND :reasons (REASON ...))` 记录局部尝试。目前覆盖混合局部规划，
以及已选局部计划在生成输出时退回普通投影的情况：

`fragment-ledger` 还会记录局部替换无法复用片段解析的原因，例如边界不对齐、缺少
保留的来源事实或行拓扑变化。角色变化可以保留未变片段的解析并重新计算目标归属，
不必因此退回整页解析。

| 原因 | 拒绝该尝试的能力边界 |
| --- | --- |
| `geometry-allocation` | 没有可用的局部几何分配证明。 |
| `native-property-composition` | 混合绘制合成器不能发布变化的原生 surface 属性。 |
| `paint-composition` | 外部绘制 owner 不满足合成器约束。 |
| `candidate-style-preparation` | 候选样式尚未完整准备，不能局部复用。 |
| `retained-style-closure` | 已发布的样式绑定不能安全表达候选状态。 |
| `overlapping-output` | 几何与绘制输出无法按支持的互不重叠方式组合。 |
| `output-proof` | 已选局部计划无法生成经过证明的局部输出。 |

一次尝试可以有多个独立拒绝原因。这不是完整的证明追踪，缺少记录不代表满足局部条件。
其他局部路径仍可能成功；实际发布路径以最终 `:projection-kind` 为准。原因不表示耗时归因。
`make update-effects-performance` 额外执行两次开启观察的更新，覆盖两个状态，
将原因汇总为 `rejection_counts`。这两次执行相同的正确性检查，但不计入延迟样本和
`projection_counts`；`diagnostic_updates` 记录其次数。普通更新不收集这些详细诊断。

## 6. 查询和更新 mounted surface

`:id`、`:class` 与 `:key` 是 author metadata。Selector 使用 ECSS 语义。
在目标已挂载 buffer 中，可以直接传入语义 `:id`：

```elisp
(with-current-buffer "*Ebox Guide*"
  (ebox-region-update "status" :color "#166534"))
```

需要显式指定 buffer 时，把 `:id` 解析为不透明、surface-scoped 的 handle：

```elisp
(let ((handle (ebox-region-resolve "*Ebox Guide*" "status")))
  (ebox-region-update handle :color "#166534"))
```

节点仍保留在同一父节点下时，可以继续使用已有 handle；插入或重排兄弟节点不会
使它失效。替换节点的逻辑身份、移除节点或重新挂载 buffer 后，应重新解析 handle。

同一 API 可以替换 Text 或 Box region 的原生能力。对上面的交互示例：

```elisp
(with-current-buffer "*Ebox Interaction*"
  (ebox-region-update "action" :help-echo "Updated help" :pointer 'arrow
                      :hover-style '(:background-color "#F6D6AB"))
  (ebox-region-update "action" :help-echo nil :pointer nil
                      :hover-style nil :keymap nil))
```

更新参数是正常求值的 Elisp，因此符号和字面量 plist 需要 quote；它们与已经被 quote
的 DSL 数据不同。省略的更新属性保持不变，显式 `nil` 清除对应能力并阻止外层值覆盖。
Ebox 对 keymap 创建快照；发布新绑定时应替换 `:keymap`，而不是修改原 map。
清除节点 keymap 后，普通 buffer 和全局绑定仍然可用。

`ebox-selector-query-buffer` 按文档顺序返回 mounted buffer 中的匹配；
`ebox-selector-update-buffer` 对所有可编辑匹配应用一次样式更新。数字 region id
只是诊断用渲染 metadata，不是稳定更新 handle。

一个操作需要多次更新 region 时，可以合并这些更新：

```elisp
(ebox-call-with-update-batch
 (lambda ()
   (ebox-region-update "status" :help-echo "Ready")
   (ebox-region-update "status" :color "#166534")
   'ready)
 (get-buffer "*Ebox Guide*"))
```

回调在指定 buffer 中运行，省略 buffer 时使用当前 buffer；本例的 helper 返回
`ready`。helper 只 flush 一次自己拥有的非空 batch；已有 batch 时，由外层拥有者
负责 flush。非局部退出会恢复到本次调用前的待处理状态，自己拥有的 batch 若
flush 失败则保留上次已提交 surface。回调中的其他业务副作用不会被撤销。嵌套、
no-op 和显式生命周期行为见[批量更新契约](manual.zh-CN.md)。

## 7. Resize 与滚动

内容超过有限高度时，`:overflow scroll` 会创建内部 scroll window。键盘滚动以
文本光标（point）为目标；鼠标和触摸板滚动以事件中的鼠标位置为目标。剩余滚动距离
沿包含该位置的 scroll owner 从内向外传递，最后交给普通 Emacs 滚动。鼠标位于
其他栏、盒子外或 mode line 时，不会选取页面中无关的滚动盒子。

```elisp
(ebox-build
 '(box :id log :width (px 420) :height (lh 8) :overflow scroll
       "line 1\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7\nline 8\nline 9"))
```

可见 mounted buffer 会跟随选定的一个显示窗口。每个已挂载 buffer 只有一套视口布局：
将同一个 buffer 同时放到不同宽度的窗口中，不会产生两套独立布局。每个视图需要
各自宽度时，把同一份 canonical input 分别挂载到不同 buffer。集成层也可以显式应用
viewport，横向以像素、纵向以行为单位：

```elisp
(ebox-rerender-buffer-with-context
 (get-buffer "*Ebox Guide*") 800 30)
```

## 8. 公共 API

受支持的接口清单、调用参数和使用说明统一放在
[`ebox.el`](../ebox.el) 开头的 Commentary 中。未列出的符号均属于内部接口，
与是否含双连字符无关。本手册说明使用流程与集成契约。

## 9. 验证

```sh
make load EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make compile EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make test EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make check EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
```

## 框架集成契约

Ebox 通过 `(require 'ebox)` 提供 framework SPI v3，面向 ETAF 等框架实现者；
普通应用使用前面的渲染和更新入口。先调用 `ebox-framework-spi-capabilities` 获取
不可变 provider，并用 `ebox-framework-spi-validate-provider` 验证，再保存公共
operation descriptor。不得读取私有 provider 字段。

| 操作 | 输入与结果 |
| --- | --- |
| `ebox-framework-spi-initial` | 未挂载 buffer、canonical input 和 stage/rollback 回调对；返回传给回调的同一份已完成报告。不允许加入外层 Ebox publication 事务。 |
| `ebox-framework-spi-update` | 已挂载 buffer、canonical input 或 candidate，以及回调对；返回 stage 回调看到的同一个报告对象。 |
| `ebox-unmount-buffer` | 释放挂载，使该 buffer 可以建立新的 initial generation。 |

框架管理应用状态，Ebox 管理布局与 runtime indexes，Ebox publication 管理 buffer 发布和事务。
stage 在临时 Ebox publication 与 Ebox 状态一致后执行。回滚依次恢复框架、Ebox、Ebox publication 状态。
initial 失败时恢复编辑器状态，包括文本、point、mark、narrowing、overlay、undo 与
modified 标志；已被销毁的 buffer 不会被复活。提交接受后的观察者或 retirement 错误
是诊断信息，不能把已经完成的提交当作回滚。调用方必须同时提供两个回调并传播失败，
不得失败后切换另一个写入器。精确参数以对应函数 docstring 为准。

```elisp
(require 'ebox)
(let ((buffer (generate-new-buffer " *framework-example*")))
  (unwind-protect
      (progn
        (ebox-framework-spi-validate-provider (ebox-framework-spi-capabilities))
        (ebox-framework-spi-initial buffer (ebox-build '(box "Initial"))
                                    #'ignore #'ignore)
        (ebox-framework-spi-update buffer (ebox-build '(box "Updated"))
                                   #'ignore #'ignore)
        (with-current-buffer buffer (buffer-string)))
    (ebox-unmount-buffer buffer)
    (kill-buffer buffer)))
```

`tests/acceptance.json` 列出当前保留的公共 API 验收场景。消费方链接到本契约，
不再复制一份回调时序说明。


### 组合属性与结构更新

框架在已有 Host 的自身声明变化时使用 `ebox-candidate-update-host-properties`。
传入前后两代规范作者输入；旧输入描述候选捕获的已发布基线，重复调用也使用
该基线。只有匹配 Host 的局部属性参与变化，输入中的文本与子节点被忽略，
因此只构造该节点即可。Ebox 保留当前内容、子节点与身份，并决定样式、布局
及交互影响。

下面只改变面板宽度，保留原有标签：

```elisp
(require 'ebox)
(cl-labels
    ((panel (width &optional text)
       (let* ((builder (ebox-source-builder-create))
              (decls (ebox-style-compile-form 'column (list :width width)))
              (handle (ebox-source-builder-bind builder :identity 'panel
                                                :declarations decls))
              (children
               (when text
                 (list (ebox-text-create
                        :value text
                        :source-handle (ebox-source-builder-bind builder :identity 'label)
                        :owned-facts (ebox-canonical-facts-from-declarations 'text nil)))))
              (node (apply #'ebox-box-create
                           (append (ebox-canonical-box-configuration 'column decls)
                                   (list :source-handle handle :children children
                                         :owned-facts
                                         (ebox-canonical-facts-from-declarations 'column decls))))))
         (ebox-canonical-input-create (list node) (ebox-source-builder-finish builder)))))
  (let* ((buffer (get-buffer-create "*Ebox Properties*"))
         (previous (panel '(ch 32) "Retained content"))
         (next (panel '(ch 18))))
    (ebox-render-to-buffer buffer previous)
    (let ((candidate (ebox-candidate-begin buffer)))
      (ebox-candidate-update-host-properties candidate 'panel previous next)
      (ebox-commit buffer candidate))))
```

同一候选可以替换后代 Host 或子 Range。属性更新在结构操作后作用于保留的
节点；移除节点吸收它的更新，完整根替换吸收全部操作。同一节点的重复属性
更新使用最后一次提交的声明差异。节点类型变化必须使用子树替换。未知基线
引用、非法输入和已封存候选会报错；调用方不需要判断变化是否仅涉及绘制。
提交只消费候选一次，发布失败也不能复用该候选。

对于更新后仍然存在的节点，保持其 source identity 稳定。子树和 Range 替换
都先匹配 author key，再匹配无 key 节点的 source identity；移动保留节点不需要
在每一层额外添加 key。发布后，节点的焦点和后代 Range 地址仍然有效。

## 局部规则输入

`:ecss` 接受有序规则列表，`:ecss-file` 按 ECSS 的[静态数据契约](https://gitea.gklazycat.heiyu.space/geekinney/ecss/src/branch/main/docs/manual.zh-CN.md#静态规则数据)
从文件读取同一列表。文件不加 quote 包装；普通 Elisp 表达式仍正常引用
字面量列表。文件规则先于行内 `:ecss` 规则。Ebox 通过 ECSS 与自己的属性
schema 校验选择器和声明。规范输入构造者调用 `ebox-style-compile-rules`，
将结果传给 `ebox-source-builder-bind` 的 `:ecss` 字段，与 DSL 使用同一路径。

规范输入生产者还可在该 source binding 中传入 `:ecss-targets`。默认 t 允许
所有后代；proper list 按 `equal` 比较 source 的 `:identity`，限定规则目标；
nil 禁用该作用域的规则。绑定时保存列表快照，渲染时在候选 source index 中
解析身份，缺失目标在发布前报错。不在挂载 source 子树内的目标不会匹配。
例如根绑定使用 `:ecss-targets '(slot)` 和 `.title` 规则时，可以样式化子组件
之下身份为 `slot` 的 source，同时排除其他匹配后代。生产者必须把该身份绑定在
同一规范输入中。这属于规范集成元数据，不是新增 DSL 字段。

目标集合只限定规则接收者，不改变结构选择器关系或计算值继承。所有权变化时
构造新规范输入；候选失败保留已提交的所有权和显示。导出的规范快照保留目标集合，
可以独立重新挂载。

规范 Box 构造者使用 `ebox-canonical-box-configuration`，从规范声明取得
`:layout` 和 `:outer` 构造字段。DSL 使用同一投影：Ebox 缓存具体配置，带 ECSS
标记的值等待层叠计算。返回的 plist 独立于缓存，其中的类型化 LayoutConfig
不可变。非法 tag、声明上下文或具体值会报错。完整声明仍需保留在 source binding
中，并据此生成 owned facts，让延迟值参与渲染和更新。

```elisp
(require 'ebox)
(require 'ecss)
(let* ((declarations (ebox-style-compile-form
                      'flex (list :flex-direction (ecss-important 'column))))
       (builder (ebox-source-builder-create))
       (handle (ebox-source-builder-bind builder :declarations declarations))
       (child-input (ebox-build '(box "Child")))
       (children (ebox-canonical-input-import-roots
                  child-input (ebox-canonical-input-roots child-input) builder))
       (node (apply #'ebox-box-create
                    (append (ebox-canonical-box-configuration 'flex declarations)
                            (list :children children :source-handle handle
                                  :owned-facts (ebox-canonical-facts-from-declarations
                                                'flex declarations))))))
  (ebox-render (ebox-canonical-input-create
                (list node) (ebox-source-builder-finish builder))))
```

## 共享样式作用域

框架通过 `ebox-style-scope-create` 创建不可变作用域描述，输入仍是各样式入口
共用的有序规则列表。可选 `:origin` 使用 ECSS 来源语义，因此主题可以提供 UA
默认值，组件规则仍作为 author 声明。非法规则或来源会报错，不改变已有描述。
描述不拥有 buffer 或运行时资源，无需释放；规则输入被快照保存，修改规则时创建
新描述。保留成员更新时，调用
`(ebox-style-scope-with-rules scope rules :origin 'author)`，将返回值绑定到根。
此操作保留作用域身份，成员可继续携带任意旧版本；每个根使用自身绑定的规则版本，
旧输入保持不变。非法更新报错且不修改已有描述。来源默认 author，更新 UA 默认值
时需再次指定来源。

每个规范 source 通过 `:ecss-scopes` 列出所属作用域，通过 `:ecss-scope-roots`
列出自身作为哪些作用域的根。两者都接受作用域身份不重复的 proper list，非法输入
在绑定时报错。根与成员身份相互独立：成员只有位于某个已标记根的子树内才能接收
规则；根自身也必须是成员，才能接收 `&` 或 `:scope` 规则。普通选择器匹配严格
后代。一个描述可有多个根，每个根独立挂载；结构关系和继承仍使用规范节点树。

父组件提供的 slot 可以在子组件根下携带父描述，fallback 携带子描述。动态内容
携带已有描述即可，无需改写祖先上的目标列表。输入中没有根的描述不贡献规则，
因此可以先组合独立片段，再接入其外部根。规范导入、保留更新和快照均保留这些
事实，失败候选保留已提交归属。应用之间可以共享描述中的不可变规则，不共享
live 状态。

在层叠 source order 中，共享作用域排在 source 局部 `:ecss` 作用域之后。
共享描述之间按首个根的文档顺序、该根列表内的顺序排序；specificity、origin、
importance 和作用域距离仍遵循 ECSS。两个根可共享展示规则，无需为作用域增加
可见节点：

```elisp
(require 'ebox)
(let* ((scope (ebox-style-scope-create '(("&" :color "#ff0000"))))
       (builder (ebox-source-builder-create))
       (children
        (mapcar
         (lambda (label)
           (ebox-text-create
            :value label
            :source-handle (ebox-source-builder-bind
                            builder :ecss-scopes (list scope)
                            :ecss-scope-roots (list scope))
            :owned-facts (ebox-canonical-facts-from-declarations 'text nil)))
         '("First root" "Second root")))
       (root (ebox-box-create
              :layout (ebox-column-layout-create) :children children
              :source-handle (ebox-source-builder-bind builder)
              :owned-facts (ebox-canonical-facts-from-declarations 'column nil))))
  (ebox-render (ebox-canonical-input-create
                (list root) (ebox-source-builder-finish builder))))
```

## 需要计算的声明值

程序构造的样式可使用 `ecss-important`、`ecss-wide-value` 和 `ecss-var`。
Longhand 值在绘制和布局前计算；importance 也保留已支持的 shorthand 展开。
在 Elisp 中构造这些值：

```elisp
(ebox-render
 (ebox-build
  (list 'box '--accent "#334155"
        (list 'text :color (ecss-var '--accent "#000000") "Accent"))))
```

Custom property 在规则列表、行内声明及 `ebox-region-update` 中均使用
`--name` 符号，其继承值可以影响绘制或几何。修改 custom property 会重新
计算保留的消费者；行内与规则的 important 声明参与 ECSS 优先级计算。非法
具体值仍在发布前被拒绝。变量解析和非法计算值遵循 ECSS 的 schema 回退
约定。静态 `.ecss` 文件仍只读数据，不调用这些构造函数。上下文相关的
shorthand 值请显式写成 longhand；当前接口尚未实现延迟的多值 shorthand 替换。
