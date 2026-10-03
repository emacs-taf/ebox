# Ebox 增量更新合同

本文定义底层发布合同。它独立于 ETAF 应用状态，直接使用 Ebox 的调用者和上层包都必须遵守。

## 预准备图片内容

`ebox-image-prepare SOURCE COLUMNS ROWS` 是统一的能力选择入口，返回占用正整数
字符网格的不可变准备结果。`SOURCE` 可以是本地文件路径，或带 `:type` 与
`:file` / `:data` 的 Emacs image descriptor。文件读取、解码和外部进程全部属于
prepare 阶段；缺失、不可读或不支持的图片降级显示，参数错误则在发布前报错。
不支持远程文件，不增加包依赖。

选择顺序为 graphics → text converters → placeholder。Graphics 要求
`display-graphic-p`、可用的默认字体度量、受支持的图片类型，以及按目标尺寸成功解码。
`:adapter text` 跳过图形，`:adapter placeholder` 跳过前两级。
`ebox-image-info` 返回 `:adapter`（graphics/text/placeholder）、`:converter`、
`:columns` 和 `:rows`。

图形准备阶段从自有源字节创建并解码一个 image，像素尺寸为
`columns × frame-char-width` 和 `rows × frame-char-height`，显式指定 scale 1、
margin 0。每个字符持有 `((slice X Y CELL-WIDTH LINE-HEIGHT) IMAGE)`，所有格子共享
同一 descriptor。`:ascent` 是默认字体真实 ascent 与行高之比向上取整的百分比，
因为 redisplay 会将百分比截断回整数像素；无法精确表达 ascent 的字体度量回退到
文本适配器。没有硬编码的最小像素高度。重复渲染复用同一 descriptor 和不可变 slice 对象。
带图片 display 的空格属于可见内容，不允许空行归一化将其替换成填充空格。

文本适配器先尝试可选的 `chafa`，要求完整 RGB、仅使用 U+2580、拉伸到指定尺寸、
只处理静态帧，禁用终端探测及光标移动，并把 ANSI 颜色转为普通 `face` 属性。
不可用、失败或输出无效时，`ffmpeg` 将一帧缩放为 `columns × (2 × rows)` 的
RGB24 像素：上像素成为每个 `▀` 的前景色，下像素成为背景色。两者都填满分配区域，
终端的颜色近似由 Emacs 负责。两者都失败时，使用相同尺寸的 ASCII `.` 单色占位
网格；占位器自身不启动进程。

`ebox-image-converters` 是按顺序尝试的 `(NAME . FUNCTION)` 协议，也可通过
prepare 的 `:converters` 提供。函数接收 source、columns、rows，返回 nil 或精确
网格：行间一个换行、末尾无换行，每行 columns 个 `▀`，每格 `face` plist 包含
`#RRGGBB` 格式的 `:foreground` 和 `:background`。异常或格式错误尝试下一个函数。
只接收这两个颜色属性，复制转换器的字符串和颜色以及调用者的 descriptor；
转换器不能注入 display、keymap、归属或其他属性。验收测试用可执行 fixture 测试
两个默认转换器，无须安装 chafa 或 ffmpeg。

缓存最多保留 64 份准备结果，键包含源身份、列数、行数、适配器/转换器协议和
图形字体度量。文件身份包括绝对/解析路径、大小、修改及状态时间、inode；
descriptor 的 data 按值参与比较。`ebox-image-cache-clear` 用于转换器配置或
可用能力变化，不影响已发布内容。文件、frame 或字体变化后需要重新 prepare，
渲染应使用准备时 frame 的默认字符网格；buffer 局部 text scale 和祖先 font-size
覆盖不是 prepare 的输入。
CSS 尺寸覆盖仍由普通 Box 布局证明负责。

`ebox-image-create PREPARED BUILDER &rest SOURCE-PROPERTIES` 返回一个规范 Box，
内部只有一个自有 Text 子节点，声明固定 `(ch columns)` / `(lh rows)`、hidden
overflow 和禁止换行。它接受 source-builder 的身份、`:id`、交互、样式作用域等
元数据，但不接受与固定尺寸冲突的 `:declarations`。Row、Column、Flex、Grid、
裁剪、源快照和回滚均沿用普通内容合同，没有独立的图片发布通道。

```elisp
(let* ((cover (ebox-image-prepare "/music/cover.png" 24 12)) ; 冷路径 I/O
       (builder (ebox-source-builder-create))
       (node (ebox-image-create cover builder :identity 'cover :id "cover")))
  (ebox-render-to-buffer
   buffer
   (ebox-canonical-input-create
    (list node) (ebox-source-builder-finish builder))))

;; 在渲染/提交回调以外准备；发布只使用缓存内容。
(let ((next (ebox-image-prepare "/music/next.png" 24 12)))
  (ebox-region-update (ebox-region-resolve buffer "cover")
                      :content (ebox-image-content next)))
```

`ebox-image-content` 返回自有字符串，内部图形 display 值不可变并共享。同尺寸换图
通过普通 `:content` 更新或规范节点替换加 `ebox-commit` 发布。no-op 判断包含文本
属性，因此字符同为空格或半块而像素不同仍是内容变化。带属性的内容重新生成自有
属性并组合已证明的祖先绘制，不运输旧像素颜色或 slice。分配、角色、归属、输出
验证和原子回滚检查全部保留。24×12 封面加歌词的验收要求已提交报告为
`span-patch` / `owner-scoped` 投影、一个 dirty node、一个 patch、无 full-root
发布，并与导出源及全新渲染比较。尺寸变化使用节点替换和常规布局规划。

24×12 的图形准备成本为一个已解码 descriptor 和 288 个 slice；文本准备为
576 个 RGB 样本（1,728 原始字节）转成 288 个半块；占位器生成 288 个 ASCII 格。
每份缓存网格含 11 个换行。commit 复制并发布准备好的块，执行普通保留式验证，
不创建 image、不运行转换器。prepare 是同步冷操作，调用者可在交互前调度。

`benchmarks/benchmark-image.el` 分别测量冷准备、准备缓存命中、自有内容复制和同尺寸
commit。使用常规 batch load path 并调用 `-f ebox-image-benchmark-batch`；文本使用
实际已安装的转换器，batch 图形明确标记为模拟，耗时不含原生解码和 redisplay。
相同占位像素正确地产生 no-op commit。Emacs 31.1 的原生 SVG 检查使用 7×16 字符格、
13 像素字体 ascent，确认 `:ascent 82` 对应 16 像素 slice 行，十二行封面加一行歌词
共 208 像素。

## 发布运行时

Ebox 自己持有保留式发布运行时。投影、文本/属性写入与回滚共享同一份已准备候选，
不再转换成另一个包的 target-entry 或 outcome 对象图。发布器只接受 content surface，
保留一份失败恢复基线，在接受框架 authority 前核对最终文本及属性。原来的通用 watcher、
properties-only surface 和外部变量 signal 适配路径已删除。

surface 上下文追踪 viewport、display 和 scroll 输入，样式绑定保留准确的依赖关系；
应用 ref 仍归 ETAF。原生属性组合与 paint slot 归 Ebox，选择器和层叠语义归 ECSS。
框架只通过 SPI v3（`ebox-publication/v1`）接入发布。

候选输入在发布器安装私有对象和挂载索引前完成验证。提交前按身份核对已安装的代，
不再重新构造集合来复查同一发布器刚生成的私有索引。公共回调和 buffer hook 仍可能
改动文本或属性，因此在生命周期结算前及最终接纳时都核对完整预期输出。
已认证的不变子树通过子树证明保留对象及存活绑定，不再把每个身份复制进候选集合。
新对象不能仅凭相同路径继承这份证明。

发布器自身产生的错误只携带脱离运行状态的诊断：保留对象 ID、数值坐标、去属性的
短字符串和有界集合，不把 surface、挂载或回调循环图交给 Emacs 错误输出。
错误类型及回滚顺序保持不变；调用方主动产生的错误保留原始数据。诊断载荷不是
可操作的运行状态句柄。

