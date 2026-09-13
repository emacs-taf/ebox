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
介绍的四种原生节点能力。padding、margin、border、
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

包括隐藏节点更新和 rollback 在内的发布仍通过 TP transaction。固定外部尺寸的
局部修改可以只重新合成受影响的宿主；几何变化或根图层依赖可能需要扩大范围。
不保证每次更新的耗时或所有更新都保持局部。用 `make layer-tests` 运行聚焦契约。
独立的 `ebox-playground` 包提供 `layer-minimal.ebox`、`layer-reference.ebox`；
batch 测试不证明 GUI 视觉一致性或远程 CI 成功。

### 换行与可选 EKP 依赖

`:wrap-mode word` 按普通单词换行，并允许 CJK 字符换行；`char` 按 Ebox 支持的常见
文本簇边界换行；`none` 保留显式换行符，不添加软换行。`kp` 将段落交给独立的
[EKP 包](https://github.com/Kinneyzhang/emacs-kp)，使用 Knuth–Plass 算法排版。
换行模式属于 Box，并由其中的文本继承。

使用 `:wrap-mode kp` 前，安装 EKP 1.0.0 或更高版本，或将其源码目录加入 `load-path`。
它是按需加载的可选依赖，普通 Ebox 布局只需要 ECSS 和 TP。选择 `kp` 而没有兼容的
EKP 时，会提示安装或更新；请安装 EKP，或显式选择其他换行模式，不会静默改用单词换行。
EKP 加速器与 Ebox Rust reflow 模块是两个独立的可选模块，启用一个不会安装另一个。

```elisp
(add-to-list 'load-path "/path/to/ekp/lisp")
(ebox-render
 (ebox-build '(box :width (ch 40) :wrap-mode kp :overflow hidden
                   "Knuth–Plass considers the paragraph when choosing line breaks.")))
```

Ebox 的文本簇处理会保留常见组合音标、变体选择符、Emoji 修饰符、ZWJ 序列和区域指示符
配对，但不实现完整 Unicode 字素分段或浏览器级双向布局。字形塑造和字形是否可用，
仍取决于 Emacs、所选字体和窗口系统。

<a id="native-node-interaction"></a>
### 原生节点交互

Text 与所有 Box form 都接受 `:help-echo`、`:pointer`、`:hover-style` 和
`:keymap`。它们是 CSS cascade 之外的显式节点能力。例如，下面的 Box 组合了
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
快速双击、三击的每次释放也各激活一次；主按钮按下和拖动默认不执行操作，保留 point
和选区，避免触发原生的选词或整行选择。
`:bindings` 接受 alist，按键描述字符串或事件向量对应零参数回调。
辅助函数让鼠标回调在事件窗口的 buffer 中运行，因此回调可以直接按语义 ID 更新：
`(ebox-region-update "action" :help-echo "Activated")`。
显式绑定可以覆盖连击、按下和拖动事件的默认行为。

使用键盘绑定时，先把 point 移到交互范围内。可选命令 `ebox-next-interaction` 与
`ebox-previous-interaction` 在当前渲染了可用 keymap 的声明节点之间移动。每个 owner
只有一个停靠点，即使其 map 覆盖 padding 或多行；显式子 map 单独形成停靠点。
空 map、显式 `nil`、不可见或被裁掉的内容不产生停靠点。导航读取当前已提交 buffer，
更新后不需要额外刷新。到达边界时报用户错误，不循环跳转，也不移动 point。
这些命令不会自动添加按键绑定。例如，为启用了 `ebox-buffer-mode` 的 buffer 选择启用：

```elisp
(keymap-set ebox-scroll-map "TAB" #'ebox-next-interaction)
(keymap-set ebox-scroll-map "<backtab>" #'ebox-previous-interaction)
```

仍可直接传入原生 keymap，其鼠标命令需要自行处理事件的目标 buffer。Ebox 使用原生
命令分派，不创建应用状态或焦点管理系统。单独设置手形指针不会绑定点击命令。

Playground 的[交互实验室](https://gitea.gklazycat.heiyu.space/geekinney/ebox-playground/src/branch/main/README.zh-CN.md#native-interaction-lab)
把业务函数与状态放在 `interaction-reference.el`，把布局放在
`interaction-reference.ebox`，展示回调、嵌套覆盖，以及通过公共 region 更新替换或
清除四种能力。

## 5. 渲染与发布

`ebox-render` 返回带属性文本，不修改 live buffer；`ebox-render-to-buffer` 挂载
retained TP surface 并返回 buffer。它们和 `ebox-display-buffer` 都接收
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

## 8. 独立 `.ebox` 文件

`.ebox` 文件包含一个普通 Elisp 表达式，其求值结果就是交给 `ebox-build` 的布局
数据。静态布局对整个列表加 quote：

```elisp
'(column :padding ((lh 1) (ch 2))
         :cross-align center
         (text :color "#263244" "Title")
         (box :width (px 240) "Body"))
```

同级 `ebox-playground` 读取唯一一个表达式，以词法绑定求值，再将得到的数据传给
`ebox-build`，不再单独求值属性或子节点。这与 `.el` 中 `(ebox-build ...)` 的参数
表达式完全一致；在 `.ebox` 中只需省略外层的 `ebox-build` 调用。

必要的业务函数与变量放在布局旁边的同名 `.el` 文件中。预览 `notes.ebox` 时，如果
存在 `notes.el`，Playground 会在每次求值布局前加载它；`C-c C-c`、
`ebox-playground-open-file` 和文件渲染入口都遵循这个顺序。加载的是指定的 `.el`
源码，因此保存修改后再次预览即可生效，不使用 `require` 缓存，也不优先选择旧的
`.elc`。没有配套文件时，独立 `.ebox` 仍可使用；配套文件加载出错时，渲染停止，
不会继续求值布局。

例如，由 `notes.el` 定义数据与操作：

```elisp
;;; notes.el --- Notes example behavior -*- lexical-binding: t; -*-
(defvar notes-body "A long article.")

(defun notes-help ()
  "Return business help for the article."
  (format "Article: %s" notes-body))

(defun notes-activate ()
  "Mark the article in the current Ebox buffer."
  (ebox-region-update "article" :color "#166534"))
```

`notes.ebox` 专注表达布局：

```elisp
`(column :padding ((lh 1) (ch 2))
         (box :id "article" :width (px 480)
              :help-echo ,(ebox-help-create #'notes-help)
              :pointer hand
              :keymap ,(ebox-keymap-create :activate #'notes-activate)
              ,notes-body))
```

反引号保留布局数据，`,` 插入值，`,@` 展开子节点列表。不要仅为了隐藏重复 DSL
属性列表而添加辅助函数。每次预览先加载配套文件，再求值一次布局；普通 Elisp
变量定义决定应用状态是初始化、保留还是重置。

旧的属性求值格式需要显式迁移：静态布局在最外层加 quote，去掉内部 list 和 symbol
属性的 quote；动态布局使用反引号，并在需要求值的位置加逗号。例如，旧的
`:padding '(1 2)` 改成引用列表内的 `:padding ((lh 1) (ch 2))`；计算像素宽度时，
在反引号列表内写 `:width (px ,(+ 200 40))`。
不再自动将裸结构 form 解释为 DSL，也不自动识别旧格式。

## 10. 可选 native reflow 与验证

Rust 模块是可选加速器，Ebox 加载时不会构建它：

```elisp
(ebox-native-status)
(ebox-native-build)
```

在仓库根目录运行：

```sh
make docs-contract-tests EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make interaction-tests EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make dsl-tests EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make check EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
```


## 接口参考

[English](manual.md)

本文描述独立 Ebox 包当前的公共边界，并把普通 author 路径与框架集成使用的
evaluated typed API 分开。以 `ebox--` 开头的名称都是私有实现。

Ebox 需要 Emacs 29.1 或更高版本、ECSS 0.1.0 或更高版本，以及 TP 2.0.0 或更高版本。
EKP 1.0.0 或更高版本是 `:wrap-mode kp` 所需的可选依赖；`word`、`char`、`none`
不加载它。EKP 缺失或不兼容时会给出可操作的错误，不会静默改变换行算法。
源码加载方式和各项依赖职责见[安装说明](../README.zh-CN.md#安装)。

```elisp
(require 'ebox)
```

## 2. Evaluated typed construction

已经拥有 author parsing 的框架可以使用 evaluated 集成 API；它不是第二套 author
语法。一个 `ebox-source-builder` 拥有完整 source generation；每个 typed node 都携带
该 builder 返回的 handle，以及由同一份 normalized declarations 投影出的 node-owned
facts。最后用一个 `CanonicalEboxInput` 同时传递 forest 与封存的 source index：

```elisp
(let* ((builder (ebox-source-builder-create))
       (root-declarations nil)
       (left-declarations nil)
       (right-declarations nil)
       (root-handle
        (ebox-source-builder-bind
         builder :declarations root-declarations))
       (left-handle
        (ebox-source-builder-bind
         builder :declarations left-declarations))
       (right-handle
        (ebox-source-builder-bind
         builder :declarations right-declarations))
       (left
        (ebox-text-create
         :value "Left"
         :source-handle left-handle
         :owned-facts
         (ebox-canonical-facts-from-declarations
          'text left-declarations)))
       (right
        (ebox-text-create
         :value "Right"
         :source-handle right-handle
         :owned-facts
         (ebox-canonical-facts-from-declarations
          'text right-declarations)))
       (root
        (ebox-box-create
         :layout (ebox-row-layout-create
                  :item-gap '(ch 1) :cross-align 'center)
         :children (list left right)
         :source-handle root-handle
         :owned-facts
         (ebox-canonical-facts-from-declarations
          'row root-declarations))))
  (ebox-canonical-input-create
   (list root)
   (ebox-source-builder-finish builder)))
```

- `ebox-source-builder-create` 开始且只开始一次 mutable source assembly；
- `ebox-source-builder-bind` 保存 normalized source facts，并返回只含 identity 的
  opaque handle；
- `ebox-source-builder-finish` 分离并封存 builder 的 immutable fact index；封存后
  builder 拒绝继续修改；
- `ebox-canonical-facts-from-declarations` 从传给 source builder 的同一份 normalized
  declarations 投影 node-owned facts；
- `ebox-text-create` 要求 `:value`、`:source-handle` 与 `:owned-facts`；
- `ebox-normal-layout-create` 构造 Normal LayoutConfig；
- `ebox-row-layout-create` 与 `ebox-column-layout-create` 接受
  `:item-gap` 和 `:cross-align`；
- `ebox-flex-layout-create` 构造经过验证的 Flex LayoutConfig；
- `ebox-grid-layout-create` 构造经过验证的 Grid LayoutConfig；
- `ebox-box-create` 要求 `:layout`、`:source-handle` 与 `:owned-facts`，并接受 typed
  node 的 `:children` list；
- `ebox-canonical-input-create` 把有序 node forest 与拥有其中全部 handle 的唯一
  source index 组合为一个值；这个边界验证精确 handle 集合，并从 forest 的最终
  preorder 封存 source order，不依赖 bottom-up 构造顺序。
- `ebox-canonical-input-root-host-ref` 返回经过验证的 single-root input 的分离发布
  地址，不暴露其中的 source handle；
- `ebox-canonical-input-roots` 返回 exact top-level roots 的 shallow、只读副本，
  不会把 source facts 导入另一个 candidate；
- `ebox-canonical-input-import-roots` 只接受该 input 中 exact、唯一的 top-level
  roots 与一个 open source builder；它只导入选中 subtree 的 facts，保留 node、
  source-handle 与 immutable record identity，绝不接管未选 root 的 facts；
- `ebox-canonical-input-equal-p` 比较完整 canonical forest、Range anchor、source
  identity 和 immutable source facts，用于 no-op 证明。

这些 source builder、fact/input constructor 与 typed node/layout constructor 只属于
evaluated 集成契约；其中的 field 不是 author property，也不是另一套 DSL。

typed 模块还公开 `ebox-node-kind`、`ebox-text-node-p`、`ebox-box-node-p`、
`ebox-node-source-handle`、`ebox-text-node-value`、`ebox-box-node-layout`、
`ebox-box-node-children` 和 `ebox-box-node-range-anchors`。下面的 facade 清单重点列出
应用入口，因此不重复这些 inspection function。

## 3. 渲染与 retained 发布

| 函数 | 契约 |
| --- | --- |
| `ebox-render` | 接收 single-root `CanonicalEboxInput`，返回带属性字符串，不发布 live buffer。 |
| `ebox-render-to-buffer` | 接收 single-root `CanonicalEboxInput`，挂载 retained TP surface，启用 `ebox-buffer-mode` 并返回 buffer；可选 plist 只接受 `:observer FUNCTION`。 |
| `ebox-unmount-buffer` | 从 live buffer 释放 mounted Ebox/TP surface、observer、retained indexes 与 runtime authority。 |
| `ebox-display-buffer` | `(BUFFER-OR-NAME INPUT &optional ACTION)` 先渲染 single-root `CanonicalEboxInput`，再以 `ACTION` 调用原生 `display-buffer`，返回 buffer。Ebox 不删除其他窗口，也不选中结果窗口。 |
| `ebox-commit` | 原子发布 single-root `CanonicalEboxInput` 或 `ebox-candidate-begin` 返回的 one-shot logical candidate。 |
| `ebox-buffer-set-observer` | 给已经 mounted 的 buffer 设置或移除一个 function observer。 |
| `ebox-buffer-update-report` | 返回最近一次成功更新报告的防御性副本。 |
| `ebox-rerender-buffer-with-context` | 应用显式 viewport width 与可选 height，同时保留 identity。 |
| `ebox-viewport-window-width` | 返回 Ebox 对 window 使用的 display-safe 像素宽度。 |

`ebox-display-buffer` 遵循 `display-buffer-alist` 与原生 action 优先级。渲染失败时
不会调用显示函数。窗口放置由选用的 Emacs display action 决定；调用方提供的 display
action 报错时，Ebox 不会撤销已经成功发布的 buffer。

每个已挂载 buffer 只有一套视口布局，所有显示它的窗口共享该布局。不同窗口需要独立
宽度时，使用不同的挂载 buffer。显式视口更新修改的是该 buffer 共享的布局。

`ebox-commit` 接受可选 framework publish/rollback callback。它们加入现有原子发布；
失败会恢复旧 buffer、surface、runtime state 与最近一次成功报告。

每个公共 Ebox publication 都拥有自己的 TP transaction。在已经 active 的外层 TP
transaction 中调用 mount、commit、viewport、region、selector、batch 或 TP-backed
scroll publication，会在 Ebox mutation 前被拒绝。

观察是可选只读边界，不拥有 transaction 权限。observer 签名是
`(OBSERVER BUFFER REPORT)`。一次 TP publication 被接受且 Ebox finalization 全部完成后，
observer 按顺序收到两份防御性 flat report：先 TP，后 Ebox。两者共享从 TP transaction
id 得到的 `:correlation-id`。Ebox stage 是 `mount`、`commit`、`viewport`、
`region`、`selector`、`batch` 和 `scroll`。嵌套公共调用复用最外层 operation，
因此多匹配 selector 或显式 batch 仍只发送一对 report。没有 TP surface publication
的 no-op 与 native-window scroll 不发送 report。observer error 在 accept 后被包含，
不能回滚渲染。

需要观察首次 mount 时，把 `:observer` 传给 `ebox-render-to-buffer`。mount report 只
瞬时发送；有无 observer 时 `ebox-buffer-update-report` 都仍为 nil。后续通过
`ebox-buffer-set-observer` 替换 observer，传 nil 时移除并从 TP surface 解绑 bridge。
observer 为 nil 时，Ebox 不创建 observation context，不取 timestamp/GC snapshot，
也不装饰 report。

`ebox-call-with-render-burst` 是框架 callback 的 exception-safe allocation/GC 边界。
`ebox-render-burst-begin` 与 `ebox-render-burst-end` 提供较底层的 token 形式，必须用
`unwind-protect` 配对。它们本身不发布内容。

## 4. Identity、直接更新与 logical candidate

| 函数 | 契约 |
| --- | --- |
| `ebox-region-ids` | 按文档顺序返回当前底层 region id。 |
| `ebox-region-resolve` | 把 mounted buffer 中一个逻辑 `:id` 解析为不透明、surface-scoped 的 handle。 |
| `ebox-region-update` | 通过一次 retained transaction 应用支持的可变样式、滚动或原生节点能力 property；接受不透明 region handle，或当前已挂载 buffer 中的语义 `:id`。 |
| `ebox-call-with-update-batch` | `(CALLBACK &optional BUFFER)` 在目标 buffer 中运行零参数回调，合并其排队的 region 更新，并返回回调的返回值。 |
| `ebox-child-range` | 仅供框架集成：在组装 typed canonical input 时构造非视觉、可寻址的 child Range descriptor。 |
| `ebox-candidate-begin` | 在 one-shot candidate 中捕获当前准确 mounted generation。 |
| `ebox-candidate-replace` | 用 single-root `CanonicalEboxInput` 替换一个 candidate node address。 |
| `ebox-candidate-replace-range-ref` | 用 forest-valued `CanonicalEboxInput` 替换一个透明 child Range payload。 |
| `ebox-candidate-replace-root` | 用 single-root `CanonicalEboxInput` 替换 candidate 的私有 root address。 |
| `ebox-candidate-replace-host-ref` | 用 single-root `CanonicalEboxInput` 替换一个 framework-owned opaque host reference。 |
| `ebox-candidate-patch-host-paint` | 比较 previous/next single-root canonical input；记录经过证明的 paint-only host patch，需要 replacement 时返回 nil。 |
| `ebox-host-ref-bounds` | 返回 opaque host reference 当前不含 margin 的 bounds。 |
| `ebox-host-ref-position` | 返回其当前第一个位置。 |

handle 和位置只属于一个 live publication generation；对象被删除后要重新解析。
candidate 被 commit 封存后不能复用。

回调在目标已挂载 buffer 中运行时，可以直接用语义 ID 更新，例如
`(ebox-region-update "action" :help-echo "Updated help")`。
语义 ID 接受字符串、非 `nil` 符号和整数；author 声明的整数 `:id` 与 Ebox 用于
诊断的数字 region metadata 不同。
更新另一个已挂载 buffer 时，使用显式 buffer 调用 `ebox-region-resolve`，再把返回
的 handle 传给 `ebox-region-update`。

`ebox-region-update` 接受 Text 和 Box region 上的 `:help-echo`、`:pointer`、
`:hover-style` 和 `:keymap`，验证规则与构造时一致。新值替换对应能力，`nil` 清除
对应能力并阻止外层值覆盖，省略的属性保持不变。Ebox 对 keymap 创建快照；调用方
之后直接修改原 map 不会更新已挂载的 surface，应显式替换 `:keymap` 来发布新绑定。
清除该属性只移除节点 keymap，普通 Emacs buffer 和全局绑定仍然适用。

### 合并 region 更新

`ebox-call-with-update-batch` 的 `BUFFER` 默认是当前 buffer，`CALLBACK` 在该
buffer 中执行。如果 helper 自己创建 batch，回调正常返回且存在待处理变化时只
flush 一次。空回调或未产生变化的回调不会发布，也不会替换最近一次成功更新报告。
flush 成功后，helper 原样返回回调的返回值。

目标 buffer 已有活动 batch 时，helper 加入该 batch 而不 flush，由外层拥有者决定
何时发布。回调发生 error、quit 或其他非局部退出时，helper 丢弃本次调用排队的
变化，并将外层 batch 的待处理状态恢复到进入回调前的检查点。helper 自己拥有的
batch 若 flush 失败，其未发布变化会被丢弃；已有 TP transaction 恢复此前已提交
的 buffer、runtime、revision 和报告。

回滚范围仅限于 `BUFFER` 中排队的 `ebox-region-update` 工作。回调对应用变量的
赋值、文件写入及其他业务副作用不会被撤销。显式
`ebox-incremental-begin-batch` / `ebox-incremental-flush` 生命周期调用应放在回调
外部；这些底层调用保留各自的重试语义。

author DSL 没有 Range form。普通 author 只组合直接嵌套的 Text/Box child，不调用
`ebox-child-range`；Range address 只服务已经拥有 semantic child range 与 candidate
update 的框架。

## 5. Selector

ECSS 是唯一 selector parser 与 matcher；Ebox 只提供 logical tree relation 和
mounted index。

| 函数 | 契约 |
| --- | --- |
| `ebox-selector-parse` | 把 CSS-like selector 编译为 ECSS AST。 |
| `ebox-selector-match-node-p` | 用 selector 或 AST 匹配一个 built node。 |
| `ebox-selector-query-all` | 按文档顺序查询 unmounted built tree。 |
| `ebox-selector-query-buffer` | 查询一个 mounted runtime。 |
| `ebox-selector-update-buffer` | 更新所有可编辑 mounted match 并返回结构化报告。 |
| `ebox-select-all` | `ebox-selector-query-buffer` 的 alias。 |
| `ebox-update-selector` | `ebox-selector-update-buffer` 的 alias。 |

## 6. 滚动

`ebox-buffer-mode` 安装 `ebox-scroll-map`。map 会把行、页和滚轮意图先交给最内层
semantic scroll owner，再回退到普通 Emacs 滚动。

公共命令是 `ebox-scroll-down`、`ebox-scroll-up`、`ebox-scroll-page-down`、
`ebox-scroll-page-up`、`ebox-wheel-scroll-down` 与 `ebox-wheel-scroll-up`。
`ebox-scroll-state` 根据数字 region id 返回只读快照。

## 7. 测量、缓存与构建工具

| 函数 | 契约 |
| --- | --- |
| `ebox-string-pixel-width` | 测量字符串第一行的 display width。 |
| `ebox-display-signature` | 返回 measurement cache invalidation 使用的 display 输入。 |
| `ebox-clear-cache` | 清理 Ebox measurement/render cache。 |
| `ebox-byte-compile` | 编译 Ebox 活跃 Elisp 源码；重启 Emacs 后加载新 bytecode。 |
| `ebox-native-status` | 报告 native toolchain、module、ABI 与加载状态。 |
| `ebox-native-build` | 异步构建并安装可选 native 模块。 |

native 模块只是加速器，不是正确性依赖。加载包不会构建它。

## 8. Facade 清单

`ebox-public-api` 保存稳定 facade 入口。下面的分组列出其中每一个名称：

- 构造：`ebox-build`、`ebox-text-create`、`ebox-normal-layout-create`、
  `ebox-row-layout-create`、`ebox-column-layout-create`、
  `ebox-flex-layout-create`、`ebox-grid-layout-create`、`ebox-box-create`；
- 交互：`ebox-help-create`、`ebox-keymap-create`、
  `ebox-next-interaction`、`ebox-previous-interaction`；
- 渲染/发布：`ebox-render`、`ebox-render-to-buffer`、`ebox-unmount-buffer`、
  `ebox-display-buffer`、`ebox-commit`、`ebox-buffer-set-observer`、`ebox-buffer-update-report`、
  `ebox-rerender-buffer-with-context`、`ebox-viewport-window-width`、
  `ebox-call-with-render-burst`、`ebox-render-burst-begin`、
  `ebox-render-burst-end`；
- Candidate/identity：`ebox-candidate-begin`、`ebox-candidate-replace`、
  `ebox-candidate-replace-range-ref`、`ebox-candidate-replace-root`、
  `ebox-candidate-replace-host-ref`、`ebox-candidate-patch-host-paint`、
  `ebox-child-range`、
  `ebox-region-ids`、`ebox-region-resolve`、`ebox-region-update`、
  `ebox-call-with-update-batch`、
  `ebox-host-ref-bounds`、`ebox-host-ref-position`；
- Selector：`ebox-selector-parse`、`ebox-selector-match-node-p`、
  `ebox-selector-query-all`、`ebox-selector-query-buffer`、
  `ebox-selector-update-buffer`、`ebox-select-all`、`ebox-update-selector`；
- 滚动：`ebox-buffer-mode`、`ebox-scroll-map`、`ebox-scroll-down`、
  `ebox-scroll-up`、`ebox-scroll-page-down`、`ebox-scroll-page-up`、
  `ebox-wheel-scroll-down`、`ebox-wheel-scroll-up`、`ebox-scroll-state`；
- 测量/构建：`ebox-string-pixel-width`、`ebox-display-signature`、
  `ebox-clear-cache`、`ebox-byte-compile`、`ebox-native-status`、
  `ebox-native-build`。

## 9. 验证

```sh
make load EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make compile EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make docs-contract-tests EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make interaction-tests EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make dsl-tests EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
make check EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
```

## 框架集成契约

Ebox 通过 `(require 'ebox-spi)` 提供 framework SPI v2，面向 ETAF 等框架实现者；
普通应用使用前面的渲染和更新入口。先调用 `ebox-framework-spi-capabilities` 获取
不可变 provider，并用 `ebox-framework-spi-validate-provider` 验证，再保存公共
operation descriptor。不得读取私有 provider 字段。

| 操作 | 输入与结果 |
| --- | --- |
| `ebox-framework-spi-initial` | 未挂载 buffer、canonical input 和 stage/rollback 回调对；返回传给回调的同一份已完成报告。不允许加入外层 TP 事务。 |
| `ebox-framework-spi-update` | 已挂载 buffer、canonical input 或 candidate，以及回调对；返回 stage 回调看到的同一个报告对象。 |
| `ebox-unmount-buffer` | 释放挂载，使该 buffer 可以建立新的 initial generation。 |

框架管理应用状态，Ebox 管理布局与 runtime indexes，TP 管理 buffer 发布和事务。
stage 在临时 TP 与 Ebox 状态一致后执行。回滚依次恢复框架、Ebox、TP 状态。
initial 失败时恢复编辑器状态，包括文本、point、mark、narrowing、overlay、undo 与
modified 标志；已被销毁的 buffer 不会被复活。提交接受后的观察者或 retirement 错误
是诊断信息，不能把已经完成的提交当作回滚。调用方必须同时提供两个回调并传播失败，
不得失败后切换另一个写入器。精确参数以对应函数 docstring 为准。

```elisp
(require 'ebox)
(require 'ebox-spi)
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

`tests/ebox-spi-tests.el` 验证成对发布、回滚及公共 teardown。消费方链接到本契约，
不再复制一份回调时序说明。
