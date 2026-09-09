# Ebox 公共 API 参考

[English](ebox-api-reference.en.md)

本文描述独立 Ebox 包当前的公共边界，并把普通 author 路径与框架集成使用的
evaluated typed API 分开。以 `ebox--` 开头的名称都是私有实现。

Ebox 需要 Emacs 29.1 或更高版本、ECSS 0.1.0 或更高版本，以及 TP 2.0.0 或更高版本。
EKP 1.0.0 或更高版本是 `:wrap-mode kp` 所需的可选依赖；`word`、`char`、`none`
不加载它。EKP 缺失或不兼容时会给出可操作的错误，不会静默改变换行算法。
源码加载方式和各项依赖职责见[安装说明](../../README.zh-CN.md#安装)。

```elisp
(require 'ebox)
```

## 1. Author 语法

`ebox-build` 只接受以下 author 入口：

```text
STRING
(text PROPERTY VALUE ... STRING)
(box PROPERTY VALUE ... CHILD ...)
(row PROPERTY VALUE ... CHILD ...)
(column PROPERTY VALUE ... CHILD ...)
(flex PROPERTY VALUE ... CHILD ...)
(grid PROPERTY VALUE ... CHILD ...)
```

`STRING` 是 `(text STRING)` 的简写。Text form 必须且只能有一个字符串 payload。
每种 Box form 都接受零个或多个直接嵌套的 Text/Box 子节点。form 名称选择 Normal、
Row、Column、Flex 或 Grid 子布局；author 不通过 property 传入布局选择器。

`ebox-build` 返回一个不透明的 `CanonicalEboxInput`，以原子整体携带有序 canonical
forest 和拥有其 author facts 的 source generation。普通 author 代码只把这个值原样
传给 Ebox 渲染/发布函数，不取出 node，也不构造 source index。

```elisp
(ebox-build
 '(column :padding ((lh 1) (ch 2))
          (box :id "status" :color "#166534" "Ready")
          (row :item-gap (ch 1)
               (box "Left")
               (box "Right"))))
```

author source field 是 `:key`、`:class` 与 `:id`。`:outer` 可取 `inline` 或
`block`，控制 Box 如何参与父布局。

### 布局拥有的 property

| Form 或关系 | Property |
| --- | --- |
| `row`、`column` | `:item-gap`、`:cross-align` |
| `flex` | `:flex-direction`、`:flex-wrap`、`:flex-flow`、`:justify-content`、`:align-items`、`:align-content`、`:gap`、`:row-gap`、`:column-gap` |
| `flex` 的直接子 Box | `:order`、`:flex`、`:flex-grow`、`:flex-shrink`、`:flex-basis`、`:align-self` |
| `grid` | `:grid-template-columns`、`:grid-template-rows`、`:grid-auto-columns`、`:grid-auto-rows`、`:grid-auto-flow`、`:justify-items`、`:justify-content`、`:align-items`、`:align-content`、`:gap`、`:row-gap`、`:column-gap` |
| `grid` 的直接子 Box | `:order`、`:grid-column`、`:grid-row`、`:grid-column-span`、`:grid-row-span`、`:align-self` |

participation property 就是普通子 Box property，不会创建另一种公共节点或 wrapper。

### 当前常用 property

| 范围 | 当前输入 |
| --- | --- |
| 尺寸 | `:box-sizing`、`:width`、`:min-width`、`:max-width`、`:height`、`:min-height`、`:max-height` |
| 边缘 | `:padding`、`:margin`、`:border`、各 side shorthand 与 longhand |
| 绘制 | `:color`、`:background-color`、精确 alias `:bgcolor`、border color、`:visibility` |
| 文本布局 | `:text-align`、`:wrap-mode`（`word`、`char`、`kp`、`none`） |
| Overflow | `:overflow`（`visible`、`hidden`、`scroll`） |

`hidden` 在组合子节点后约束内容宽度，保留完整的受支持文本簇；容器自身的 padding 与
border 不在裁剪区域内。被裁掉的子文本同时移除其属性。固定 display space 可以缩短，
放不下的字形/图像则整体省去，不做像素遮罩。纵向按完整行裁剪。`visible` 允许溢出，
`scroll` 提供纵向滚动；这些设置不隐含省略号或横向滚动。

几何值统一使用 `(单位 数值)`：`(px 240)`、`(% 50)`、`(vw 100)`、`(vh 100)`、
`(ch 80)`、`(lh 3)`。每个属性只接受[统一单位约束表](ebox-user-guide.zh.md#size-unit-constraints)
规定的单位，不能跨几何轴使用。不接受 CSS 字符串、裸长度、单元素像素列表及旧的
viewport/contain 关键词；零长度也需要允许的单位。边框宽度采用独立绘制厚度规则，
不接受百分比，
例如 `:border ((px 1) solid "#687386")`。Flex 因子、Grid 索引等无量纲值仍是数字。

| 属性 | 接受的关键词 | 默认值 |
| --- | --- | --- |
| `width`、`height`、`min-width`、`min-height` | `auto`、`min-content`、`max-content`、`fit-content`、`stretch` | `auto` |
| `max-width`、`max-height` | `none`、`min-content`、`max-content`、`fit-content`、`stretch` | `none` |

尺寸函数支持 `calc`、`min`、`max`、`clamp`，可以组合使用，例如
`(calc (- (vh 100) (lh 1)))` 与 `(clamp (ch 20) (% 50) (ch 80))`。
`fit-content` 只接受裸关键词，不带参数。property 验证属于 Ebox；构造树时就按
属性或父布局方向，递归检查所有函数分支、展开后的简写、Grid 轨道与 Flex basis。
context/value 组合无效时会直接报错。百分比参照、字体单位、算术规则及纵向完整行显示量化见
[用户指南的几何章节](ebox-user-guide.zh.md#4-使用几何与绘制-property)。这是 CSS
语义的子集，不是完整浏览器布局引擎。

### 原生节点能力

`text`、`box`、`row`、`column`、`flex` 和 `grid` 都接受下面四个显式节点属性。
这些能力与 CSS declaration 分开，不参与样式表 cascade。

| 属性 | 接受的值 | 原生 surface property |
| --- | --- | --- |
| `:help-echo` | `nil`、字符串，或由 Emacs 以 `(WINDOW OBJECT POSITION)` 调用的函数 | `help-echo` |
| `:pointer` | `nil`、`text`、`arrow`、`vdrag`、`modeline`、`hand`、`hdrag`、`nhdrag` 或 `hourglass` | `pointer` |
| `:hover-style` | `nil`，或仅包含 `:color`、`:background-color`、`:text-decoration-line`、`:text-decoration-color`、`:text-decoration-style` 的 Ebox 绘制 plist | 编译后的 `mouse-face` |
| `:keymap` | `nil`，或使用普通交互命令作为绑定的原生 Emacs keymap | `keymap` |

悬停颜色使用颜色字符串，`:text-decoration-color` 还接受 `currentColor`。
`:text-decoration-line` 接受 `none`、`underline`、`overline`、`line-through`，或不含
`none`、不重复的非空装饰列表；`:text-decoration-style` 接受 `solid`、`double`、
`dotted`、`dashed`、`wavy`。悬停样式不能改变字体度量、几何、间距或布局。Ebox 负责
编译受限绘制 plist；原始 face 或任意原生 property plist 都不是 author 输入。
不提供 `:tps`、`:local-map` 或原始 `:mouse-face` 输入。

同一渲染行中，由同一个 hover owner（声明 `:hover-style` 的节点）覆盖的文字与
padding 共享一个原生 `mouse-face`。未指定的悬停属性采用 owner 的基础样式；
因此，即使子文本的正常颜色不同，被父级悬停覆盖时也会采用 owner 未被覆盖的属性。
子节点显式声明 hover style 会形成独立悬停区域，`nil` 阻止外层悬停。物理左右边框
不参与悬停高亮，水平边框线条保留自己的绘制。

Box 的帮助、指针与 keymap 范围包含渲染后的内容、padding 和 border，不包含该 Box
自身的 margin 及结构性换行符；悬停遵循上述范围。Text 的能力作用于其渲染文本。
嵌套位置上，子节点显式声明的每项
能力优先于外层值；显式 `nil` 阻止外层值覆盖，省略属性则保留外层交互范围的覆盖。

`ebox-help-create` 把零参数业务函数适配为原生的 `(WINDOW OBJECT POSITION)`
帮助回调。业务函数返回字符串或 `nil`，在悬停 buffer 的上下文中运行，不移动 point
或切换选中窗口，直到 Emacs 请求帮助时才调用。例如：

```elisp
(ebox-help-create (lambda () (format "Help for %s" (buffer-name))))
```

仍支持直接传入原生帮助函数。帮助函数保留为函数，由 Emacs 在请求帮助时调用，
不在构造 DSL 时求值。
计算得到的函数或 keymap 通过反引号和逗号插入。帮助显示和指针外观遵循用户的
Emacs 设置及窗口系统；单独设置指针形状不会绑定命令。

推荐使用 `ebox-keymap-create` 将回调转换为 keymap：

```elisp
(ebox-keymap-create
 :activate (lambda () (message "Activated"))
 :bindings (list (cons "?" (lambda () (message "Action help")))))
```

`:activate` 接收零参数函数，将其绑定到 `RET`、`[return]`、`SPC` 和 `[mouse-1]`。
`:bindings` 接收 alist，key 是按键描述字符串或事件向量，value 是零参数函数。
两项都可省略，`nil` 表示不添加相应绑定。重复按键和重叠前缀会报错，包括与激活键
重叠的绑定。辅助函数返回原生 Emacs keymap；回调保留为函数，直到对应命令触发时才调用。
鼠标事件会自动从事件取得窗口，并在其 buffer 中运行回调，不选择窗口或移动 point。
键盘回调在当前 buffer 中运行，由 point 所在位置进行原生分派。

仍支持直接传入原生 keymap；其鼠标命令需要自行从事件取得目标窗口，并在该窗口的
buffer 中操作。

`ebox-next-interaction` 和 `ebox-previous-interaction` 是可选导航命令，均接受可选整数
count，默认为一；负数反向，零不移动。每个声明了含命令 keymap 的节点在其首个可访问
渲染字符处形成一个停靠点，包括继承覆盖；显式子 map 单独形成停靠点。从 owner 内部
移动时跳过该 owner。导航尊重 narrowing 与不可见文本，忽略普通 buffer、overlay 和
全局 map，在更新或滚动后使用当前已提交输出。目标不存在时抛出 `user-error`，point
不动；命令不循环跳转，也不绑定按键。不会求值菜单 enable 表达式或 filter，因此即使
应用动态禁用了菜单项，已声明命令仍可能保留停靠点。导航只移动 point；Ebox 不提供
独立的应用状态或焦点管理系统。
可运行示例见[交互指南](ebox-user-guide.zh.md#native-node-interaction)。

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
