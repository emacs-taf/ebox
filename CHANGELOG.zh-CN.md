# 变更日志

Ebox 的重要变化记录在这里。

## 未发布

### 修复

- 支持 SVG 的图形 frame 上，遮罩现在会压暗 PNG、JPEG 和 SVG，包括使用原生
  `currentColor` 的图标。缓存的内存合成保留透明度、切片、行内留白和应用调色板，
  不重新读取来源或执行外部转换；其它原生格式保持可见，但不改变图像像素。
- 同一个浮层移除后重新挂到相同坐标，也会正确重绘，不再遗留未遮挡的背景。

### 新增

- 键盘焦点支持复合控件：`:focus-group`（`vertical`、`horizontal` 或 `grid`）使容器
  成为一个 Tab 停靠点，进入时落在选中或上次聚焦的成员上，并用方向键在内部移动；
  `:focus-scope modal` 把导航限制在打开的对话框内；`ebox-focus-direction` 移到某方向上
  最近的停靠点；`ebox-focus-scope` 和 `ebox-focus-stops` 公开当前作用域；
  `ebox-focus-change-functions` 报告每次焦点移动。

- 图形 frame 上的盒子背景支持 `:border-radius`；块方向 padding 接受行高的分数，
  例如 `(lh 0.5)`，背景会覆盖该行的相应部分，而每行仍保持一个行高。
- `ebox-image-prepare` 接受 `:inset (TOP . BOTTOM)`，在图形图像上方和下方留出几像素
  空白，而不改变图像占用的行。
- 在 macOS 上，彩色 emoji 显示为整行高度的图像，由一个用 `swiftc` 编译的辅助程序渲染，
  并缓存在 `user-emacs-directory` 下的 `ebox-emoji/` 中。
- 软换行不再让闭合标点出现在行首，也不再让开启标点出现在行尾。
- `ebox-input-begin` 接受 `:on-change`、`:on-leave`、`:keymap` 与 `:local-variables`；
  `ebox-input-edit-commands` 列出 keymap 中会编辑值的命令。
- 样式 `:scroll-anchor end` 让滚动容器在内容变化时固定在最后一行，直到用户滚离，
  适用于日志和聊天视图。
- `ebox-node-scroll-into-view` 滚动外层滚动容器，使节点可见。
- 交互属性 `:swipe` 在节点上每次水平双指触控板手势时收到一次 `left` 或 `right` 调用，
  惯性滚动会被吸收。
- 交互属性 `:scroll` 在滚动改变滚动容器的行偏移时收到新的行偏移，便于列表在边缘
  加载更多行。
- `ebox-node-scroll-into-view` 接受可选的 `start` 或 `end` 对齐方式。
- `ebox-viewport-measure` 在 buffer 挂载之前返回其挂载将占用的 viewport。
- `ebox-viewport-change-functions` 在已挂载 buffer 的 viewport 尺寸变化且新布局
  稳定后，以该 buffer 运行。
- `make native` 会字节编译 Ebox，并把 native code 存入用户的 `eln-cache`，Emacs 会
  加载它来代替字节码。

### 变更

- **BREAKING：** Ebox 现在暴露可变 retained-node engine。使用 `ebox-build`、
  `ebox-node-create` 或 `ebox-text-create` 构建 root；使用 `ebox-mount` 挂载；然后通过
  节点 mutation 函数更新已有树。flush 会对 dirty paths 重新计算样式、重新布局和重绘，
  并且只重写变化的 buffer 行或行内片段。
- 当编译后的 `.ebox` 伴随文件的字节码比 `.el` 源文件新时，`ebox-file-load-companion`
  会加载它；已编辑的源文件仍直接加载。
- 输入会话不再让已绘制文本变为可写，也不再推迟挂载的 flush。它在隐藏 buffer 中用
  原生命令、undo 和输入法编辑节点的值，同时节点保留其 padding、边框和换行，并随值
  增长。在节点内单击、拖动、双击和三击都会编辑该值，输入法的预编辑文本会在节点内
  换行，而不会溢出节点。
- 没有锚点的 `:layer root` 绝对定位盒子改为依据 root 的 border box 而非 content box
  确定位置和尺寸，因此全尺寸的遮罩或查看器会覆盖 root 的 padding。

### 删除