## 所有权

1. 调用者拥有新的 source tree。
2. `ebox-tree.el` 拥有 identity、key、遍历和 snapshot。
3. `ebox-style.el`、`ebox-measure.el` 与布局模块拥有归一化、测量和几何。
4. `ebox-incremental.el` 拥有 dirty 分类、live fact 适配、纯声明式 commit 准备和 Ebox 报告语义；`ebox-patch-plan.el` 只用不可变 parent fact 归并 tentative operation。
5. `ebox-surface.el` 投影 retained candidate，并让 Ebox runtime-state 发布加入 Ebox publication transaction。
6. Ebox publication 拥有首次 mount、声明式 commit、handle 更新、viewport/theme 更新和 scroll 更新的通用 retained-surface reconciliation、mount/index 状态、全部 live buffer diff 执行、revision 变更和 rollback。
7. `ebox-buffer-backend.el` 只构造和整形带文本属性的渲染字符串，不拥有 live marker 或 buffer mutation executor。

任何层都不能从可见 buffer 文本推断应用状态；公共调用者不能原地修改已经发布的树。每条公共 live 发布路径，包括 `ebox-render-to-buffer`、其展示包装 `ebox-display-buffer` 以及 commit/update 入口，都使用 retained Ebox publication surface；公共门面不再提供擦除 buffer 后执行任意 BODY 的 writer。

原生与 Elisp 的片段记录共用归属投影。节点关系已证明不变时，沿用已发布的节点／对象和
region／对象索引，只解析尚未出现的角色组合。候选缓存只保留当前输出使用的组合，
失败候选不能修改上一代缓存；结构变化及完整回退重新构建索引。语义相等的角色标签副本
与同一标签对象一样保留挂载身份，同时仍验证对象身份和准确的候选坐标。

候选渲染缓存同时复制淘汰队列及已计算的空间占用，只隔离会修改的表和队列向量。
沿用不可变输出时不重新遍历全部缓存对象来统计内存；容量配置变化仍通过队列执行淘汰。

小数像素布局的原始分配与最终取整输出共用角色和绘制记录。像素取整只改变显示宽度，
初次投影因此只解析一次，之后的局部编辑无需重新解析完整的原始画面。

原始分配证据属于已保留的代，不取决于当前输出是否含小数宽度。中间结果变为整数时，
仍为下一次更新保留这些证据。计算效果归一化也保留已分类的选择器元数据；再次处理
已保留的状态，不能把没有显示变化的交互转换成根更新。

样式图归属于一个已发布的节点代。完整对象投影只保留候选中同时存在的对象和绑定的
样式状态。已移除或不再使用的绑定在发布后退出生命周期；弱表回收和绑定当前是否存活，
都不能代替候选成员关系。移除浮层或普通兄弟节点不会使其他区域的后续局部更新失效。

局部内容槽位复用要求父布局分配独立于变化的内容。仅有相同的父节点声明和保留
坐标不能证明这一点：内在宽度可能变大或变小，改变兄弟节点的对齐和填充。
这类更新在发布前提升到负责分配的包含布局。

带 ECSS 语义标记的声明值及 custom property 保留在 source facts 中，直到
层叠计算。候选规范节点只填入具体 engine 值，带标记的尺寸不直接进入布局。
完整渲染和保留的 source 更新都会为这类声明请求样式计算。仅绘制变化的
快捷路径要求具体输入；子节点即使显式声明了属性，其中的 `var()` 或
`inherit` 仍可能依赖父节点。

局部 stylesheet facts 可以携带明确的 source 身份目标集合。候选 source index
把身份解析为自身的选择器 subject，作为集合快照传给 ECSS 作用域。保留的 source
重绑定和规范导出保留目标事实。只有有序作用域定义、成员资格及选择器 subject
身份都不变时，作用域缓存才共享同一代。内联绘制更新复用相等的不可变 subject；
选择器事实、关系或作用域声明变化时建立新代。样式所有权独立于物理父子关系和
live buffer 坐标；ECSS 继续拥有结构匹配与继承。

选择器 subject 保存不可变本地元数据及稳定的父子关系键。每个 source generation
通过自己的持久索引和 ECSS subject adapter 解析这些键。候选树路径复制只更新
受影响 subject，不需要修补未变化子节点的父对象引用，也不修改已发布的树。
查询条目和查找表可以延迟更新；样式计算已经拥有一致的候选关系，不因查询缓存
过期而重建关系树。

层叠复用比较挂载 source 身份、规则、目标成员资格和继承值。每代样式状态保留
当时使用的不可变父样式；遍历子节点时父绑定可能已包含候选值，不能再用其可变的
最新值代表已提交的继承输入。这使 Theme 颜色捷径在父字体变化时也能正确更新
具有显式颜色的后代。父颜色增量必须对应
父节点计算后前景色的实际变化；父样式未变时保留原计算函数与依赖图。只有父颜色
变化时，显式指定前景色的子节点继续复用其不可变样式。只依赖 subject
自身的选择器按每个绑定的有序规则输入、成员资格和祖先身份链判断复用；增加或
移除其他成员不会让未受影响的绑定失效。Subject 元数据、作用域根、适用规则
版本和父样式绑定仍参与校验。ECSS 分类选择器依赖，Ebox 证明宿主关系和作用域
事实；结构选择器仍完整失效。这减少普通投影中重复的样式工作，不代表所有原生
属性或混合更新都已经采用局部投影。

原生结构更新可以复用显示对象，同时仍需完整样式投影。此时，候选重建选择器
关系，并在原生布局消费节点前为所有节点应用当前样式。对象身份保留本身不构成
样式复用证明；结构稳定的原生更新仍需满足规划器的预计算样式契约。

Canonical 输入的选择器元数据变化会准备完整候选样式树，包括仅由规则设置
样式的节点。两种渲染器都在规划前接收完整的计算结果变化，包括 source delta
之外因样式而改变的节点；检查只访问 Style Adapter 本次准备的节点。
原生续用读取已发布 fragment ledger 中确认的 frame 及其根几何；
临时渲染字段只承载当前尚未发布的结果。原生计划必须具备可执行的 viewport，
才能跳过普通投影。
完整 frame 还必须排除垂直 `stretch`、`min-content`、`max-content` 和
`fit-content` 尺寸，包括未变化后代的高度上下限。这些编译器限制在规划时选择
Elisp；水平 stretch 与受支持的自动或确定高度仍可使用原生路径。
不支持的 Grid 形状也在编译前拒绝。不变节点分区可以保留准入证明；候选只需对照
已接纳节点索引的身份，验证准确的变化分区。

坐标稳定的保留式行更新只展开变化行和相邻保护行。复用片段记录前，原生发布验证
行坐标、字符坐标、片段边界与归属保持不变。绘制增量同时替换属性模板和样式 ID。
坐标或归属变化、活动滚动生产者及未证明的根元数据仍使用完整编码器。两条路径
共用同一发布批次、输出验证和回滚边界。变化证明只属于当前事务；确认后的 frame
不会通过证明链持续保留前代。同步 session fork 共享不可变的已确认数据，不启动
队列线程；首次异步提交才启动有界工作线程池。

局部样式预计算读取候选的挂载作用域，并在复用前比较已发布上下文。依赖树关系
的匹配交给完整投影；未完成的 author 样式转换在局部几何探测之前确定这一边界，
避免探测过程中把子树当作完整样式树渲染。每次成功的局部投影仍保留完整样式表
签名，供下一次更新使用；计算范围缩小不意味着可以丢弃已发布的上下文。保留样式绑定时，绘制 owner 同样
需要检查选择器事实：结果分类为绘制变化，仍可能来自 class 或交互状态变化。

局部 owner 证明从候选 source index 解析作用域签名，包含不可变规则版本与成员
身份，不依赖当前动态渲染环境。保留祖先原生 keymap 时使用 Ebox publication 的属性相等策略：
绑定相同的防御性副本仍然等价，命令、前缀映射或继承绑定变化则必须发布。

