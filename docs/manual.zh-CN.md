# Ebox 手册

[English](manual.md)

本手册说明 retained engine 的受支持工作流。完整 API 清单、签名和生命周期说明在
[`../ebox.el`](../ebox.el) 的 Commentary 中；未列出的 symbol 均为内部实现。

## 1. 加载 Ebox

```elisp
(require 'ebox)
```

加载包只安装定义，不创建 buffer、不启用 mode，也不运行图片转换。

## 2. 构建 retained 树

一棵树由 retained 可变节点组成。离线节点可以渲染或挂载；已挂载节点保留 identity，
并在原地更新。

### Author form

`ebox-build` 接受一套紧凑 author grammar：

| Form | 结果 |
| --- | --- |
| `"text"` | 文本节点。 |
| `(text PROPS... "text")` | 带属性的文本节点。 |
| `(box PROPS... CHILD...)` | 普通 box。 |
| `(row PROPS... CHILD...)` | 水平一维容器。 |
| `(column PROPS... CHILD...)` | 垂直一维容器。 |
| `(flex PROPS... CHILD...)` | flex 容器。 |
| `(grid PROPS... CHILD...)` | grid 容器。 |

子节点直接嵌套。属性是普通 keyword/value 对。

```elisp
(defvar ebox-guide-root
  (ebox-build
   '(column :id "root" :padding ((lh 1) (ch 2)) :item-gap (lh 1)
            (text :class "title" "Inbox")
            (row :item-gap (ch 1)
                 (box :id "open" :tab-index 0 "Open")
                 (box :id "done" "Done")))))
```

### 程序化构造

当 Lisp 代码已经知道节点形状，或需要保留节点引用时，使用 `ebox-node-create` 与
`ebox-text-create`。

```elisp
(let* ((label (ebox-text-create "Count: 0" '(:class "counter")))
       (root (ebox-node-create 'column '(:width (ch 20))
                               (list label))))
  (list root label))
```

一个节点只能有一个 parent。需要复用当前输入时，用 `ebox-node-copy` 复制子树。

## 3. 挂载、渲染和卸载

`ebox-render` 返回带属性字符串，不创建 live buffer。`ebox-mount` 将根节点或 author form
挂载到 buffer 并返回根节点。之后该 buffer 文本由 Ebox 拥有，直到
`ebox-unmount-buffer` 释放挂载。

```elisp
(let ((root (ebox-mount "*Ebox Guide*"
                        '(column :width (ch 24)
                                 (box "First")
                                 (box "Second"))
                        :width 240 :height 8)))
  (ebox-buffer-root "*Ebox Guide*")       ; => root
  (ebox-mount-viewport "*Ebox Guide*"))   ; => (240 . 8)
```

mount 选项 `:width` 和 `:height` 固定 viewport。省略任一选项时，Ebox 会在存在显示窗口时
测量它；离线渲染可使用 `ebox-viewport-width` 与 `ebox-viewport-height`。

## 4. 更新节点与批量 flush

mutation 会标记 dirty bits 并把所属 mount 入队。batch 外部立即 flush；在
`ebox-with-batch` 中，所有入队 mount 会在最外层 batch 结束时只 flush 一次。

```elisp
(let* ((root (ebox-mount "*Ebox Update*"
                         '(column :width (ch 20)
                                  (box :id "count" "Count: 0")
                                  (box :id "status" "cold"))
                         :width 240 :height 8))
       (count (car (ebox-selector-query root "#count")))
       (status (car (ebox-selector-query root "#status"))))
  (ebox-with-batch
    (ebox-node-set-text (car (ebox-node-children count)) "Count: 1")
    (ebox-node-set-props status '(:background-color "#EEF2FF"))))
```

常用 mutation 入口包括：

- `ebox-node-set-text`：设置文本节点内容。
- `ebox-node-set-props` 或 `ebox-node-put`：设置 author 属性。
- `ebox-node-set-states` 与 `ebox-node-restyle`：更新 selector state。
- `ebox-node-insert`、`ebox-node-remove`、`ebox-node-move`、`ebox-node-replace-children`：更新结构。
- `ebox-node-set-image`：设置已准备的图片内容。

flush 后，用 `ebox-node-geometry` 查询几何，用 `ebox-node-position` 或
`ebox-node-bounds` 查询 buffer 位置，用 `ebox-node-at` 做命中测试。

