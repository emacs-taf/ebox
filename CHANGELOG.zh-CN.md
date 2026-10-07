# 变更日志

Ebox 的重要变化记录在这里。

## 未发布

### 变更

- **BREAKING：** Ebox 现在暴露可变 retained-node engine。使用 `ebox-build`、
  `ebox-node-create` 或 `ebox-text-create` 构建 root；使用 `ebox-mount` 挂载；然后通过
  节点 mutation 函数更新已有树。flush 会对 dirty paths 重新计算样式、重新布局和重绘，
  并且只重写变化的 buffer 行或行内片段。

### 删除

- **BREAKING：** 删除上一代 engine 的 canonical inputs、source builders、surfaces、
  publications、transactions、prepared update/geometry API、generation/candidate 模型、
  layer module、native Rust layout module、framework SPI 与 render-burst 接口。迁移高层调用方时，
  改为保留 Ebox 节点引用而不是外部 handle：旧的完整 input replacement 对应构建或复制 retained root
  并挂载；旧的 source-builder child update 对应 `ebox-node-insert`、`ebox-node-remove`、
  `ebox-node-move` 或 `ebox-node-replace-children`；旧的 content/property/selector update 对应
  `ebox-node-set-text`、`ebox-node-set-image`、`ebox-node-set-props`、`ebox-node-put`、
  `ebox-node-set-states` 或 `ebox-node-restyle`；旧的显式 update grouping 对应 `ebox-with-batch`。