规范构造者与 DSL 通过 Ebox 拥有的统一声明投影取得临时 LayoutConfig 和 outer
字段。该投影排除延迟值并缓存具体配置，不取得 source 声明所有权；完整声明仍是
层叠计算输入。

共享样式描述是不可变 stylesheet 快照。规则更新保留成员身份，各根选择自身的
规则版本，旧输入保持不变。Source record 携带成员与根标记，候选 source index
将标记归并为 ECSS 挂载；多根无需合成可见节点。成员归属属于候选版本，slot
插入与移除通过普通 source delta 改变归属。层叠签名包含描述身份、stylesheet
版本、挂载 source 和成员身份；没有根的描述在组合到根之前不贡献规则。

原生 Box 将解析后的确定内容高度（包括父 Flex 分配及高度上下限约束）传给
内部 Flex 排版上下文，子布局求值请求保留该分配。未确定的自动高度仍由内容
决定，不能把环境 viewport 高度当作分配值。

同一原生 frame 内，按 source 地址和完整约束共享已完成的布局请求，包括两个
viewport 轴、内在尺寸模式、尺寸覆盖和滚动效果模式。Flex 的不同测量阶段可以
复用相同子树结果，不再重复执行其布局。此 memo 属于不可变 frame 的本次事务，
结束后丢弃。每个调用者保留自己的使用边，并相对自己的上一结果计算变化；最终
滚动所有权仍与测量探测区分。跨 frame 复用继续由 source 失效和保留求值树负责。

自动高度的单行 Grid 原生布局支持固定及 `fr` 轨道。单元格为自动放置的 Text，
或没有竞争尺寸约束和外边距、填满并裁剪轨道的 Box。轨道分配保留文本的最小
内容宽度；未确定宽度时按内容测量比例轨道，并在累计像素边界取整。单元格保留
source 所有权、边框、内边距、绘制和溢出行为；内容和 viewport 变化通过共享的
保留源及布局求值路径重新分配。其余 Grid 配置保留完整 Elisp 实现。

原生布局上下文独立保留原始 frame viewport 的两个轴，不随包含块或 Flex 元素
分配而改变。`vw` 宽度与行向 basis、`vh` 高度及其上下限与列向 basis 在 IR 中
保留相对值，每个 frame（包括保留请求）重新解析。高度 `calc` 的加减法保留
操作数符号；字体度量将 viewport 像素换算为所属节点的行高单位。小数或越界
操作数在发布前拒绝原生候选，由普通布局路径处理。其他依赖上下文的表达式
保留完整 Elisp 实现。

计算后的渲染效果签名从样式 registry 派生字段：Box 和参与布局的属性读取已投影节点值，
容器布局读取 LayoutConfig，字体读取已解析的 font fact。因此位置、层级、anchor 和
轨道／对齐变化不会丢失为 metadata，即使唯一源变化是 selector；相同计算值仍不产生
额外渲染工作。

## Commit 生命周期

框架候选把节点自身属性更新与子树、子 Range 替换区分开来。属性输入比较
前后两代作者声明，不能以计算后的布局或继承样式作为旧输入。属性操作保留
内容与子树结构，再进入 Ebox 原有的样式计算、布局、影响分类与发布流程。
消费者不判断变化是否仅涉及绘制，也不负责选择子树回退。

属性更新在结构组合后作用于仍保留的节点。被移除的节点不再接收更新，
完整根替换吸收全部操作。source index 与最终路径复制记录描述同一棵结果树。

```text
新的根树
  -> 校验与归一化
  -> 复制到 surface-owned candidate state
  -> reconciliation Ebox publication object、key 与 Ebox identity
  -> 测量/布局候选
  -> 分类 dirty owner
  -> 生成 Ebox publication surface plan 与 Ebox report base
  -> Ebox publication 准备并原子发布 buffer 变更
  -> Ebox transaction participant 发布匹配的 runtime index/report
  -> 成功后退役 Ebox timer，并预热已提交的 scroll state
```

候选要么完整发布，要么丢弃。render、Ebox publication 写入、Ebox participant 或发布回调失败时，必须保留之前的 buffer 文本、属性、Ebox publication revision、Ebox runtime identity、滚动状态和最近一次成功报告。如果目标 buffer 在发布期间被 kill，teardown 是最终状态，rollback 绝不能把它复活。

投影规划在多个局部证明之间共享 Ebox publication 挂载范围的数值快照。该只读视图只存在于
一次规划过程，在 Ebox publication 发布新坐标之前丢弃；它不替代 Ebox publication 的权威挂载状态，也不
改变 Ebox 公共查询返回防御性快照的契约。

重叠替换在合并后代写入前，先从最近的候选祖先解析中间节点。若从已提交树
复制中间路径，会覆盖该祖先对兄弟内容的修改。查询仅覆盖受影响路径，未变
子树继续共享；拒绝发布时保留已提交代和焦点。

Range 更新按祖先到后代解析，与记录顺序无关。后代地址从当前候选父节点解析，
祖先已移除的后代更新被吸收。Range delta 描述受影响的内容，owner 与内容节点
均从最终路径复制记录中进入索引；后续后代更新可能再次复制它们。大范围索引
重建同时接收最终源节点先序，包含插入和删除。两条准备路径都发布相互匹配的
树与索引代。

Runtime 身份转移保留节点与 region 身份，不复制子序列坐标。坐标属于特定的
父树；keyed 插入或重排后，按当前树重新解析或建立位置索引。
子树与 Range 替换共用同一个兄弟身份匹配器。
兄弟节点先按 author key 匹配；无 key 时，先按相同的源身份匹配。位置回退排除
新兄弟列表中仍然保留的身份，避免插入内容占用存活节点的身份、使嵌套 Host 更新失效。

完整和增量 surface 投影均把已协调的 runtime 节点身份用作 Ebox publication key，不再次按
author key 或兄弟位置判断身份。因此，插入状态标签时，后续保留的兄弟节点仍
使用原来的 Ebox publication object、样式绑定和可编辑 handle。

## Patch 顺序

焦点和按下状态请求携带已经接纳的根与 source 代。交互层确定旧、新目标，通过
不可变记录和 selector view 的差量更新局部事实，保留关系索引。只依赖当前 subject
的规则若得到完全相同的计算样式，也证明后代继承不变，可提交保留式 metadata。
关系选择器、响应式样式绑定以及实际样式变化仍进入普通准备流程。Metadata 提交
复用 viewport 依赖，并跳过不必要的布局规划；对象绑定不向已发布的 node-id 表写入节点键。

启用 observer 时，source、style、plan、layout、projection 和 transaction 分别记录
独占耗时。增量规划通过已有编排边界接收观测回调，不拥有时钟和公共报告发布。
未启用观测的更新不分配计时回调。

挂载渲染允许复用响应式子树的输出。签名包含显示上下文、相关的局部及 CSS viewport
尺寸、依赖高度的包含块高度、内在尺寸测量模式和节点输入。仅声明依赖 viewport
不能成为重复布局该分支的理由；约束改变时选择不同缓存项，无关分支保留输出。
可见 root portal 仍重新收集，不能只重放缓存字符串而遗漏合成依赖。

字面回调与原生 keymap 只以不透明身份 token 进入渲染签名，不递归展开捕获的应用状态
或循环前缀绑定。Source 发布拥有 keymap 快照，更换 keymap 会改变 token 并使对应输出
失效；弱引用身份表不延长已退役应用回调的生命周期。

后代的文本与尺寸可在分配不变的 owner 内重排。owner 保留身份、子节点拓扑、
自身布局声明及祖先分配，最终输出仍须验证精确外部尺寸、裁剪与祖先效果。
内部绘制角色可以改变；整数与数值相等的浮点数按同一几何值比较，不采用容差。
分配证明只测量变化 owner 的已发布边界，向上检查父边、布局输入和有序子节点是否
保持不变。最终 owner 输出通过外部尺寸校验后，以等尺寸输出替换即可逐层保持祖先
分配，无需重新读取祖先挂载或测量其文本；相关输入变化仍会拒绝局部发布。

