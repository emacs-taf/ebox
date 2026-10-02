# 变更日志

Ebox 的重要变化记录在这里。

## 3.0.0（未发布）

### 新增

- 图片内容可占用固定字符网格：图形 frame 使用缓存的逐格 image slice，其余环境
  通过可选 chafa / ffmpeg 生成真彩色半块文本，最后回退到 ASCII 占位网格。
  `ebox-image-prepare` 独立完成解码，同尺寸换封面只发布保留块，渲染期间不运行
  转换器；`ebox-image-info` 报告实际适配器。

### 变更

- 发布、文本属性快照与绘制槽由 Ebox 统一维护。Ebox 和 ETAF 须一起升级到
  SPI v3；发布协议为 `ebox-publication/v1`，报告提供方为 `ebox-publication`，
  报告字段使用 `:publication-*`。
- 原生与 Elisp 输出共用归属映射；节点关系不变的局部更新复用已发布索引，
  减少重复祖先解析和按节点创建的临时哈希表。
- 候选缓存保留淘汰统计，发布时按代核对私有索引而不重复重建验证集合；仍检查完整
  buffer 输出，拒绝回调或 hook 对结果的意外修改。

### 修复

- 文本内容只在固定槽位内变化、画面同时存在像素小数余量和保留滚动区时，重新按
  局部 span patch 发布：原始量化路径接受与所有滚动盒不相交的纯内容属主，并把
  已提交的角色/溢出拓扑带入私有渲染。秒数标签不再整树重建候选。
- 内容更新同时比较字符和文本属性，换图或更新彩色字符网格不会再误判为 no-op。
  局部更新在原有归属、输出验证和回滚合同内重新生成带属性内容；空行归一化保留
  图片 display slice。
- 按压位置的绘制链未到达任何 keymap 声明时（如 Flex 间隙、padding 与裁剪后的
  尾格），主按钮归属改为通过已发布的 keymap 快照索引解析到声明节点，这些位置
  的按压会正常触发所属节点。
- 按键位置的已发布 keymap 不再对应存活节点时，按压不再报
  "No enabled Ebox drag target at the press position"，而是把这一次按压与释放
  留给 Emacs 的常规鼠标处理。
- 移除带样式的内容时，其样式状态也退出当前节点代；关闭浮层或删除普通兄弟节点后，
  其他区域的焦点、背景色及局部内容更新仍可复用增量路径。
- 百分比布局在中间结果恰好为整数像素时仍保留原始分配证据；进度条从满格恢复为
  部分填充时，不再丢弃有效的局部投影。
- 局部内容更新后的焦点和按压状态变更保留选择器元数据分类，不再无必要地重绘根节点。
- 可见溢出的 Flex 在 viewport 更新的无缓存几何探测中不再访问缺失的
  测量缓存，尺寸变化可以继续发布。

- 原生 Box 将确定的内容高度传给内部 Flex 排版，包括父 Flex 分配的主轴或
  交叉轴高度；拉伸的嵌套单元格保留完整背景。自动高度仍按内容确定。

- 原生 Box 保留 Flex、行与列布局已排好的内容，不再把相邻元素再次折行。
  普通文本仍按自己的 wrap mode 排版。

- 原生 frame 在根节点字体上下文中解析字体相关宽度，不再用 viewport 宽度替代。
  保留 frame 使用实际已提交的根宽度作为后续发布基准。

- 原生 Flex 布局支持包括零在内的可编译主轴显式最小尺寸，并与 Elisp
  保持相同的 overflow 自动最小尺寸及尺寸上限语义。请为 ABI `18:8:12` 重新构建
  可选模块并重启 Emacs；旧模块不能提供修正后的语义。不支持的场景特性仍走普通渲染。

- viewport 更新在判断样式稳定性时包含已挂载的局部与共享作用域，
  未变化的作用域样式能够继续使用保留式重排。

- 保留节点的内在尺寸测量沿用已计算的作用域样式。更新带作用域的应用时，
  不再尝试把祖先作用域挂载到脱离整树的局部节点，避免分页等操作报错。

### 新增

