# 变更日志

Ebox 的重要变化记录在这里。

## 2.0.1（未发布）

### 新增

- 直接依赖独立的 ECSS 0.1.0 cascade engine 与 TP 1.0.1 retained/reactive text runtime。
- Box、Flex 与 Grid 节点统一使用 ECSS property schema、selector、stylesheet、inheritance、cascade layer、custom property、computed value 与 provenance。
- 通过 `ebox-region-resolve` 提供 surface-scoped region handle；`ebox-render-to-buffer` 与 `ebox-display-buffer` 统一使用 retained TP publication；handle、selector、viewport 与 scroll 更新加入同一原子事务。
- 增加 typography longhand 与继承 foreground 的投影；子盒子覆盖背景色时仍能保持文字可读。
- 增加公开、可嵌套的 framework render-burst 边界，覆盖 commit 前分配，与 Ebox commit 共用交互 deferred GC ownership，并在 batch 边界不主动 GC 的情况下恢复原设置。
- 增加受支持的 `ebox-transaction-participant-route` 开关：默认使用 v2
  structured TP registration；显式旧 route 与旧 TP manifest 的完整 v1 adapter
  fallback 继续保留。

### 变更

- 包 metadata 现在会区分具备 public unmount/revision 边界与 SPI v2
  compatibility surface 的构建，旧的 2.0.0 development snapshot 不会再被误接受。
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

### 迁移

- ECSS 0.1.0 与 TP 1.0.1 互相独立，安装顺序任意；两者都安装后再安装 Ebox 2.0.1。
- 数字 region id 更新改为先调用 `ebox-region-resolve`，再把返回的 handle 交给 `ebox-region-update`。
- `ebox-pop-to-buffer` 或 `ebox-switch-to-buffer` 改为 `ebox-display-buffer`；如果显示行为由调用方控制，则使用 `ebox-render-to-buffer`。
- Ebox 不扫描历史渲染文本来重建 runtime identity；请通过 Ebox 2.0 重新 mount 声明式 source。