单个已完成样式准备的 Box 子列表替换，也可在新旧列表均非空且子节点数量相等时
尝试复用该槽位。owner 自身布局输入及祖先分配必须保持不变，静态层叠证明必须
成功，且不能涉及滚动或图层依赖。数量相等只决定是否尝试：仍由普通子树渲染器
及精确 footprint、父槽位、overflow、祖先属性和外部补集校验授权发布。局部
角色校验使用新后代的 region 身份，被删除的 spans 则保留旧身份。Surface 投影
对象增量，将拼接后的输出交给普通 scoped 协调发布；对象集合固定的坐标批次
不能新增或移除这些后代。外部尺寸变化或缺少证明时仍使用完整渲染。

含小数像素的已提交代保留取整前的布局文本。局部 owner 使用原始分配更新，再对
组合后的物理行统一取整，保留前面兄弟消耗的小数余量。原始文本与显示文本共用
字符坐标，但几何快照独立。取整只改显示宽度，继续复用 fragment 角色、绘制来源
和未改变的祖先分配证明。纯绘制更新使原始输出缓存失效；证据不足或涉及滚动
owner 时保留完整渲染回退。
发布范围与投影策略相互独立：非 scoped 发布和空范围回退仍消费规划器准备好的投影
与源所有权。已证明仅改变选择器状态的候选保留已接受的树，新交互事实存于候选源索引。
自动 basis 的 flex item 在主轴尺寸确定且已发布 slot 等于该尺寸时保留自己的 slot；
由 grow 或 shrink 决定的 slot 仍要求 fixed basis 与主轴最小值 0。这类证明让更新
发布 item 自己的 slot，不再扩大到包含它的格式化上下文；最终仍由 surface 校验
完整替换 footprint。局部渲染会记录 paint origin，因此渲染缓存签名包含 paint-origin
采集模式，两种模式的缓存输出不能互相授权。
Grouped span 证明允许非 root owner 自己的绘制与字体变化，包括已解析的继承
font fact，并可组合后代的绘制、内容和 surface-property 更新。水平边框宽度和样式
变化还要求 border-box 的确定宽度或 stretch 宽度不变；字体变化不得影响使用字体单位的
宽度、宽度上下限或外侧 margin。仍须保留 Column 槽位或与内容无关的 Flex 分配及有序
子节点身份。owner 的样式比较只排除将重新渲染的字体与已证明的水平边框输入；祖先与
canonical 相等契约保持严格。
边框样式更新在普通几何提升之前，把继承影响合并到变化的源 owner。独立的标题和副标题
变化可共用一个较小的 fixed-basis Flex owner。所有 dirty entry 必须属于这些互不重叠的
owner 分区，整批更新才能原子发布，无需将共同祖先提升到 root。root owner 和缺少分配
证书的 owner 仍不满足这一证明。
Surface 保留候选已计算的 owner 样式，重新渲染完整 spans，并合成已证明不变的
祖先绘制，不能复制旧的局部属性。边框变化使用 owner reflow 渲染器重建内部角色；精确的
footprint、parent-slot、overflow 和外部补集校验仍决定能否发布。内在宽度或 content-box
边框导致的外部增长、无法证明的祖先 surface properties 及分配变化，在找不到稳定的外层
owner 时仍走普通回退。字体大小不包含 viewport 表达式，因此这类变化沿用原有视口依赖索引。
当已发布代没有 fractional pixel 间隙时，owner-scoped 输出直接使用整数局部 patch；只有
需要保留兄弟余数的代才重放 raw allocation。
仅供生产阶段使用的 paint-origin carrier 保留在局部 fragment ledger 和 raw allocation
副本中，但在 Ebox/Ebox publication 发布边界剥离；Ebox publication 只比较公共文本属性，从而复用未变化的 run。
交互候选的源拓扑证明会跨越 declarative preparation 边界传递，后续 runtime lowering
不再重复计算同一份 source-state overlay。
Metadata 和纯绘制交互候选保留完整挂载状态，不伪称拥有内容范围证明；只有候选挂载
规格证明范围一致的内容与几何 patch 才使用 scoped 发布。

完整层叠投影重新建立渲染签名、viewport 高度依赖与内在宽度的派生缓存。
仅按源修改路径失效不足以证明这些缓存有效：源未变的后代仍可能继承新样式。
渲染输出继续按新计算的签名复用；已证明的局部投影保留其准备阶段的缓存失效结果。

规划器优先使用 `paint-patch`，再使用 `span-patch`、`owner-rerender`，最后在几何或 identity 使小操作不安全时使用 `root-rerender`。incremental adapter 从 live generation fact 推导 tentative owner；pure patch port 随后只接收这些 artifact 与不可变 parent table。这些名称描述的是 Ebox 的语义 owner 范围；只有 Ebox publication 负责计算并执行物理文本/属性 diff。Patch 不得静默扩大语义范围。报告保留 Ebox strategy 与 planned scope，同时单独记录 Ebox publication 的实际 surface operation 和 revision。

仅选择器状态变化时，完整计算样式闭包若证明没有绘制变化，且身份、父子关系和显示
约束不变，可复用已有 paint 投影。这覆盖没有视觉规则命中的焦点和按下状态切换：
所有 surface 会进一步提交坐标不变的空 Ebox publication batch，只提升 runtime 与选择器索引，
不重新协调已提交的挂载对象；Ebox publication 直接复用已提交的 object set。滚动内容和覆盖层像素
仍被保留。任何计算样式中的绘制或几何变化继续使用普通增量规划。

source index 重建按 source 身份保留 selector subject token；只有逐项比较身份、父节点
及有序子节点均相同，才保留 topology token。因此焦点或按下状态本身不会使整个局部
作用域的层叠失效。局部样式准备读取当前 source 代，而非旧绑定捕获的 subject；相等的
计算样式保留身份，避免未变的继承继续向后代传播失效。结构选择器及真正的拓扑或作用域
变化仍执行完整匹配。该路径仍校验重建的树，不承诺交互准备具有常数时间成本。

span、owner-scoped、formatting-context 或 mixed 局部输出被拒绝时，producer 先重建普通 candidate state，再渲染完整 root。被拒绝的尝试留下的临时坐标、fragment 和 paint layer 不能授权发布。报告保留 planned strategy 与 scope；普通 fallback 的 `:projection-kind` 为 `nil`。因此，planned mixed strategy 不能证明计算始终局限在局部。

片段账本把原始角色与换行数，与派生绘制地址、行内布局依赖和归属范围分开保存。
局部替换只解析边界对齐的变化窗口；角色拓扑改变时重新计算目标归属，不重新扫描
整页文本属性。合并阶段从保留事实更新坐标、绘制序号与跨窗口行依赖；角色变化时
禁止仅凭旧坐标复用归属。角色缓存仅使用语义角色，不散列 keymap、回调闭包或完整
文本属性。无法对齐的窗口仍走普通解析，并在观测中记录 `fragment-ledger` 拒绝原因。

## 严格 retained viewport reflow

`viewport-reflow` 是一个明确的 retained projection kind，只用于范围很窄、由 proof 驱动的 viewport resize 路径。只有以下条件全部满足时，规划器才能选择它：plan 是一个 root-owned geometry `owner-rerender`；旧 root 与 candidate root 是同一个 retained root；没有 dirty entry 修改 children；node-key set、region-id set 和 parent table 都不变；旧 surface 和当前 style environment 都不需要 cascade 或 inline-inheritance 重新计算；没有 scroll state；root 没有 visible-overflow scope；旧 surface 存在非空 retained node-object table。仅改变 width、仅改变 height 以及同时改变两个轴使用同一套 proof。 样式稳定性比较当前全局 stylesheet 及从已挂载 source index 解析的作用域与已发布签名。