- 侧栏选中项的背景、粗体和水平边框可与相邻标题区的标题、副标题一起，通过独立的
  保留槽位发布，避免重新渲染整帧。每个槽位仍须保持精确的外部尺寸；内在宽度或
  content-box 增长继续使用普通布局，并保留原子回滚。
- 已完成样式准备的 Box 可在子节点数量相等、精确分配尺寸不变时，仅渲染并发布
  被替换的子树。新控件获得当前身份和属性；尺寸不兼容、滚动、图层或缺少样式
  证明时保留普通渲染与回滚。
- 原生 Box 宽度、最小／最大宽度及行向 Flex basis 支持 `vw` 长度，始终以
  frame viewport 为参照。缩放时重新解析，不能精确表示为整数像素时回退；
  复合 viewport 表达式、间距与其他相对单位仍使用普通渲染。

- 固定单行 Grid 的拉伸、裁剪单元格可通过原生 frame 发布。轨道分配包含
  单元格边框、内边距与 box sizing；更新后超出此子集时使用普通 Grid 渲染。

- 显式原生节点能力 `:help-echo`、`:pointer`、`:hover-style` 与 `:keymap`，包含回调
  适配器 `ebox-help-create`、`ebox-keymap-create`、嵌套覆盖、显式 nil 阻断和 retained
  更新。不需要 ETAF 或任意文本属性逃生入口。
- 可选 `ebox-next-interaction`、`ebox-previous-interaction` 导航命令，在渲染后的
  keymap owner 之间移动；不安装默认导航绑定或应用状态系统。
- 显式几何单位 `px`、`%`、`vw`、`vh`、`ch`、`lh`，可组合的
  `calc`/`min`/`max`/`clamp` 函数，以及构造时的属性方向验证。
- 仓库级 GPL-3.0-or-later 许可证与统一的 Ebox/Rust 包声明，保留第三方声明。
- 固定依赖输入与可复用的源码归档构建/安装验证器（`make release-check`），包含
  可选 EKP 和显式 native 模块集成。CI 补齐 ECSS 与 TP、测试最低支持 Emacs 版本，
  并配置了三个平台的 native 加载与执行。
- 直接依赖独立的 ECSS 0.1.0 cascade engine 与 TP 2.0.0 retained/reactive text runtime。
- Box、Flex 与 Grid 节点统一使用 ECSS property schema、selector、stylesheet、inheritance、cascade layer、custom property、computed value 与 provenance。
- 通过 `ebox-region-resolve` 提供 surface-scoped region handle；`ebox-render-to-buffer` 与 `ebox-display-buffer` 统一使用 retained TP publication；handle、selector、viewport 与 scroll 更新加入同一原子事务。
- 增加 typography longhand 与继承 foreground 的投影；子盒子覆盖背景色时仍能保持文字可读。
- 增加公开、可嵌套的 framework render-burst 边界，覆盖 commit 前分配，与 Ebox commit 共用交互 deferred GC ownership，并在 batch 边界不主动 GC 的情况下恢复原设置。
- 所有 retained publication 统一使用 structured TP participant registration。

### 变更

- `ebox-display-buffer` 先完成渲染，再调用原生 `display-buffer`，接受可选 action，
  返回渲染结果 buffer。普通显示不再删除其他窗口或选中结果窗口。
- `:overflow hidden` 现在也限制横向内容宽度，包括组合后的子节点输出，并保留自身
  padding 与边框。裁剪保留受支持的文本簇和可见属性、移除被裁掉的子节点交互，用空白
  补齐剩余像素，不加省略号。复用 GPL 兼容的 s-pixel 思路，不增加依赖、半字形遮罩或层叠。
- `:wrap-mode kp` 明确要求可选 EKP 包。缺失或不兼容时提示安装/更新，不再静默改用
  单词换行。其他换行模式不需要 EKP。
- TP 最低依赖提升到 2.0.0 与最终 v2 participant 协议。原生 keymap 所有权、回调身份
  和共享 hover 范围需要其属性策略，原来的 TP 1.0.1 过渡基线不满足这些要求。
- 增量更新复用已证明不变的样式、身份、所有权与视口事实。内容和绘制变化保留最小
  安全发布范围，几何或依赖变化仍在必要时提升 owner。TP 发布实际变化的文本区间，
  并保留失败回滚。