## 5. 样式、ECSS scope 与 selector

节点构建或更新时会验证内联属性。几何使用显式长度数据，如 `(px 120)`、`(ch 20)`、
`(lh 2)`、`(% 50)`、`(vw 50)` 和 `(vh 25)`。`calc`、`min`、`max`、`clamp` 以数据形式
组合长度。横向属性接受横向单位，纵向属性接受行/viewport-height 单位，border width 接受
stroke 单位。裸数字不是 public length。

Text 与 box 支持字体、颜色和文本装饰属性。Box 还支持尺寸、padding、margin、border、
overflow、visibility、positioning、row/column gap、flex 容器与 item 属性、grid track 与
placement。schema 是严格的；无效属性或值会在修改现有 mount 前报错。左右 border 按解析后的像素
宽度绘制；上下 border 绘制为该行的 overline 或 underline，宽于 1px 的上下 border 会触发
`ebox-error`。

图形 frame 上，box 背景可以通过 `:border-radius`（例如 `(px 12)`）绘制圆角。块方向
padding 可以是小数：`:padding-block (lh 0.5)` 占一整行，但背景只绘制其中一半，使胶囊和气泡
上下留白均匀。每行保持一个行高，文字不会被替换；终端里背景按方角、整行绘制。

软换行不会让 `。`、`，`、`）`、`!` 等闭合标点出现在行首，也不会让 `（`、`“` 等开启标点停在
行尾；前一个字符或单词会一起移到下一行。

内联 ECSS rule 可通过 `:ecss` 附加。复用 scope 由 `ebox-style-scope-create` 创建，
通过 `:ecss-scope-roots` 附加到 root，member 通过 `:ecss-scopes` 加入。

```elisp
(let* ((scope (ebox-style-scope-create
               '((".warn" :color "#B45309" :font-weight bold))
               :origin 'author))
       (root (ebox-mount "*Ebox Styles*"
                         `(column :ecss-scope-roots (,scope)
                                  (text :class "warn" "Warning")
                                  (text "Normal"))
                         :width 240 :height 6)))
  (length (ebox-selector-query root ".warn"))) ; => 1
```

Selector 通过 ECSS subject facts 查看 retained node：type、`:id`、`:class`、`:attributes`、
`:states`、parent 和 children。与 CSS 一致，`[id="..."]` 和 `[key="..."]` 匹配节点的
`:id` 与 `:key`，包括不是合法 `#` 标识符的 id。交互还会派生 `focus`、`active`、`disabled` selector state。

使用 `ebox-selector-query`、`ebox-selector-query-buffer` 和
`ebox-selector-match-node-p` 完成 public selector 工作。

## 6. 布局与定位

根据意图选择最小容器：

- `box` 堆叠 block 子节点，并把 inline text 排为段落。
- `row` 与 `column` 沿单轴放置直接子节点，支持 `:item-gap` 与 `:cross-align`。
- `flex` 支持方向、换行、分布、item grow/shrink 和对齐。
- `grid` 支持显式/自动 track、fraction、`minmax`、`repeat`、gap 与一基 placement。

绝对定位属于 box layout。absolute 子节点脱离父节点的流，用 `:left` 和 `:top` 从父节点内容原点放置（inline 父节点交给最近的外层 box）；父节点把合成的浮层裁剪到自己的画布内，需要预留空间时给它显式高度。
`:z-index` 排序重叠绘制：`:position relative` 的流内子节点保留其流内位置，
`:z-index` 高于同一父节点中的 absolute 子节点时绘制在它们之上，空白处透出下层背景。`:layer root` 把 box 绘制在根的顶层，同时保持 selector 与继承
使用的逻辑 parent；未锚定时其偏移与百分比从根的 border box 起算，因此 `:width (% 100) :height (% 100)` 的遮罩覆盖整个页面。anchored absolute box 用 `:anchor` 与 `:placement` 相对 host 中唯一语义目标定位。
目标缺失时该 box 不绘制、没有位置，也不能获得焦点。

`overflow hidden` 在完整显示单元边界上做横向与纵向裁剪。`overflow scroll` 通过下方 scrolling API 提供纵向滚动。

## 7. 交互