选择该路径后，candidate 保留已发布的 Ebox topology，并复用 retained Ebox publication node-object subtree。Producer 仍会重新执行 viewport-sensitive layout 并生成新的 surface plan；Ebox publication 继续负责 scoped buffer diff、revision、stable identity 和原子 rollback。即使最终文本 patch 很小，topology、cascade、inheritance、scroll、overflow 或 display-signature 变化也不能报告为 `viewport-reflow`。

任意 proof 条件失败时，更新必须使用普通安全 projection 路径。该 fallback 可以执行更宽的 node projection 和 Ebox publication reconciliation，但必须保持相同的输出、identity、publication 和 rollback 合同。`tests/ebox-surface-tests.el` 覆盖 retained width/height/both-axis 路径、每个不安全 fallback 触发条件，以及 candidate preparation 之后的 publication failure。

## 覆盖层合成

定位子树共享所属平面的物理文本行网格。现有 placement 遍历在生成图层记录前，
检查所有后代（包括普通 Text 与 Box）的规范字体实际行高不超过宿主。大字体会在
实际发布前拒绝候选，较小字体及行高相同的粗体不会扩大行网格。定位子树以外的普通
流保留独立字体布局。此证明使用规范字体事实，不认证调用方提供的任意 face 属性或
逐字形的 fontset 回退。内置 UI 标记还必须在用户字体配置中通过实际物理行高验证。

公共几何边界是 `ebox-region-update-geometry` 与 `ebox-region-geometry`。它们只暴露
Box 所有的位置、尺寸、边界和堆叠事实，并沿用现有 retained candidate 与 publication
事务。调用方的属性表会先校验并复制到一个 candidate，按 geometry 分类，再遵循普通
`ebox-region-update` 的 scoped planning 与 rollback；不会增加第二份几何状态。查询返回
已提交 Box 事实及注册的样式初始值的脱离式视图。

Ebox 不把这些事实解释成可拖拽窗口。`:drag` keymap 能力仍是报告手势阶段和 delta 的
输入原语；回调或 ETAF behavior 决定 delta 是否改变 `:left`、`:top`、`:width` 或
`:height`。resize handle、约束、最大化/最小化状态、focus 顺序和桌面窗口策略都在
Ebox 之上。padding、margin、border 等样式变化继续走通用 region-update，不扩大这个
位置/尺寸/图层类型边界。

Placement 在判断遮挡前保留原始行文本与像素来源区间。行签名不变时直接复用已提交
输出，无需先提取每个子元素的字符串；变化的行只从原始来源裁切实际可见的区间。
这消除了先裁切全部 flow 子元素、再对中间字符串二次裁切的重复工作。普通流、相对
偏移、portal 定位和 z 顺序共用该路径。

已准备的包含平面可将数值遮挡扫描交给可选原生模块。每个平面拥有有界的工作存储，
稀疏位置变化刷新数值缓存，模块把损伤行的可见来源区间写入复用向量。模块不持有
Lisp 值、源字符串、buffer 状态或发布基线；拒绝后，下次使用前从已恢复的源记录
重新同步缓存。容量或精确坐标超出支持范围时使用普通合成器。字形裁剪与属性物化
沿用 Emacs 实现；固定 display 空格分隔的片段可一次拼接，未证明的 shaping 边界
仍使用原有测宽拼接，包括阻止相同替换片段合并的零像素分隔符。
普通图层渲染也用同一内核计算变化行，工作存储归本次候选，求值结束即释放而不等待 GC，
不修改已发布的合成账本。
未变化的行继续按既有签名复用。

当 flow 子元素没有相对移动，且全部定位记录的 z 顺序都不低于 flow 时，直接把已完成
的普通流行作为合成底层，并从中读取 anchor 几何；浮层覆盖之外保持原有内容。相对
移动或穿插的 z 顺序仍使用逐 owner 合成。

预备几何把稳定的包含平面路径编译成保留栅格片段、数值位置槽、文档顺序及复用的
损伤行存储。移动只更新目标 primitive，再沿已准备的外层 wrapper 传播变化行。
冷路径编译固定 chrome、裁剪及继承绘制的有限属性变换；热路径只装饰损伤行，保留
其余已接纳行。
面板栅格与位置和层级分开；普通 candidate 在渲染文本不变时也复用已经分行、测宽
并解析所有权的栅格。

预备发布仍属于原有 surface 权威，复用两组 mount/index、回调绑定、报告和回滚资源。
冷路径把栅格片段的所有权编译为直接对象及祖先 token；损伤行刷新固定 mount 池的
可见区间，其余行只平移字符偏移。已测量的 owner/tag 组合初始预留自身已知栅格
区间数的两倍加一；稀疏边框不会沿用其他角色的范围，也不再按层数增加通用余量。
缺少栅格证据的角色仍采用保守的冷预留。耗尽的池在统一上限内倍增并保留全部既有
mount；只有容量增加后才重试填充。
发布从末尾写入已知损伤范围，只更新范围内的属性。
写入 buffer 前移除 token。Source 准备分别拥有私有声明单元和挂载节点的数值投影
单元；每次 stage 显式同步两者，snapshot 导出时冻结这些单元。后续普通发布读取最新声明，并重建已经
失效的 fragment 证明。外部 buffer hook 仍会运行，其意外写入会拒绝本次发布。

同一包含平面中的合格目标共享一个 prepared canvas：它的挂载场景、mount 池、发布
frame 与交互能力。准备该平面内的新目标只绑定它的标量源单元、值存储和回调，不会
重新合成已有目标。一个挂载面用 per-buffer 缓存同时保留多个平面的 canvas（最近使用
的在前）。成员集只复用为它自己包含平面编译的那份 canvas，因为别的 canvas 会把共享
祖先当作边界、随后无法回放自己的像素；需要别的平面的成员留给它们自己的 cohort。
有效性由缓存成员身份加上共享的 state、style 与 display 检查决定；最近使用的 canvas
服务交互发布与原生焦点。源 handle 的等价替换只在冷路径刷新这份能力。普通发布使操作绑定失效，但发布方拥有的拓扑 token
可以保留已编译资源：必须有明确的非结构脏分类，且 publication 对象没有创建、删除
或移动。再次准备只刷新栅格和绑定，不重新比较完整节点树。固定 wrapper 配置不变时
复用属性变换。准备阶段只记录 wrapper 可能遇到的属性模式（程序 primitive、内层
route、surface 属性与绘制装饰）；某个 primitive 属性组合在脏行首次出现时才编译，
模式之外的组合使该 prepared 操作拒绝。角色指令也覆盖初始被遮挡的栅格，使后来显露的像素继续使用 mount 池。
frame 接纳新 revision 与 client-state；下一次原子 prepared 发布前，普通 mount
仍保持权威。结构变化或不受支持的组合重新准备。

冷编译读取 state 的图层合成 ledger，而一次 prepared 发布会把 ledger 清掉。因此只有
anchor 到 root 之间的每个包含平面都仍有记录时才能编译新 canvas；一次 publication
只有一个 writer，同一代内不支持两个 canvas 交替写入。把 anchor 直接挂在 root 平面，
或挂在 ledger 有记录的平面上，并一次只发布一个区域。

普通更新保留拓扑但替换权威挂载记录时，准备发布 frame 先绑定当前已接纳的代。
区间池扩容只能替换仍然有效的 frame，且新池必须包含完整旧池。替换后的 frame 归
共享场景所有，所有预备目标在接受或回滚后都使用这份 frame。普通发布器留下的
权威挂载即使不属于编译池，仍是下一次发布的回滚基线。首次准备仍要求包含全部
权威挂载，失效拓扑或代际不能授权复用区间池。

当前路径编译固定平面的移动和层级。保留栅格内部的滚动视口随所属窗格移动，保留
内容相对偏移与 producer；包含平面路径上的活跃滚动仍因缺少偏移与裁剪的 wrapper
指令而拒绝。anchor 与 portal 保持各自的准入要求。
底层裁剪和原生文本写入仍会分配输出相关产物，编译后的 wrapper 指令及预备
publisher 本身不代表已经通过分配或延迟验收。