- 包内手册 `docs/manual.md` 由 [ETAF 参考手册](https://etaf.top/zh-cn/ebox-node-construction/) 取代，README 与包入口 Commentary 改为链接手册；`docs/architecture.md` 仍是维护者契约。

- **BREAKING：** 删除上一代 engine 的 canonical inputs、source builders、surfaces、
  publications、transactions、prepared update/geometry API、generation/candidate 模型、
  layer module、native Rust layout module、framework SPI 与 render-burst 接口。迁移高层调用方时，
  改为保留 Ebox 节点引用而不是外部 handle：旧的完整 input replacement 对应构建或复制 retained root
  并挂载；旧的 source-builder child update 对应 `ebox-node-insert`、`ebox-node-remove`、
  `ebox-node-move` 或 `ebox-node-replace-children`；旧的 content/property/selector update 对应
  `ebox-node-set-text`、`ebox-node-set-image`、`ebox-node-set-props`、`ebox-node-put`、
  `ebox-node-set-states` 或 `ebox-node-restyle`；旧的显式 update grouping 对应 `ebox-with-batch`。

### 修复

- 指针悬停改为按节点自身的计算样式重绘整个节点，不再只画一条矩形文本带：
  悬停的控件保留 `:border-radius`，并覆盖全部内边距行；指针离开后在同样的行上
  恢复静止样式。

- 叠放布局中超宽子项的绘制先裁剪到父级内容宽，再参与浮层合成。移动或调整
  重叠窗口时，隐藏内容不再撑宽画布、挤偏相邻窗口或造成图像横条错位；子项的
  固有尺寸保持不变。
- 原生整行图像与已有图像切片都支持部分遮挡裁剪，并保留基线修饰。窗口只盖住
  图像行的一部分时，未被遮挡的其余部分不再整行消失。

- Buffer 文本缩放后 mounted tree 保持对齐：缩放稳定后清空共享字形缓存并整棵重新布局，
  滚轮缩放已挂载应用不再按上一档度量把行切开。

- 从按钮开始原生输入时，启动手势的鼠标松开不再被误判为离开文本区、立即结束
  会话；字段内嵌控件除非显式结束编辑，否则保留会话，后续点击外部仍正常触发离开回调。

- 挂载期间禁用 Emacs 原生续行，避免对已排版行二次折行、在右侧留下续行列色条；
  卸载时恢复 buffer 原有的折行设置。
- 固定高度 flex 容器中的文字增减不再误插或误删外部 buffer 行；多行原生输入、
  清空和撤销保留后续内容，包括独立更新的动画页脚。

- 双指横向手势反向时立即开始并触发下一次滑动，连续左右划每一下都能生效，
  不必等惯性滚动结束。
- 被宿主裁剪的交互 overlay 在空白行以及在裁剪边缘被截断的 padding 上保留其 keymap、
  指针和帮助信息，因此在这些位置的点击能到达它。
- 图形图像的透明像素显示承载它的盒子背景，而不是 frame 背景，因此圆形头像能融入
  高亮行。
- 在图形 frame 上，回退字体比行更高的字形（例如彩色 emoji、符号、数学字母和其他
  回退文字）会缩放以适应其所在行。每行保持一个行高，因此旁边的图像切片（例如头像）
  保持衔接。
- 在输入会话之外，于已挂载 canvas 中按下可打印按键不再向应用 buffer 插入文本。
- 节点的边界包含其自身绝对定位子节点下的单元格，例如范围控件的填充部分。
- 对 padding 或 gap 单元格调用 `ebox-node-at` 时返回拥有该单元格的最内层盒子，
  而不是 root。
- 对滚动容器内的空白或 padding 单元格调用 `ebox-node-at` 时返回该单元格下的最内层
  盒子，而不是滚动容器。
- 图形图像每行只绘制一个切片字形，而不是每个单元格一个，因此滚动和重绘包含大量
  图像的视图不再卡顿；在盒子或 overlay 边缘被截断的图像行保留其可见部分。
- 滚过滚动容器末尾时，不再滚动已经显示整个 buffer 的窗口，因此固定的页眉和页脚
  保持原位。
- `ebox-buffer-mode` 在已挂载 buffer 中关闭 `show-paren-mode`，并在该模式禁用时
  恢复，因此绘制的文本不会显示括号匹配或不匹配高亮。
- 比拉伸后盒子更窄的图像会在其旁边绘制盒子背景，因此较宽气泡中的照片不会留下
  未绘制的空隙。
- 在没有右侧 fringe 的窗口中，已挂载 viewport 在截断列之前结束，因此全宽行不再显示
  Emacs 的 `$` 字形。
- 已挂载 buffer 显示在另一尺寸的窗口中时，即使没有任何窗口缩放，也会重新适配该窗口。
- 宽于其盒子的内容在盒子边缘被截断，因此同一行中后续兄弟节点保持原有列位置，
  不再向右偏移。
- 内容填充原本为空的已挂载 buffer 时，point 和窗口起始位置保持在顶部，因此应用打开
  时不再滚动到 buffer 末尾。
- 已挂载 buffer 的默认背景跟随 root 的背景色，因此最后一行下方的不完整行以及布局
  文本之外的其他空间与应用表面一致；卸载时会移除该重映射。