交互能力是保存在节点上的 author 属性。绘制时，Ebox 将它们复制为覆盖节点 content、
padding 和 border 的 Emacs text property；子节点的显式值覆盖祖先。

### Keymap、activation 与 focus

使用 `ebox-keymap-create` 创建原生 keymap。

```elisp
(defvar ebox-guide-activated nil)

(let* ((root (ebox-mount
              "*Ebox Interaction*"
              `(column :width (ch 20)
                       (box :id "button" :tab-index 0
                            :keymap ,(ebox-keymap-create
                                       :activate (lambda ()
                                                   (setq ebox-guide-activated t)))
                            "Activate"))
              :width 240 :height 6))
       (button (car (ebox-selector-query root "#button"))))
  (ebox-focus button "*Ebox Interaction*")
  (with-current-buffer "*Ebox Interaction*"
    (ebox-activate (ebox-node-position button) t)))
```

`ebox-mount` 会启用 `ebox-buffer-mode`，卸载时关闭；它安装 scrolling 键、TAB/backtab focus 循环、
方向键（以及 C-n/C-p/C-b/C-f）focus 移动、Home/End 组边界和 RET/return activation。
不启用 mode 时，应用可直接调用 `ebox-focus`、`ebox-focus-next`、`ebox-focus-previous`、
`ebox-focus-within`、`ebox-activate`、`ebox-next-interaction` 和 `ebox-previous-interaction`。

### 键盘导航

每个指针交互都需要键盘路径；导航由引擎提供，应用只声明结构，不写按键处理。

- 容器上的 `:focus-group`（`vertical`、`horizontal` 或 `grid`）把其中的 `:tab-index`
  后代合并为一个 Tab stop。Tab 进入时落在上次聚焦的成员，否则是 `aria-selected`、
  `aria-current` 或 `aria-checked` 为真的成员，否则是第一个。方向键沿组的方向在组内移动；
  `grid` 移动到几何上最近的成员。到达组边界或沿另一轴移动时，focus 移到组外最近的 stop。
- 未分组的 stop 按空间位置到达：`ebox-focus-direction` 选择该方向上完全位于当前 stop
  之外的最近 stop。上下方向没有 stop 时滚动内容。
- `:focus-scope modal` 把 Tab、方向键和 `ebox-focus-first` 限制在最内层可见的 modal 节点，
  例如对话框或菜单。`ebox-focus-scope` 返回该节点（或根节点），`ebox-focus-stops`
  列出其中所有 stop（包括焦点组成员），供按键分发或命令面板停留在打开的对话框内。
- 聚焦节点会滚动其 Ebox scroller 使其可见，并显示它的 `:hover-content`。被聚焦的节点
  被移除后，下一次移动从它最后的位置继续。
- 每当 `ebox-focus` 或导航移动焦点，`ebox-focus-change-functions` 以先前和新的聚焦节点
  在该 buffer 中运行，宿主可以在焦点进入某个区域时做出反应，例如提升窗口。

```elisp
(ebox-mount "*Ebox Keys*"
            `(column
              (box :id "search" :tab-index 0 "Search")
              (column :focus-group vertical
                      ,@(mapcar (lambda (title)
                                  `(box :tab-index 0
                                        :attributes (("aria-selected"
                                                      . ,(if (equal title "B") "true" "false")))
                                        ,title))
                                '("A" "B" "C"))))
            :width 240 :height 6)