当已挂载根的最终合成保留全部可见 portal 且不存在 anchor 依赖时，root portal
场景允许范围更窄的纯 content cohort。冷路径保护每个 portal、其后代及逻辑祖先；
成员和最近的保留栅格 owner 都必须位于保护集合之外。独立内容传播损伤行时，根
程序继续保留 portal 记录及其遮挡和输入所有权。不支持的成员保留拒绝索引，框架
可移除这些成员后准备独立内容。该证明只在当前 binding capability 内缓存；普通
发布使证明和全部操作失效。公共几何准备仍不接纳或复用这种纯内容场景来改变位置。

混合 prepared-update cohort 在冷路径绑定固定成员的源单元及拥有其像素的保留
primitive；准备阶段不渲染。稀疏变化索引进入同一个保留 frame。成员先对选定的 routes
和 crop 完成准入证明，冷场景随后才绑定源单元并分配 interaction、mount 和发布
frame 存储。复用场景也执行同一成员证明；拒绝保留 member/property 诊断，不安装
半成品 session。同一 Host 的多个规格共享一份源记录；hook 前冻结调用方值，拒绝时
恢复所有源和调用方单元。暂存后，应用
重算变化样式成员及其后代的完整 cascade，并为每个被改写的节点保存快照，使回滚恢复
原投影。数值 unit 的声明与运行时存储相互独立；cascade 可替换节点值，因此 stage
显式同步两者，rollback 同时恢复源数值、先前节点投影和复用的运行时 unit。随后用
普通渲染器在 host 内容上下文中渲染每个变化成员最近的
记录所有者，增量与全量输出共用同一 box 实现。渲染签名与 viewport memo 表归共享
scene 所有，cohort 各自保留调用存储。任一 cohort 在渲染前及拒绝后，都使变化和
重算样式的节点及其祖先路径失效；直接 prepared geometry 接受时也失效其变化路径。
无关节点继续保留 memo，使用同一栅格的操作因而读取一致的当前源签名。flow 所有者只替换像素变化的行，且
必须保持原有行和像素区间；absolute 所有者不参与 flow，尺寸或行数变化时复用其记录槽，
追加记录并隐藏多余记录。固定稀疏批次对每条记录只保存一次原值，使绘制、Text、尺寸
与多个位置共享完整像素回滚。

窗格内部的滚动区域不再使整个固定场景退出预备更新。纯平移保留已接纳的滚动偏移、
内容及 producer；边界重绘和 resize 在独立候选表中计算滚动内容、视口与偏移钳制，
同像素一起提交，失败恢复旧表、全局索引和节点偏移。包含平面自身或其祖先滚动仍需
专门的视口映射证明。活跃 scroller 不使用仅合成像素的弹性尺寸重放；无滚动的尺寸
试验须隔离候选状态，并证明不会创建滚动状态。卸载及 buffer 关闭不复活旧滚动事实。

absolute 所有者的纯尺寸变化可以跳过这次渲染。`ebox-elastic` 从两次普通渲染学习
所有者的尺寸响应：宽度变化只改变每行一个固定像素空格，或居中子项两侧的两个等分
空格；高度变化在固定的前缀行与后缀行之间插入同一填充行的副本，并重新编号受影响
内容单元的行号。学到的模型在包含平面的极限尺寸以及节点声明的最小、最大尺寸处用
试渲染验证；每次回放前先检查保留行仍具有学到的形状——无属性文本、其他所有
`display` 值以及固定片段的像素宽度——因此字体、绘制与内容变化都会回退到普通渲染，
并由该渲染重新学习。回放产生与渲染器完全相同的行，包括居中标题的奇数像素，
`tests/ebox-prepared-resize-tests.el` 将每次结果与全新渲染比较。flow 所有者、
裁剪或非整数尺寸，以及尺寸与其他光栅值同时变化的情况仍使用普通渲染。

两次学习样本的实际行数必须分别等于声明高度。min/max 钳制或 content-box 装饰
打破这一对应关系时，保留普通渲染的结果，不创建会索引不存在行形状的尺寸模型。

class 变体使用原有 source token 语法，冷编译私有 selector view 与有限候选索引。
绑定通过 opaque source handle 查找规范查询条目，因此滚动投影复制 runtime node
不会改变其 source/subject 身份；复用同一规范条目也避免 class 候选重复。
ECSS 始终匹配当前 subject。任何观察变化 token 的 rule/scope 都拒绝，避免多个 Host
合批时触发未证明的关系规则。原生 focus/active 共用私有 source/subject 单元及固定
状态 journal；没有相关状态 selector 或动态样式求值器时，press/focus/release 经保留
frame 只发布元数据，不替换像素或 mount index。report bank 与 mount bank 分别推进，
保证穿插元数据发布不会覆盖下一次几何回滚所依赖的 live index。

预备源记录保留精确 opaque handle，通过不可变索引 overlay 选择新的私有记录；
操作有效性比较记录 identity。这保证旧树/索引及导出快照在 focus/active 元数据和后续
普通 candidate 处理中仍可解析。预备绘制只标记 computed style 陈旧；该标记阻止普通更新中的
metadata、native、scoped、viewport no-op 和 retained-scroll 快捷路径。下一私有
candidate 保留 binding key 并重算继承，仅其接纳状态清除标记。

## 保留式 scroll window

缓存滚动在可见窗口和 display context 的稳定性得到证明后，复用已发布的 cascade、
viewport axes 与未变化的 runtime index。Chrome-free root 直接拼接 rendered lines；
layered 或带 chrome 的 root 可以复用完整合成内容，只渲染 wrapper。纯 root offset
变化保留已经合成的 portal 和 anchor 内容；style、placement、content 或 display
context 变化必须使该证明失效。

通过证明的纯滚动变更从已发布状态与局部不可变 index delta 构造完整 candidate，
跳过通用声明式准备。Surface 提前生成带属性的替换文本及精确的新旧字符范围，
再通过带完整目标 mount specs 的认证 Ebox publication commit batch 发布，不构造 surface plan。
文本等长不能证明旧 mount 可复用：新进入视口的行可能具有不同 owner 与交互 tag。
Topology 与 Ebox publication object index 有效时，可复用私有 owner 解析缓存。属性更新与布局
重排仍使用各自的准备路径，只共享最终发布与回滚边界。

Nested owner 在 allocation 不变且通过证明时，可以只替换自己的 viewport，避免渲染
无关兄弟节点。若存在一个 offset 不变的 root scroll ancestor，还必须更新该祖先的
保留内容、ownership membership 和 line index，并将 producer 重新绑定到 candidate
树。缓存内容坐标与 mounted buffer 坐标分别验证。不支持的祖先链、部分可见的 owner，
以及 footprint 或 wrapper 证明失败的情况，保留普通 fallback。

普通 owner batch 可以组合 scroll box 外的 grouped owner 与保留滚动窗口内的 content
owner。先证明 scroll identity、窗口不变以及两代树中其他 scroll 依赖互不相交，再在缓存
坐标中使用原有 span／grouped proof。缓存中的规划可以收窄 mounted owner 分区，不能
扩大它。缓存 owner 重新生成自身属性，并重组已证明不变的祖先绘制；缓存不能提供属性
搬运所需的 mounted paint baseline。Owner proof 保留变更键，供 Flex allocation 校验。
隐藏内容将初步计划提升到 root 时，可将 dirty entry 重新分为已证明的 scroll 分区和
与 scroll 无关的 grouped row owner；外部分区仍无法证明时保留普通 root fallback。
Surface 按缓存分别验证并组合互不相交的替换，
重新生成变化的 rendered content lines 及其索引，然后在 mounted 坐标中统一验证全部
可见替换。完全隐藏的 owner 只修改已证明的缓存。缓存与 buffer 一起提交或回滚；
identity 缺失、owner 证据不完整或嵌套缓存链仍完整回退。完整布局渲染 slot-sized 副本后，
将 scroll metadata 和 lazy producer 绑定回该代 canonical runtime，供下一次更新严格
验证 identity。