- 每个渲染行内，hover 将声明 owner 的文字与 padding 作为一个原生悬停区域，并保留
  物理左右边框；子节点显式 hover 声明仍形成独立区域。
- 包 metadata 现在会区分具备 public unmount/revision 边界与 SPI v2
  compatibility surface 的构建，旧的 2.x development snapshot 不会再被误接受。
- 早期 3.0 开发使用 TP 1.0.1 的 structured 过渡协议；当前候选版本要求 TP 2.0.0
  或更新版本，并始终只调用公开 structured participant API。
- SPI initial publication 自己负责 widening 与外层 editor change group。stage
  失败或 rollback 非局部退出向外传播前，会恢复 text、marker、overlay、point、
  mark、narrowing、undo history 与 modified state。
- ECSS 是唯一 selector matcher 与 cascade winner。Ebox 只把节点树适配为 ECSS subject，解释 computed value 的测量、布局与绘制后果，并分类 layout impact。
- TP 是唯一 live buffer writer。Ebox 只生成 retained surface candidate 与语义 dirty-owner plan；diff execution、marker-backed mount、revision、transaction 与 rollback 都属于 TP。
- Flex/Grid container 与 item declaration 和普通 box 一样进入同一条 ECSS pipeline，不再维护平行 style path。
- Region 更新改用 opaque、surface-scoped handle；同一份声明式 source 可以挂载到多个 buffer，而不共享 live identity。
- 只有继续已提交 native frame 的 full declarative update 才会在 stable native
  eligibility 前计算完整 selector-local style certificate；其他 full/local 路径
  保持原有 O(changed) style work。native update 不再提交缺失 computed style 的
  replacement runtime，结构性 full-frame bootstrap 继续保留。

### 删除

- `ebox-pop-to-buffer`、`ebox-switch-to-buffer`，以及它们暴露的私有 erase-and-evaluate buffer writer。
- Ebox 内重复的 selector parser/matcher 与 cascade winner。
- 仓库内置 playground fixture；可执行 `.ebox` reference 已迁到独立 `ebox-playground` 包。
- Ebox transaction route 开关、v1 TP participant adapter 调用，以及 capability
  缺失时的 fallback。

### 迁移

- 将旧几何字面量改为显式单位：例如 `:width 80` 改为 `:width (ch 80)`，
  `:width (240)` 改为 `:width (px 240)`，`:height 3` 改为 `:height (lh 3)`。
  动态值在产生处明确单位。纵向几何不接受 `px`，`fit-content` 只使用裸关键词。
- 需要选中或独占显示的调用方应显式选择相应窗口策略；普通 `ebox-display-buffer`
  遵循原生显示规则。只渲染不显示时仍使用 `ebox-render-to-buffer`。
- 仅在使用 `:wrap-mode kp` 时安装 EKP 1.0.0 或更高版本；其可选 native 加速器与
  Ebox 的可选 Rust reflow 模块独立。
- ECSS 0.1.0 与 TP 2.0.0 或更高版本互相独立，安装顺序任意；两者都安装后再安装
  Ebox 3.0.0。
- 删除 `ebox-transaction-participant-route` 的自定义设置；Ebox 3.0.0 要求 TP
  提供 structured participant capability，缺失或格式错误时会 fail closed。
- 数字 region id 更新改为先调用 `ebox-region-resolve`，再把返回的 handle 交给 `ebox-region-update`。
- `ebox-pop-to-buffer` 或 `ebox-switch-to-buffer` 改为 `ebox-display-buffer`；如果显示行为由调用方控制，则使用 `ebox-render-to-buffer`。
- Ebox 不扫描历史渲染文本来重建 runtime identity；请通过 Ebox 3.0 重新 mount 声明式 source。

### 发布状态与支持边界

- `3.0.0` 仍未发布；这些修改准备源码分发，不代表已上传包归档或发布版本 tag。
- 每个已挂载 buffer 拥有一套视口布局，需要独立宽度的视图使用不同 buffer。纵向
  几何仍以完整行为单位。
- 保留常见 UI 文本簇，但完整 Unicode 字素分段、浏览器级双向布局、层叠和绝对定位
  不属于当前契约。