```

从 Search 按 Tab 落在 B；Down 移到 C，Up 回到 B。

### Help、pointer、hover 和 drag

- `:help-echo` 接受字符串或由 `ebox-help-create` 生成的函数。
- `:pointer` 设置 Emacs pointer shape。
- `:hover-style` 映射为 `mouse-face`，用于颜色和文本装饰变化。
- hover 反馈覆盖元素的整个绘制区域：跨多行的元素把各行连成一段原生
  `mouse-face` run，而不是只高亮指针所在的那一行。
- hidden 元素不绘制任何东西，因此也不绘制交互反馈：`:visibility hidden` 的
  槽位保留布局空间，但不提供 hover、pointer、help 或激活。
- hover 绘制是无条件的，自带背景的元素同样会被覆盖。是否让选中/当前项不
  叠加 hover 属于应用策略：在该状态下把元素的 `:hover-style` 声明为 nil。
  引擎无法推断选中状态，而有底色元素叠加 hover 变色是受支持的效果。
- 后代继承祖先的 `:help-echo`、`:pointer`、`:hover-style` 和 `:keymap`；后代显式设为
  nil 会阻断继承值。
- `:hover-content` 在鼠标悬停某个 group 时临时替换文本节点或 box 的第一个子文本；
  `:hover-group` 将相关成员作为一个 batch 更新。
- `:swipe` 接收单参数函数：节点或其后代上每次水平两指手势调用一次，参数为手指方向 `left`
  或 `right`。最内层启用的处理者优先，惯性事件被吸收。`ebox-swipe-distance` 与
  `ebox-swipe-quiet` 调节识别。
- `:scroll` 接收单参数函数：`ebox-node-set-scroll`、滚轮、滚动键或 scroll-into-view
  改变滚动器偏移后调用，参数为新的行偏移。固定在末尾的 `:scroll-anchor end`
  滚动器随内容增长保持在末尾时不调用。
- `ebox-keymap-create` 可绑定 `:drag` 回调和受支持的 `:drag-lock-modifier`。
  drag 回调收到包含 phase、node、window、buffer、start、position、delta 和取消原因的 plist。

### Input session

Input session 是允许用户直接编辑已挂载文本的唯一受支持方式。session 用普通 Emacs 命令编辑一个已布局 text node 的值，
同时节点保持自身布局：输入的文本在节点盒子内换行，padding 与边框保持不变，point 跟随 caret。undo、kill 与 yank、region、
按词移动和输入法的行为与普通 buffer 相同；上下键按绘制行移动；在节点盒子内点击会移动 caret，拖动会选择，双击选择单词，三击选择整个值。输入法 preedit 文本在盒子内换行。

`ebox-input-begin` 接受 `:on-change`（每次新值时调用）、`:on-leave`（点击落在盒子外时调用）、`:keymap`（优先查找的绑定，
在挂载 buffer 中执行）以及 `:local-variables`（为编辑命令设置 `completion-at-point-functions` 等变量）。`:keymap` 中属于
`ebox-input-edit-commands` 的绑定（如 `newline`）会编辑值本身，多行输入框据此绑定 S-RET。把节点文本设为 session 当前值不产生
任何效果，因此上层可以把 `:on-change` 回写到自己的模型；设为其他字符串则替换该值。

```elisp
(let* ((root (ebox-mount "*Ebox Input*"
                         '(box :padding-inline (ch 1) (text :id "field" "draft"))
                         :width 160 :height 3))
       (field (car (ebox-selector-query root "#field")))
       (map (define-keymap "C-j" #'newline))
       (session (ebox-input-begin "*Ebox Input*" field
                                  :keymap map
                                  :on-change (lambda (value) (message "%s" value)))))
  (prog1 (ebox-input-text session)
    (ebox-input-end session)))
```

对可见且可用的节点执行短同步 reader 时使用 `ebox-call-with-input`。`ebox-input-cancelled`
表示控制返回前节点或 mount 已不可用。

## 8. Scrolling

带 `:overflow scroll` 或 `auto` 且内容高于 viewport 的节点可滚动。scroll offset 存在 retained node 上。

```elisp
(let* ((root (ebox-mount "*Ebox Scroll*"
                         '(box :id "pane" :height (lh 2) :overflow scroll
                               "one\ntwo\nthree\nfour")
                         :width 200 :height 4))
       (pane (car (ebox-selector-query root "#pane"))))
  (ebox-node-set-scroll pane 1)
  (ebox-node-scroll-offset pane)) ; => 1
```

`:scroll-anchor end` 适合日志和会话。节点初始显示最后一行，并在内容增减时保持钉在末尾；
滚动到更早的位置会解除固定，此后新内容不再移动可见行；滚回最后一行会重新固定。默认值
`start` 保留已存的 offset，并按内容范围夹取。

`ebox-node-scroll-into-view` 从内到外滚动每个外层 scroller，以最小距离让节点可见，
例如选中的列表行。

交互命令先滚动 point 下最内层可滚动节点；当 Ebox 节点不能消费剩余滚动时，回退到普通
window scrolling：`ebox-scroll-down`、`ebox-scroll-up`、`ebox-scroll-page-down`、
`ebox-scroll-page-up`、`ebox-wheel-scroll-down`、`ebox-wheel-scroll-up`。
`ebox-scroll-step` 控制 wheel 与行滚动步长。

## 9. 图片

图片在渲染前被准备为不可变字符网格。准备阶段拥有文件读取、Emacs image descriptor、
可选 converter 进程和 fallback placeholder。渲染与 buffer 写入只复制已准备内容。

```elisp
(let* ((prepared (ebox-image-prepare "cover.png" 24 12
                                     :adapter 'placeholder))
       (image (ebox-node-create 'image (list :image prepared)))
       (root (ebox-node-create 'column nil
                               (list image (ebox-text-create "caption")))))
  (ebox-render root))
```

使用 `ebox-image-info` 查看所选 adapter 与尺寸，`ebox-image-content` 取得 owned string，
converter 或字体能力变化后调用 `ebox-image-cache-clear`。要原地替换 image node，先准备新值，
再调用 `ebox-node-set-image`。

`:inset (TOP . BOTTOM)` 在图形图片上下分别留出 TOP、BOTTOM 像素（各小于一个行高）的空白，
不改变图片占用的行数，使图片与上下文字之间留有间隙。图形图片的透明像素显示其所在 box 的背景。

macOS 图形 frame 上，会撑高行高的彩色 emoji 以一个行高的图片显示。首次使用时用 `swiftc`
（Xcode 命令行工具）编译一个小型渲染程序，并把图片缓存在 `user-emacs-directory` 下的
`ebox-emoji/`；没有 `swiftc` 时 emoji 会缩小以适应行高。

## 10. Viewport 与 refit

一个已挂载 buffer 只有一个 viewport。没有固定 `:width`/`:height` 选项时，Ebox 会测量被选中
或已显示的 window。需要同一棵树在不同宽度下同时显示时，请使用不同 buffer。

- `ebox-mount-viewport` 返回当前 `(WIDTH . HEIGHT)`。
- `ebox-mount-set-viewport` 固定或清除尺寸，然后 refit。
- `ebox-refit` 重新测量显示窗口，只 relayout 读取已变化 viewport 单位的节点，或 root 尺寸跟随 viewport 的节点。
- `ebox-viewport-window-width` 返回 window 的可用像素宽度。
- `ebox-viewport-settle-delay` 控制 window-size event 后的 trailing refit。

## 11. Observer 与 update report

设置 observer 可接收每次成功 flush 的 report。之后也可用 `ebox-buffer-update-report` 取得同一 report。

```elisp
(let ((root (ebox-mount "*Ebox Report*" '(box :id "n" "old")
                       :width 160 :height 3)))
  (ebox-buffer-set-observer
   "*Ebox Report*"
   (lambda (_buffer report) (message "Ebox wrote %S" report)))
  (ebox-node-set-text (car (ebox-node-children
                            (car (ebox-selector-query root "#n"))))
                      "new")
  (ebox-buffer-update-report "*Ebox Report*"))
```

Report 包含 `:provider`（固定为 `ebox`，供共享的测量 sink 区分来源）、`:strategy`
（`full` 或 `lines`）、`:edits`、`:lines`、`:ranges`、`:flush`，observer 调用中还包含
`:duration-ms`。

## 12. 失败与恢复

Ebox 在 public 边界验证输入，并在 `ebox.el` 记录的 Ebox 专用 error symbol 下抛出普通 Emacs error。

- 无效样式属性、尺寸单位、selector fact 或图片参数会在修改现有 mount 前报错。
- 有 parent 的节点不能插入其他位置；请先 detach 或 copy。
- text 节点不能包含 children。
- `ebox-focus`、activation、scrolling 和 input-session 入口在目标不可用时抛出
  `user-error` 或 `ebox-input-error`。
- buffer 卸载时 input session 随之结束，此后 `ebox-input-text` 返回 nil。
- `ebox-unmount-buffer` 释放 marker、hook 与 mount 状态，但保留当前 buffer 文本。
- 字体或具名 face metric 变化后调用 `ebox-clear-cache`；converter 或图片能力变化后调用
  `ebox-image-cache-clear`。

如果 buffer 被 Ebox 之外的代码编辑，下一次写入会丢弃记忆的 line parts，并从 retained tree
重新安全写入。请把节点树，而不是 buffer 文本，当作事实来源。