必须在 staging 前区分 cache hit 与真实 prefix miss。Miss 使用复制的目标子树和祖先
路径、私有 index 与 registry、复制的缓存行，以及重新绑定的 producer；producer
不得在 Ebox publication commit 前修改已发布的 continuation。该隔离可能在 miss 时重建目标 prefix，
因此 cached-hit 耗时不能代表 miss 的代价。

预备的 viewport batch 在现有 scoped Ebox publication transaction 中只消费一次。后续 signal
触发的求值读取当前已提交 source，使用普通 projection。证明失败在发布前选择普通
路径；发布错误直接进入 rollback，不换另一个 renderer 重试。共享 evaluator 的
通用准备与 surface-plan 计数分别验证这两项工作已跳过；Ebox publication bookkeeping 与实际
buffer 写入另行测量。该路径并不保证耗时与总 object 数无关。

原生 frame 按所属 region 交付完整 scroll producer 集合，支持并列和嵌套容器。
保留求值树只收集最终布局使用，排除内在尺寸及 Flex/Grid 测量探测。各 producer
保留完整内容、可见高度和实际 offset，未变化的内容计划可以分别复用。Ebox 将
集合安装到普通滚动状态，通过候选路径复制修正 offset。从普通发布切回原生时
重新建立原生 source 基线。原生 producer 目前要求顶部对齐、无容器边框内外边距
及 surface template；其余几何在发布前使用 Elisp。

Scroll publication 仍经过 Ebox publication 与 Ebox participant。发布失败时，旧文本、属性、offset、
raw/rendered cache、source node、index、object、mount 和 report 均保持不变。
`make test` 覆盖独立嵌套容器、拒绝移除、内容缩短后的 offset 修正和卸载清理；
playground scroll evaluator 验证 fresh-render parity，并区分缓存滚动与实际 prefix 扩展。

## Identity 与坐标

公开 Host bounds 从发布挂载区间两端排除结构换行。分隔符仍归发布器记账，但不能
成为焦点或原生输入调用方使用的 Host 首位置。内部空隙仍包含在外包数值区间内，
消费者不需要重新推导挂载归属。

Key 只在同级兄弟集合内有效。声明式 source tree 不拥有 live Ebox publication object、marker 或 buffer 坐标。live 逻辑 `:id` 通过 `ebox-region-resolve` 解析为绑定某个 Ebox publication surface object 的不透明 handle；同一 source 挂载到两个 buffer 时会得到不同 handle。Region 与 host-ref 位置绑定于 generation；buffer 变更后调用者必须通过公共 accessor 重新获得位置。Buffer marker、display span 和 text property 是发布事实，不是 source tree identity。

显式区域更新批次用保留节点身份维护稀疏组合账本。每次更新只复制并修改目标 owner 子树；最终只复制受影响的祖先，并把嵌套替换叠到最新候选后代上。内容或尺寸更新通过局部范围证明时，准备阶段继续共享未变分支。其他输入在渲染前只隔离一次组合后的根树；证明不成立或发布失败时仍走普通安全回退与回滚。

原生输入边界只在 reader 调用期间保留当前 surface 与目标身份，接受结果和恢复
焦点时复用已提交的归属索引、可见性与焦点校验。它不增加目标注册表、编辑状态
或文本写入方。原生 Emacs 持有输入过程，消费者在边界返回后应用已接受的值。

主按钮拖动也由 Ebox 跟踪。生成的 keymap 在按下时确定声明节点，并在发布重排后
复用焦点的 source identity／key 解析保持目标。已发布 keymap 不再对应存活节点时，
这一次按压不算 Ebox 手势：跟踪把它和随后的释放留给 Emacs 的常规鼠标处理，
不报错。原生跟踪循环提供 start、变化的
移动位置和一次 end／cancel；不保存应用位置、不增加目标注册表或独立发布路径。
消费者在每次回调中使用普通公共更新操作。原生 reader 空闲时定期检查目标和窗口
是否存续，并在可能执行定时器的读取之后重新检查。每轮不等待地读取最多 64 个
原窗口中已待处理的移动，只发布最新位置；释放、按下、取消、无关事件或移出窗口
会停止合并，该边界事件仍排在后续输入之前。手势内的校验在已提交 surface revision
和 client-state 身份不变时复用已解析 owner，另行检查 buffer 可访问范围与原生可见性。
终结阶段只交付一次，包括仍需消费最后一次释放的
锁定手势；无关输入交回 Emacs 命令循环。

准备后的几何通路只编译已声明的交互依赖。当前焦点、按下 owner 和全部
hover-content 目标在准备时直接绑定 publication object，包括当前被遮挡的
hover 目标。每次发布从实际输出 mount 区间解析这些绑定，不重建导航、不遍历
Box 树。逻辑焦点随目标首个绘制位置移动，手动 point 保持独立；遮挡同时清除
focus／active 选择器事实与 buffer owner。四个冷准备的选择器变体共享几何提供方
拥有的私有数值单元，不修改已导出的 source record。只有清除交互状态不改变绘制
结果的变体才可直接执行，否则该次遮挡更新在发布前退出准备通路。Hover bounds
和回滚存储被保留复用，最终焦点位置在原生视图恢复后设置。

## 验证

每条更新路径都要验证：

- 发布后的可见文本和属性完全正确；
- 兄弟节点重排时 keyed identity 稳定；
- rollback 后没有候选数据残留；
- 可以局部更新时 patch 范围受控；
- native reflow 不可用时 fallback 正确。

更新行为的聚焦测试使用 `tests/ebox-commit-tests.el`、`tests/ebox-core-render-tests.el` 和 `tests/ebox-grid-tests.el`；`tests/ebox-package-tests.el` 守护 live-buffer 发布边界；然后运行 `make check`。


## 设计与模块边界

Ebox 是底层空间渲染引擎。它负责把声明式节点树转换为经过测量的布局 fragment 与通用 Ebox publication surface plan。它有意小于应用框架。

## 设计原则

- 一棵 source tree、一套样式归一化、一条布局流水线、一个 buffer owner。
- 公共节点是数据；只有显式入口负责渲染与变更。
- 稳定 identity 来自节点 identity 和显式 key，不来自可见文本或 selector 字符串。
- 布局变化先测量再发布；候选发布失败时保留上一个 buffer 状态。
- native 模块只是可选加速器，必须有完全等价的 Elisp fallback。
- 新抽象必须消除重复，或让已有的公共工作流更简单。
- 公共 property schema、ECSS metadata 与 used engine projection 都从同一 property definition record 派生。
- 跨包 framework integration 只发布 additive versioned provider；consumer selection 与 fallback policy 不属于 Ebox。

## 流水线

```text
节点树
  -> 归一化样式
  -> 经过测量的 formatting context
  -> 布局 fragment 与 snapshot
  -> render context
  -> 纯 Ebox publication surface plan
```

各层 owner 是：`ebox-child-range.el` 负责不可变 child sequence 与 key index，`ebox-tree.el` 负责 Ebox identity 与遍历，`ebox-style.el` 负责样式语义，`ebox-measure.el` 负责 display 敏感测量，`ebox-layout.el`、`ebox-flex.el`、`ebox-grid.el` 负责几何，`ebox-fragment.el` 负责 fragment 事实，`ebox-render-context.el` 负责 candidate/materialization 输入 port，`ebox-patch-plan.el` 负责纯 operation-antichain artifact，`ebox-surface.el` 负责纯 Ebox publication plan 投影与 retained 发布，`ebox-incremental.el` 负责 dirty 分类与 live fact 适配。`ebox-layout.el` 不再 load 或调用 surface/Ebox publication 层；门面把 surface operation 接入已校验的 render-context port。patch planner 不读取 buffer 或 surface；incremental adapter 只传入不可变 parent fact 与 tentative operation。`ebox-buffer-backend.el` 只构造和整形带文本属性的 render string；所有公共 live buffer 发布路径都经过 Ebox publication surface 边界。

## 公共边界

