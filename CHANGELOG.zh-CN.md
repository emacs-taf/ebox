# 变更日志

Ebox 的重要变化记录在这里。

## 3.0.0（未发布）

### 新增

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