使用 `docs/manual.zh-CN.md` 中的函数与 property；公共 API 清单位于根目录 `ebox.el` 的 Commentary。应用和同级包只能调用清单内的接口。更高层的 Component、响应式、behavior、data 和 control 概念属于 ETAF。

ECSS 是必需的包依赖，即使作者没有写选择器或样式表也需要。EKP 是独立的可选
排版依赖：选择 `:wrap-mode kp` 时需要它的公开段落排版 API。EKP 不可用或不兼容时
会报错，不会擅自替换换行算法。它的加速器与 Ebox Rust reflow 模块相互独立。

`ebox-display-buffer` 先渲染，再把窗口放置交给原生 `display-buffer`。它接受调用方的
display action、返回 buffer，不选择独占窗口布局，也不选中结果窗口。一个 buffer
拥有一套挂载布局与视口；需要独立尺寸的视图应使用不同 buffer，不在同一段文本上
维护互相竞争的布局。

## 布局范围

Ebox 支持显式 `px`、`%`、`vw`、`vh`、`ch`、`lh` 尺寸、padding、margin、border、颜色、overflow、换行、row/column/flex formatting，以及固定、分数、隐式、gap、放置、span 和对齐等 Grid 能力。公共 typography 子集是 `:font-family`、以 CSS reference pixel 表示的 `:font-size`、`:font-weight` 和 `:font-style`；`:font-slant` 只是 `:font-style` 的精确 parse-time alias。任意 Emacs face 和文本属性 plist 属于最终 adapter，不是 Ebox 作者输入；显式原生能力 `:help-echo`、`:pointer`、`:hover-style`、`:hover-content`、`:keymap` 单独受支持。`:hover-content` 只在声明它的挂载 buffer 中启用本地鼠标移动跟踪，并通过保留的内容更新恢复，不创建 overlay 或拖拽循环。CSS 兼容性有意是部分实现：绝对定位和 z-index 属于 Ebox 的定位/图层子集；阴影、border radius、完整浏览器 typography 和浏览器级 bidi 不属于本包。

文本簇模型覆盖常见组合音标、变体选择符、Emoji 修饰符、ZWJ 序列和区域指示符配对。
它的范围小于完整 Unicode 字素分段；字符数量或这个有限的分段模型，都不能保证任意
字体塑造结果相同。

可选交互导航在当前渲染的 keymap owner 之间移动 point，读取已提交 surface，尊重
narrowing 与不可见性，不安装按键绑定、焦点注册表或应用状态。action 与状态仍属于
调用方。原生激活同样读取已提交 surface 与绘制祖先中的 keymap owner，显式 nil
阻止祖先激活。绘制链上没有任何声明时，keymap 归属回退到发布该位置快照的节点，
覆盖 Flex 间隙、padding 与裁剪尾格等排版填充格。不可访问、不可见和结构文本不能成为目标；归属校验后才执行命令，
回调错误保持可观察，不另建目标注册表。

逻辑焦点只有一个 buffer-local retained node owner。公共焦点变更拒绝加入活动中的
Ebox publication 事务，只有发布内部 participant 可以协调候选焦点并在拒绝时恢复。事务接受后的
回调可以发起新的焦点操作，只读查询仍可使用。发布后的 source interaction facts
提供 tab 顺序与禁用状态。Source index 随记录增量维护准确的 hover-content 声明数，
没有这类声明的 buffer 跳过 hover 注册扫描。Source record 分别保存作者状态与交互事实，subject 构造从
交互事实派生 `disabled`。查询、cascade 和增量失效读取同一派生视图；rebind 保留原始
作者状态，禁用变化会使 subject 失效。挂载焦点在候选 source record 中形成不可变
派生视图，作者不能声明此状态。焦点请求绑定发起时的已提交代，观察回调中的新提交
不会重放旧请求。候选阶段通过 ECSS 检查目标与祖先，最终渲染再校验绘制归属；裁剪
使已有焦点不可用时，复用同一 Ebox publication 对象清除状态并重算，之后才进行一次接受发布。
新请求的目标不可访问时原子拒绝。纯输入不保留挂载焦点。按下归属复用同一不可变
source 交互状态投影与发布 participant：生成的主按钮跟踪在回调前设置 `active`，
结束时清除；普通更新按存续 source identity 与可见性协调归属。选择器查询、ECSS
与绘制读取相同状态，消费者不保存镜像。激活接管释放事件，在清除状态后读取已接受的
原生绑定。悬停状态接入 cascade 仍待完成。
每次发布后延迟重建导航向量与 rank
索引，使用时检查可见性；每次导航不再扫描、排序全部 Host。稳定 runtime identity
加上非 nil 兄弟 key，连接 keyed DSL commit 中新生成的 source handle；仍存在的显式
source identity 优先于复用的绘制节点。Region 更新同时比较 source interaction facts
和原生投影，因此 tab 顺序或禁用节点的 keymap 更换不会被误判成 no-op。

Ebox 的可回滚 participant 随候选提升焦点，拒绝时恢复。Ebox publication 在 final accept 恢复原生
视图 marker，因此 Ebox 在受控 after-commit 回调中重新应用 point，且只作用于仍为
当前代的候选。手动 point 保留受可访问范围限制的数值位置。卸载清理焦点与派生索引；
该状态不管理应用值，也不选择窗口。

挂载 buffer mode 拥有共享导航与激活绑定。生成的原生键盘激活命令查询 point 上的
有效焦点，显式位置激活和鼠标回调则保持物理目标选择。有效 map 沿 source 归属与
祖先 nil 屏障解析。动态分派标记避免生成命令在 `ebox-activate` 选定已提交命令后
再次进入目标选择。自定义原生命令保持原生行为；重叠控件的正确激活不需要消费者
再实现焦点或输入模式。

横向 `:overflow hidden` 在内容组合后、自身 padding 和 border 添加前执行。它选取
测量后能容纳的完整受支持文本簇前缀，再用空白补齐剩余像素。固定 display space 可以
缩短，字形与图像不做局部位图裁剪；裁掉的子节点属性不会残留在中性填充上。
算法按 GPL-3.0-or-later 复用了
[s-pixel](https://github.com/Kinneyzhang/s-pixel/tree/a2a0d6ae6b3bd71c1a70084d0ea37f56463e5fe0)
的前缀加空白补齐思路，适配 Ebox 的文本簇与属性模型，不增加 `s` 或 `s-pixel` 依赖，
也不引入层叠或重叠组合。

## 尺寸组合

`ebox-size.el` 负责长度验证、依赖识别、浮点像素换算，并提供累计量化的纯函数，
供布局在选定的显示边界调用。上下文显式传入视口两轴、
该属性的百分比参照、`0` 字形前进宽度和行高；模块不读取窗口或节点，不求值任意
Lisp，不选择属性默认值，也不发布 buffer。Normal、Flex、Grid、间距和边框几何
由此复用同一套单位运算。

作者格式为 `(单位 数值)`，可组合函数是 `calc`、`min`、`max`、`clamp`。
property schema 负责允许的单位、关键词和值域。[统一单位约束表](manual.zh-CN.md#size-unit-constraints)
是作者契约：inline 几何、block 几何和边框绘制采用不同单位集合。验证递归遍历
所有函数分支和轨道参数；Flex basis 使用所在父布局主轴。无效单位组合在构造阶段
就报错，不延后到布局或显示。

布局负责提供包含块及字体测量，并解析固有/自动尺寸。`fit-content` 只接受裸关键词。
旧的裸长度、单元素像素列表、视口
关键词和 `contain` 不保留兼容执行路径。

参照尺寸缺失时延后解析，不当作零；中间运算保留小数，到格式化/显示边界才量化。
buffer 后端按完整行生成 block 几何，与收窄后的纵向单位契约一致。空 Box 的自动
内容高度为零；需要占位时由显式高度、padding 或 border 提供对应尺寸。

## 验证规则

每个行为修改都要补充聚焦的 ERT 测试，并运行新的 `make check`。修改 native 源码还要运行 `make test`；修改文档或 active 文件集合还要运行 `make test`。
