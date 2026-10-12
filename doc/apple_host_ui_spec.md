# Apple 宿主产品与 UI 对齐 Spec

- 版本：v0.6，2026-10-11；状态：P1核心与P2集合/详情已接入；已补部分CUA，四主题已接入，完整视觉验收及其余能力按计划推进。
- 基线：Godot 产品源码与当前 Apple 宿主；调查时 Apple HEAD 为 `e5108c1d`。
- 范围：macOS 13+；iOS 特有项单列，不阻塞 macOS。Minori、G1、更新器继续按既有优先级暂缓。
- 关联：[实施计划](apple_host_ui_plan.md) · [架构 spec](apple_host.md) · [进度](apple_host_progress.md)。

## 1. 调查结论与设计决策

原产品是“封面驱动的视觉小说库 + 视频库 + 游玩统计 + 可配置的运行宿主”，不是简单的文件列表播放器。原生化必须保留这四种职责。上一轮将游戏条目放进主导航侧栏、直接展示首个游戏详情，以及将设置缩成少量即时开关，改变了产品的信息结构和设置语义。

新设计采用以下契约：

1. 主导航仅表示「主页、视觉小说、视频库、设置」四个稳定目的地。个别游戏不进入主导航；视觉小说默认展示封面集合，选择条目后进入详情。
2. 游戏库、详情、游玩、设置的状态独立；返回恢复原搜索、滚动位置和选中项，不自动跳到第一个条目。
3. 设置恢复分组、解释文案、草稿和保存行为。普通玩家先看到界面、画面和兼容性，诊断与高级功能逐层展开。
4. 窗口内保留关键入口；桌面原生菜单与快捷键是同一 action 的补充入口，状态与窗口一致。
5. 使用原生按钮、选择器、弹窗、文本输入、焦点和窗口行为；保留产品封面、配色和内容层级。Apple HIG 不意味着删功能或把所有内容改成系统列表。
6. 不提供只有文案、没有实际效果的设置。未支持项在对应分组显示原因与当前有效值；能力检测不能等到首次启动游戏后才完成。

这是本项目的产品决策。HIG 提供交互依据，并不规定必须采用本 spec 的导航形式、配色或显式保存。

## 2. 调查范围与证据

按产品 → 宿主 → ABI → runtime → 测试 → 构建/分发的链路检查；不是逐行阅读所有第三方依赖或私有源码。

| 范围 | 已检查的主要证据 | 结论 |
|---|---|---|
| 产品结构/设置/统计 | [main.gd](../apps/godot_app/scripts/main.gd)：`_build_shell_chrome`、`_build_home_view`、`_rebuild_settings_view`、`_detail_tools`、`_dashboard_stats`、`_sorted_games` | 功能基线以实际 builder 和 handler 为准，不能只数翻译键 |
| 视觉与交互组件 | [tokens](../apps/godot_app/scripts/ui/aether_design_tokens.gd)、`aether_widgets/select/slider/disclosure/motion.gd` | Lumen 的页面、卡片、分组、层次与四套配色是有效参考 |
| 内容与启动配置 | `game_metadata.gd`、`game_launch_entry.gd`、`cover_index.gd`、`vndb_cover_resolver.gd`、`builtin_demo.gd` | 详情还有运行时、入口、编码、游玩时长；封面和内置 Demo 不止显示图片 |
| 游戏输入/诊断/媒体 | `game_virtual_controls.gd`、`diagnostic_session.gd`、`debug_console.gd`、`video_subtitles.gd`、原生菜单及更新脚本 | 简单虚拟按钮/日志文本不等价于完整控制模式/诊断配置 |
| Apple 实现 | `ShellView/Model/Strings.swift`、`GameLibrary.swift`、`EngineController.swift`、`MediaController/View.swift`、`GameControlsView.swift`、`DiagnosticStore.swift`、HostKit | 已有生命周期与媒体基础；产品层仍为 MVP |
| 引擎接缝 | [engine_options.h](../abi/include/engine_options.h)、`bridge/krkr2_runtime/src/krkr2_legacy_engine_api.cpp`、HostKit `EngineSession` | 多项缺失设置已有 ABI 选项，不应误记为底层全缺失 |
| 渲染实现 | `bridge/godot_extension/src/aether_runtime_player.cpp`、Apple `MetalFramePresenter`/`MetalBridge` | 增强 API 在 Godot 扩展中，不能仅透传一个 engine option 完成迁移 |
| 验收与分发 | Godot `tests/`、Apple `Tests/`、`README.zh-CN.md`、CMake、project.yml、doc、Web 构建入口 | 区分构建能力、平台适用性与用户可用功能 |

2026-10-11 CUA 打开既有 Godot Debug 导出，实际查看了视觉小说封面网格、设置分类索引、保存按钮、界面与渲染分组；未改动其设置。该导出可能落后于最新源码，功能范围仍以源码为准。当前导出的渲染页实际提示画面增强不可用，因此“原版有设置”不能等同于“每个构建均能使用”。

根目录 `DESIGN.md` 是 Claude 网页风格分析，非 AetherKiri 产品规范；不作为迁移设计依据。其他平台的构建与 runtime 模块用于能力与范围核对，不在本次重写范围。

Apple 官方参考：[Settings](https://developer.apple.com/design/human-interface-guidelines/settings)、[Collections](https://developer.apple.com/design/human-interface-guidelines/collections)、[Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)、[Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)、[Layout](https://developer.apple.com/design/human-interface-guidelines/layout)。使用 macOS 13 可用的 SwiftUI/AppKit 能力，不把新系统的 Liquid Glass 效果当作最低实现要求。

## 3. 功能差异清单

下表是P0调查时的差异基线，保留用于审查迁移范围；当前实现状态见第6节与实施计划。不能将“调查时缺失”误读为仍未实现，也不能因UI已有入口就视为完整验收。

状态：已有 = 已有基础功能，不代表完整验收；部分 = 数据/能力/交互不齐；缺失 = 未接入。P 编号对应实施计划。

### 3.1 设置

| 原 Godot 功能/真实语义 | Apple P0调查状态 | 目标/依赖 | 阶段 |
|---|---|---|---|
| 分类索引、行标题+解释、保存、脏状态离开提示 | 缺失；460pt sheet，直接持久化，只有“确定” | 主窗口设置页，分类索引，事务草稿，保存/不保存/继续编辑 | P1 |
| 语言：系统+五语言 | 已有；即时写入 | 保留全部选项，保存后生效，界面语言决定翻译目标 | P1 |
| 风格：dark/classic/warm_dark/warm_light，默认 classic | 缺失；跟随系统原生外观 | 恢复四个产品主题；原生控件色彩与主题协调 | P2 |
| iOS 界面比例 | 平台不适用 | M4；macOS 使用响应式布局，不造手机缩放开关 | M4 |
| 游戏内控制菜单入口开关 | P4e 已接入：入口按钮 + 可开关面板 | 区分入口可见性、当前控制模式和按键面板显隐 | P4 |
| Keyboard 模式按键透明度 | P4e 已接入（0.2–1.0，0.05 步进） | 模式实现后提供透明度；指针不受影响 | P4 |
| 渲染管线 | 部分；software/metal，未配置时默认 software | 显示「原生 Metal / 软件诊断」；不要用 Godot Native 名称冒充依赖；GPU Bridge 非必迁管线 | P3 |
| 画布 Game Native/Display Fit | 缺失设置；已有 setSurfaceSize 接缝 | 分离游戏逻辑画布、输出纹理和窗口 drawable；保持输入映射 | P3 |
| 缩放 smooth/nearest/linear/bicubic/lanczos | 缺失选择器与完整实现 | `smooth` 迁移为 `linear`；提供真实 nearest/linear/bicubic/lanczos 核，名称与 shader 一致 | P3 |
| 输出 original/1080p/2k/4k，默认1080p | 缺失设置 | 按原版目标尺寸/纵横比规范迁移；不是改变显示器分辨率 | P3 |
| 增强 off/preset/custom | P5b 已接入 Godot 的 kind 模型：关闭/预设/自定义；预设先开放可组合的「均衡清晰（FSR1）」= EASU+RCAS | Metal 后处理与能力报告；原始帧降级；其余 Godot 算法逐个移植前不开放 | P5 |
| 15 个增强预设，16 种自定义算法、顺序添加/移除 | 自定义链编辑器已接入（有序步骤、每步算法选择、添加/移除、上限 32）；预设仅列出可组合项 | 保留重建2×、目标尺寸缩放、同尺寸修复三种语义；不是统一 resize | P5 |
| FPS 开关+60/80/90/120/144，默认关闭、目标80 | 已接入 schema v5；DisplayLink 优先、Timer 兜底 | ABI fps_limit + 宿主调度；关闭限制也不承诺超显示器FPS | P3 |
| 游戏横屏锁定 | 平台不适用 | 移动端 M4 | M4 |
| 插件核心/完整（krkrsdl3/aether_all） | 缺失 UI/下发 | 已有 engine option，启动前应用并报告实际结果 | P1 |
| 本地 GGUF 翻译选择/清除、目标跟随界面语言 | 已有，能力不足时整段隐藏 | 纳入草稿；能力不足显示原因；加载状态与偏好分开 | P1 |
| Mock 绕过，默认 true | 缺失 UI/下发 | engine option；保存后下次启动生效 | P1 |
| 诊断 profile：off/baseline/input/render/storage/script/audio/video/plugin/system/full | P4b 已接入目录与可执行部分；storage/script/audio/video 本构建无采样源 | 迁移 profile catalog、采样与导出内容；Debug baseline，Release off | P4 |
| 调试覆盖层 off/summary/detail | P4b 已接入 | CPU/tick/GPU/呈现FPS分开命名；进程与GPU估算内存注明统计口径 | P4 |
| 错误弹窗追加最近20行日志 | 缺失 | UI 与引擎 error_dialog_logs 联动，默认关闭 | P1 |
| 插件追踪/trace日志/控制台文件/TJS导出 | P4d 已接入为临时会话工具（不写入偏好，追踪 30 秒自动关闭） | 临时会话工具；不作为普通持久偏好，追踪与trace 30秒自动关闭 | P4 |
| 场景测试：主页/设置/详情/视频库/视频播放器/游戏，运行状态变体 | 缺失 | 独立测试 fixture 与启动参数，退出可恢复；Debug工具 | P4 |
| QQ社群 | 部分；Help有入口、设置没有 | 设置中也可访问；默认不复制启动推广弹窗 | P1 |
| 关于版本、协议查看 | 缺失设置分区 | Bundle实际版本/构建、五语言协议资源、许可证入口 | P1 |
| 首次使用协议状态与分发相关额外声明 | P6 已接入 macOS 首次协议门（版本化 AcceptanceStore + 五语言协议正文 + 同意/拒绝）；渠道额外声明（App Store）留 M4 | 单独 AcceptanceStore，按分发渠道、版本管理，不能混入可撤销草稿 | P6 |
| IAP库数量解锁、coffee、恢复购买 | macOS无真实provider | macOS不启用数量限制；M4实现真实购买；不画可购买假按钮 | M4 |
| 检查更新、预发布开关、跳过版本 | 缺失 | 渠道策略后实施；用户要求留到最后 | P7 |
| 版本隐藏解锁 | 缺失 | 内部测试替代入口；不列为macOS核心交互或借此绕过正式权益 | P6/M4 |

增强预设源于 `main.gd` 的 `settings.frame_enhancement_mode.*`；算法源于同文件的算法描述与自定义编辑器。默认值以 `_load_shell_settings` 与变量声明为基线，迁移时用测试锁定，不能凭翻译文案推断。

### 3.2 产品页面与会话

| 区域 | Godot 基线 | Apple P0调查差异 | 目标/阶段 |
|---|---|---|---|
| 导航 | 稳定四页入口，窗口内可访问 | 主侧栏只有三页，游戏条目混入导航，设置仅gear sheet | 目的地侧栏四项，菜单同步；P1/P2 |
| 游戏库 | 封面卡片、数量、搜索、最近游玩排序再按标题、导入/引导 | 条目侧栏，自动进入首个详情，无搜索，无同等排序 | 封面网格为默认，可选列表；搜索标题/运行时/路径；P2 |
| 详情 | 封面编辑、运行时类型、路径、最近游玩、时长、启动入口、RFVP编码、重命名/移除 | P2 封面/路径/日期、P4a 游玩时长、P4f 运行时类型/启动入口（只读） | 编辑封面在封面区域可发现；管理菜单作补充；启动入口不提供覆盖（ABI 忽略 startup_script）；RFVP 编码待链接 provider 后提供 |
| 导入/刷新 | 探测元数据、目录/文件入口、封面/启动入口回填 | 目录/ZIP复制或外部引用已有；P4f 起按 Godot `GameMetadata` 标记识别 KiriKiri（xp3/startup）、ONScripter、Siglus、Minori 与校验过的 RFVP `.hcb` | 保留托管/引用差异；刷新主要重新读取索引和封面发现；未链接 runtime 仍可识别但不宣称可运行 |
| 内置Demo | 多语言Demo安装、版本与删除记忆 | P6 已接入：打包 `data.xp3`，首启安装到库、详情页显示「内置 Demo」并可「删除内置 Demo」，删除记忆使重启不再恢复 | 与 Godot 的 `BuiltinDemo` 对齐；升级路径（多版本）待后续 demo 版本 |
| 在线封面 | VNDB请求、候选标题、索引 | P6 已接入：详情页「搜索在线封面」显式触发，只发标题、候选缩略图选择、封面缓存到库根 `Covers/`、失败保留当前封面 | 与 Godot 的 VNDB 语义对齐；本实现不做后台自动扫描（隐私优先） |
| 主页 | 总时长、已玩、近周、最近5款、时长排行、活动/里程碑 | P4a 已迁移 `_dashboard_stats` 与主页内容 | 会话时长只统计成功启动的运行时间；周活动与七天足迹按lastPlayed推导，非完整历史日记 |
| 调试控制台 | 概览、事件、日志暂停/过滤、输入、插件、问题标记及临时工具 | 只有日志文本和导出 | 可停靠诊断面板，复用数据而非把原面板截成图片；P4 |
| 游戏控制 | 多模式虚拟控制、菜单/调试/输入、平台适配 | 固定按钮条，文本/全屏/日志/重启已有 | 优先桌面输入与可见操作；模式及焦点状态独立；P4 |
| 视频库 | 搜索、视频卡片、位置/总时长/进度、导入引导、移除确认 | 基础索引和位置；无同等搜索/时长/移除确认 | 网格/列表、真实进度、移除前确认并清理对应记忆；P2 |
| 视频播放器 | seek、倍速/字幕/音量、播放进度、控件自动收起及手势 | 基础控件+字幕选择持久化已有，控件固定占位 | 桌面悬停显示/自动收起、全屏入口、键盘、无障碍；P4 |
| 窗口/菜单 | 状态禁用、全屏、快捷键、五语言 | 基础覆盖已接入 | 共享action和禁用原因；退出游戏/视频恢复窗口与导航状态；P1/P4 |

## 4. 目标布局与行为

### 4.1 主窗口

```text
原生标题栏 + 当前页工具栏（导入、刷新、搜索等）
目的地侧栏             内容
  主页                 游玩统计 / 最近游玩 / 继续游玩
  视觉小说             封面网格 → 游戏详情 → 游戏运行
  视频库               视频集合 → 视频播放器
  设置                 分类索引 + 分组设置内容 + 保存状态
```

侧栏宽度目标200–240pt，可折叠；隐藏后工具栏提供导航入口。页面内容上限参考原版1120–1240pt；不能让所有页面永远只有600pt左对齐的狭窄内容。窄窗口使用自适应列数与纵向详情。960×640、1280×800及大窗口均有验收，文字增长不可挤掉主要动作。

导入可接受范围由当前构建已链接provider与probe结果决定。不能仅从目录名猜runtime或宣传所有README运行时已在Apple可用；Minori保留已有路径但不做本轮适配。

游戏库点击打开详情，不自动启动。详情有返回、封面编辑、主要游玩动作、可读元数据；破坏性操作与开始游玩分开。移除条目与删除磁盘文件必须分清，现有只移除索引行为保持。搜索无结果与空库使用不同提示。刷新保留排序、滚动和手动封面抑制状态。

### 4.2 设置

设置为主窗口目的地，分类沿用原产品：界面、渲染、兼容性、诊断、高级开发工具、关于；社群置于关于内的明确区域。购买仅在真实渠道能力可用时出现，移动端选项仅在移动端出现。该分类重组应在实现的功能清单中记录。

每行包含标题、说明、控件及必要的生效状态。长解释允许换行，危险/高负载操作不能只用颜色表达。渲染预设首先给普通玩家合理默认，算法链是渐进披露的专家选项。

`SettingsStore` 保存有效配置；进入页面复制为 `SettingsDraft`，修改不触碰当前引擎与持久配置。保存先校验全部配置，再写盘并发布；失败保留草稿，不能显示成功。无修改时保存禁用。切分类保留草稿；离开设置/关闭主窗口有「保存并离开 / 不保存 / 继续编辑」。不保存丢弃草稿，继续编辑维持页面。保存后新建干净草稿，语言和主题改变保持分类与滚动位置。

现有 shell UserDefaults 首次迁移进版本化存储；保留用户已选software/metal与翻译路径。全新安装以原生Metal为产品默认，初始化失败可回退软件并显示原因；P1已将新安装默认改为Metal；P3a已接入初始化失败可观测回退，行为验收通过，页面CUA待补。不要静默覆盖既有选择。Godot配置导入是显式功能，不自动覆盖不同产品储存目录；库schema兼容与设置迁移分别处理。

| 配置类别 | 目标生效时机 |
|---|---|
| 语言/主题/控制入口/透明度 | 保存后界面生效；游戏当前控制显隐属于会话状态 |
| renderer/插件加载/Mock/翻译模型 | 保存后下次游戏启动或明确重启；展示当前会话与下次启动差异 |
| 画布/输出/缩放/增强/FPS | 在无活动会话时设置，下次启动应用；后续即时切换必须先验证资源生命周期/输入映射，再开放 |
| 诊断profile/覆盖层/错误详情 | 保存后配置生效；需要初始化的采集器标明下次启动 |
| 高级追踪/导出工具 | 明确即时会话动作；不加入草稿、不持久恢复，显示倒计时/输出位置 |
| 协议接受/购买权益/更新忽略 | 各自状态仓库；不随设置撤销 |

macOS普通游戏运行时禁用全局设置导航，与Godot菜单一致；保留游戏内日志、输入、全屏等会话操作。不能只禁用菜单而让侧栏另开设置。视频运行时也暂禁设置，以免音量/字幕等播放器状态与全局草稿混淆。

### 4.3 能力与渲染契约

UI从 `HostCapabilities` 读取能力与不可用原因，不能根据是否有当前engine对象猜测。provider拒绝选项需区分“不支持”与实际失败，报告有效值，不把整个游戏终止作为常规设置处理方式。

Apple原生Metal、GPU Bridge和Godot RenderingDevice并非三个可直接搬来的等价按钮。Apple保留原生Metal与软件诊断两条真实路径；环境benchmark参数是测试入口，不是产品设置。

增强保持单次输出缩放，处理顺序：原始帧 → 自定义/预设处理 → 输出目标 → drawable等比呈现；保持直通FrameLease所有权和原有批处理。输入按逻辑游戏画布映射。增强失败回原始画面，不得黑屏、双重缩放或帧帧CPU回读。

P3d 已明确模拟时间、引擎render限频和MTKView呈现的关系：关闭限制时用 CVDisplayLink 跟随显示刷新（无活动显示或显式要求时退回 RunLoop Timer），启用限制时由宿主调度器按目标节奏放行 tick；两种模式都把真实 elapsed 时间交给引擎，不提高Timer频率同时仍推进固定1/60，因此刷新率不会加速剧情。失焦、隐藏、最小化、遮挡和系统休眠只重置调度时钟并记录状态，不产生追赶 tick；tick/render/presentation 三个计数分开记录，且都不等同于屏幕扫描FPS。

### 4.4 视觉与可访问性

Lumen四套主题保留内容层、强调色、圆角与封面比例；系统字体负责可读正文，展示标题可参考已有字体资源。原生菜单、文件选择器和窗口控件遵循系统行为；不复制大面积光效或强制动画来证明对齐。动画响应Reduce Motion，主题须验文字/控件对比度。

所有图标动作有可见标签或可发现的文本说明及VoiceOver名称。核心入口不依赖hover；键盘支持焦点移动、Enter打开详情、Escape返回/关闭非破坏性弹窗、Cmd-F搜索。实际快捷键和禁用状态使用共享action，不在不同View重复定义。

## 5. 完成标准

每个功能需同时有：窗口内入口、数据持久化/有效值、实际执行、生效时机、失败处理、五语言与必要的自动化/CUA证据。不能以“已有翻译键/已有按钮/编译通过”勾选迁移完成。

每阶段按[计划](apple_host_ui_plan.md)验收并更新进度。P1已接入设置事务、四目的地、分组页面、兼容性选项与关于资源；表中“当前差异”保留P0调查基线，实施状态以计划记录为准。全量功能对齐仍未完成；本 spec 不将当前MVP标成成品，也不改变性能证据的适用范围。


## 6. 实施状态（2026-10-11）

| 模块 | 已实施 | 剩余验收/能力 |
|---|---|---|
| 设置事务与导航（P1） | 四目的地；分组、JSON草稿/保存、脏状态离开/关闭/退出保护；插件/Mock/错误日志真实下发；协议/许可/版本 | CUA已点验继续编辑、丢弃、保存英文、取消关闭/退出；五语言全分组、文件选择取消、完成关闭/退出与重启待补 |
| 内容集合与详情（P2） | 目的地侧栏；默认封面网格与紧凑列表；游戏/视频名称和路径搜索；最近时间与标题排序；详情封面编辑与可见常用动作；返回保留搜索和条目滚动锚点 | 运行时搜索待P4元数据；滚动恢复是条目锚点而非逐像素；四主题已接入并点验；VoiceOver完整朗读与全部窗口/语言组合仍待验收 |
| 视频集合（P2） | 缓存真实位置/总时长；旧无时长条目只显示位置；移除确认同时清理进度与字幕选择，保留视频文件 | 进度数据来自实际播放器，不在导入时伪造时长；封面仍为影片占位符；播放器完整交互在P4 |
| 渲染与增强（P3/P5） | 启动前设备/呈现器与翻译provider能力；Metal初始化失败安全重建软件会话；报告请求/实际引擎/呈现路径和原因；新安装默认Metal | P3a–P3d行为回归通过；P3b/P3c/P3d设置页CUA已验证；增强仍未开放 |
| 统计/运行配置/诊断（P4） | 会话时长与完整主页（P4a）、诊断 profile 与性能覆盖层（P4b）已接入 | 启动入口/编码、调试控制台/临时工具（30 秒自动关闭）、控制模式与播放器交互待后续P4切片 |
| 发布功能（P6/P7/M4） | 关于资源已打包；macOS 首次使用协议门已接入；内置 Demo 已接入；VNDB 在线封面已接入（显式触发、只发标题、缓存到库根） | 渠道额外声明仍单列 P6；更新器最后；真实IAP与移动端M4 |

主题设置使用schema v2；渲染设置使用schema v4，读取v1/v2/v3时补齐画布、输出与采样字段并将旧配置迁移为原始输出/线性采样，加载本身不改写原文件，下一次成功保存写入当前schema。未知主题回退classic，未知schema或损坏文件仍禁止保存以保留证据。只按有效设置应用外观与启动配置，草稿不预览，也不重建页面identity。

Godot内容palette按源tokens保留。AppKit原生突出按钮使用白色标签，专用controlAccent按同一强调色降低亮度至白字对比≥5:1，不使用Godot深色主题的黑字按钮假设；原生侧栏选中、标题栏、菜单、焦点与文件面板仍由macOS绘制。Increase Contrast使用主文字替代次要文字并增强分组边框；本实现不增加页面或主题切换动画。四主题库/设置与深色重启恢复已CUA点验，随后native pipe断开，五语言全分类等剩余验收仍保留。

视频移除跨三个原子写入文件，不宣称多文件事务：清理失败保留条目；索引保存失败恢复内存列表并报错，已清理的记忆可能需要重新建立，重试清理是幂等操作。清理不触碰视频原文件。


## 7. 复核后的设置契约与差异追踪

本节按 Godot `_rebuild_settings_view` 的真实控件、`_current_settings_snapshot` 的草稿字段和 `_apply_settings_snapshot` 的处理链复核，不能把翻译字符串当功能实现。当前交付基线为 `aba88a61`；P3a/P3b 已有实现以各自实施记录和自动/CUA证据为准。调查覆盖项目的产品页、配置、引擎选项、HostKit、渲染、媒体、测试和打包入口；不声称逐行审计全部依赖。

### 7.1 字段映射

| Godot 草稿字段 | Apple 已提交字段/状态 | 尚需实现的行为 |
|---|---|---|
| `language` | `languageMode` | 五语言所有分类的完整布局验收 |
| `style` | `theme` | 四主题已实现，完整无障碍/尺寸验收待补 |
| `game_virtual_menu_enabled` | `virtualControls` 只控制固定按键条 | 分离控制菜单入口、输入模式和面板显隐，不把三者共用一个 bool |
| `game_virtual_keyboard_opacity` | 无 | Keyboard 模式透明度；隐藏/切换/失焦释放按键 |
| `backend` | `renderer`，Metal/软件 | 原生路径与原版后端有意不同；报告请求值、实际引擎路径与呈现路径 |
| `surface_mode` | `canvasMode` | Game Native/Display Fit、输入坐标与截图一致；逻辑画布保持原始尺寸 |
| `upscale_algorithm` | `upscaleAlgorithm` | smooth→linear 迁移；nearest/linear/bicubic/lanczos 使用对应 CPU/GPU 核并做确定性图像对照 |
| `output_resolution` | `outputResolution` | original/1080p/2k/4k 的目标尺寸、纵横比和资源预算；按比例缩放，不改变显示器分辨率 |
| `frame_enhancement_enabled` / `frame_enhancement_kind` | 无 | 以 off/preset/custom 为单一有效模式，enabled 仅作旧配置迁移输入 |
| `frame_enhancement_mode` / `frame_enhancement_custom_chain` | 无 | 15预设、16算法、顺序和不同 pass 尺寸语义；P5独立实现 |
| `fps_limit_enabled` / `target_fps` | `fpsLimitEnabled` / `targetFPS` → engine option `fps_limit` | 已接入：关闭下发0并跟随显示刷新，启用下发目标值并由宿主调度；真实elapsed dt、失焦重置、tick/render/presentation分开统计 |
| `plugin_load_mode` | `pluginLoadMode` → engine option | 已接入；完整/核心模式的实际可用插件随构建报告 |
| `mock_enabled` | `mockEnabled` → engine option | 已接入；启动前生效，默认true |
| `error_dialog_logs` | `errorDialogLogs` → engine option | 已接入；真实错误弹窗的最近日志显示需场景验收 |
| `text_translation_model_path` | `translationModelPath` | 草稿已接入；provider能力、模型加载失败与路径错误分别反馈 |
| `diagnostic_profile` | `diagnosticProfile` → engine options + 宿主采样 | 已接入：input/plugin/full 下发 `input_trace`/`plugin_trace`/`trace_log`；baseline/render 采宿主帧工作；system/full 记录系统快照；storage/script/audio/video 本构建无采样源并在 UI 说明 |
| `debug_overlay_mode` | `debugOverlayMode` → 游戏画面覆盖层 | 已接入 off/summary/detail；tick/render/presentation 分开命名，内存标注进程/系统/引擎缓存口径，并明确本构建没有 GPU 估算 |
| `ios_ui_scale_mode` / `force_landscape` | macOS不适用 | M4移动端处理，不塞进macOS设置 |

高级追踪、trace、文件日志、TJS导出和场景测试不在普通草稿字段中：原版通过即时handler执行，Apple也应作为会话动作实现。更新预发布/忽略版本、协议接受与购买权益另有持久状态，不能被普通“丢弃设置”撤销。

### 7.2 保留原版语义与明确差异

| 事项 | 契约及原因 |
|---|---|
| 设置保存 | 保留原版草稿和显式保存；Apple先校验/写盘成功再发布，不能照搬原版先应用内存再保存的顺序 |
| 分类 | 原版社群独立区移到“关于”；原版兼容性/诊断/高级分组保留职责。不能仅因分类减少就删掉功能 |
| 设置容器 | 主窗口目的地是本产品选择；HIG通常描述macOS独立设置窗口，不宣称HIG要求把设置放进侧栏。Cmd-,与窗口内入口调用同一路由 |
| 渲染后端 | 保留本项目Metal直通；不为视觉相似引入Godot依赖或恢复正常帧CPU回读 |
| 生效时机 | 当前运行中禁全局设置；渲染/插件/翻译等下次启动应用，这是明确差异。未来即时切换须单独验证生命周期，不沿用原版“保存立即增强”文案 |
| 能力不足 | 保留已保存偏好并说明不可用原因；不画可用假控件，也不把整组隐藏，让用户知道尚缺哪些能力 |
| macOS权益/更新 | 不启用库数量限制或假购买；真实IAP放M4，更新器P7最后 |

### 7.3 Apple规范如何落实到本产品

Apple [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars) 提倡让常用操作在工具栏可访问，并保留对应菜单命令；不要求把所有菜单项都复制成按钮。[Settings](https://developer.apple.com/design/human-interface-guidelines/settings) 强调设置应易于找到、按关联组织并控制复杂度。本产品据此采用以下窗口内入口策略，具体四目的地和保存事务是产品决策。

| 当前上下文 | 始终可发现的窗口内入口 | 次级入口与状态 |
|---|---|---|
| 游戏/视频集合 | 搜索、导入、刷新、网格/列表 | 导入附近区分复制与外部引用；空库给导入引导，无结果给清除搜索 |
| 游戏详情 | 返回、开始游玩、封面选择/清除 | 重命名/移除在管理区域；移除明确仅移除索引，不与启动混排 |
| 游戏运行 | 返回库、全屏、输入/控制入口 | 日志、重启、导出诊断在有标签的会话菜单；重启确认；退出恢复窗口 |
| 视频运行 | 返回库、播放/暂停、进度、全屏 | 字幕/音量/倍速可发现；自动隐藏不得移走当前键盘或VoiceOver焦点 |
| 设置 | 分类、标题/说明/控件、保存与状态 | 专家选项渐进展开；保存失败保留草稿；次启动生效与当前有效值明确区分 |

全局菜单、工具栏和页内按钮必须使用一致动作与启用条件。常用操作不依赖hover或顶栏；高风险操作不用颜色作为唯一提示。内容保留Lumen四主题，标题栏、系统文件面板、菜单与焦点行为使用原生控件，不为模仿原版复制装饰动画。

### 7.4 复核证据与验收边界

- 设置源：`apps/godot_app/scripts/main.gd` 的 `_rebuild_settings_view`、`_current_settings_snapshot`、`_apply_settings_snapshot`、`_save_settings_draft`；Apple `SettingsStore.swift`、`ShellSettingsView.swift`、`ShellModel.swift`。
- 运行配置源：`game_metadata.gd`、`game_launch_entry.gd`；目录runtime必须传根目录，EXE/XP3选择不能覆盖provider根语义；刷新保留显式空自动探测与用户入口选择。
- 诊断/控制源：`diagnostic_session.gd`、`debug_console.gd`、`game_virtual_controls.gd`；媒体/发布源：`video_subtitles.gd`、`builtin_demo.gd`、`vndb_cover_resolver.gd`及打包配置。
- 底层源：`abi/include/engine_options.h`、HostKit `EngineSession.mm`、`EngineController.swift`、`MetalFramePresenter.swift`。已有选项与缺失后处理分别排期。
- 本轮尝试CUA连接明确构建路径，返回 `native pipe closed before response`。本次没有完成新的视觉或点击验收；沿用已记录证据，不将文档复核或已有构建成功当作CUA通过。


### 7.5 P3a实施结果

`HostCapabilities`在启动前检查设备/宿主呈现器并查询真实翻译provider；runtime对Metal选项的接受在初始化时验证。偏好保留Metal，设备/呈现器不可用、原生不支持或初始化失败时有效引擎改为software。部分原生激活失败会先关闭未打开游戏的会话，再创建干净软件会话；不在游戏运行中重建引擎。

游戏页在回退时显示请求管线、实际引擎、显示方式与原因；设置渲染页显示最近会话。运行中的Metal显示失败退为图像呈现，引擎仍可为Metal，不宣称切换为软件引擎。新会话重新尝试用户选择，清除上次回退状态。诊断保留`rendererRequested`/`renderer`/`presentation`/`renderFallback`，包括先初始化后打开游戏的开发入口。

`AETHER_HOST_DEBUG_TRANSLATION`仅用于Debug设置预览，明确说明未链接provider；不改变真实翻译能力或给引擎发送虚假支持选项。P3b已实现画布/输出，P3c已实现采样，P3d已实现FPS与调度；增强和diagnostic profile仍有明确未迁移说明，不开放无实现控件。

行为测试使用实际引擎和隔离KAG3副本，注入无设备、呈现器失败、不支持及实际取得原生generation后失败的边界；验证软件/原生成功启动、显示降级后的tick/画面连续、FrameLease清理、重复回调幂等、重试和报告导出。注入故障验证处理路径，不等于发生真实设备丢失。另用实际应用完成30秒Metal直通输入/截图/退出回归；本轮CUA再次返回native pipe关闭，页面可见性与点击仍待验收。

### 7.6 P3b实施结果

`HostSettings` schema v3 持久化画布模式和输出档位，旧配置读取时保持原始输出语义，新安装默认为 1080p。输出目标由逻辑游戏画布、选择的档位和显示像素共同计算，始终保持原始宽高比并限制在 4K 上限；它只改变宿主呈现尺寸，不改变引擎模拟尺寸或显示器分辨率。Metal 使用 GPU 内部缩放并按 frame revision 管理中间纹理生命周期，软件路径提供等价缩放和失败回退。

指针与 IME 插入符都通过同一输出几何映射回逻辑画布；诊断报告同时记录逻辑画布和输出尺寸。行为测试覆盖非对称图像、Display Fit/Retina 像素、4K 上限、软件/Metal 路径、输入与 IME round-trip、缓存输出及 lease 清理。实际 KAG3 30 秒 direct smoke 产生 640×480 源帧和 1440×1080 输出帧，Metal RGB max diff=0 且 446 个 lease 全部提交/完成。真实构建窗口 CUA 已验证渲染页控件可见、选项可切换并保存成功。

### 7.7 P3c实施结果

Godot 的 `smooth` 仅是线性采样的旧名称，默认值为 bicubic。Apple 现在将有效采样算法作为 schema v4 偏好，加载旧配置时把缺失字段迁移为 linear，保存时把 smooth 规范化为 linear。Metal shader 与软件 fallback 共享 nearest、linear、Catmull-Rom bicubic 4×4、Lanczos 半径 3 的核定义；Metal 输出 pass 只在目标尺寸或帧版本变化时重建中间纹理，最终呈现不会重复执行输出采样。

行为测试逐算法比较 CPU 与 GPU 输出，覆盖迁移和不同核确实产生不同结果；KAG3 direct 30 秒 smoke 分别以四种算法运行，均保持 RGB max diff=0、`lease_failures=0`、`leases_live=0`。设置页 CUA 已验证四个选项、双三次切换和保存状态。

### 7.8 P3d实施结果

`HostSettings` schema v5 新增 `fpsLimitEnabled=false` 与 `targetFPS=80`，v1–v4 旧文件缺字段时迁移为默认值，目标值只接受 60/80/90/120/144。启动前把 `fps_limit` 作为 engine option 下发：关闭时为 `0`（跟随显示刷新），启用时为所选目标值；环境覆盖 `AETHER_HOST_FPS_LIMIT` 只用于 smoke/benchmark，不写入用户偏好。设置页在渲染分类提供开关和目标选择，启用时显示五个目标值，关闭时显示“跟随显示刷新（当前）”，文案说明真实经过时间与下次启动生效。

宿主调度改为独立于引擎的帧时钟：优先 CVDisplayLink 跟随显示刷新，无活动显示或显式 `AETHER_HOST_PACE=timer` 时退回 RunLoop Timer；启用限制时由纯 `FrameScheduler` 按目标间隔放行 tick，每次回调最多一次 tick，超出部分记为 `dropped_catch_up` 而不是追赶。每次 tick 传入真实 elapsed（毫秒，含亚毫秒余量），单次上限 100 ms；失焦、隐藏、最小化、遮挡和系统休眠通过 AppKit/NSWorkspace 通知重置调度时钟并记录状态，退出时停止帧时钟并解绑观察者，因此不会出现追赶爆发。CVDisplayLink 回调在主线程前做合并，主线程繁忙时不会回放积压。

统计口径在日志和诊断中分开：`tick` 是宿主 `engine_tick` 调用次数，`render` 是引擎 `engine_get_frame_rendered_flag` 报告实际出帧的 tick 次数，`presentation` 是 Metal drawable 提交或图像发布次数；`frameStatNote` 明确三者都不等同于屏幕扫描FPS。调度单元测试以 60/120 Hz 合成脉冲验证目标 80 不被超过、累计模拟毫秒在不同脉冲率下相同、迟到回调丢弃追赶和 100 ms 上限。

### 7.9 P4a实施结果：会话时长与主页统计

`LibraryGame` 新增 `playDurationSeconds`（旧索引缺字段读取为 0，负值归一为 0），`GameLibrary.addPlayDuration` 原子累加并沿用 Godot `_add_play_duration` 的上限语义：非正贡献忽略、单次会话最多加一天。`EngineController` 只在引擎报告 `startup state: SUCCEEDED` 后开始用单调时钟计session，`consumePlaySeconds()` 终结当前会话并返回自上次提交以来的秒数；返回游戏库、重启与应用退出（`applicationWillTerminate`）各提交一次，因此失败启动或启动中的会话不计时，重复返回或重启不会重复计数。主页统计由 `PlayStats` 从索引推导：总时长、已游玩（有时长或最近游玩）、近七天活跃、平均时长（Godot 同样截断到整分钟）、时长排行（>=60s，取前 5）、最近游玩（取前 5）、七天足迹与活跃天数、里程碑（Godot `DASH_MILESTONES`）与口号/问候语（按本地小时）。

主页按 Godot 内容结构重建：三层进度环与中心累计时长、问候与统计副标题、三条图例（时长里程碑/书库探索/活跃天数）、打开库入口、四张统计卡、近七天足迹（每天标题或“这天没有游玩”与汇总）、继续阅读卡、时长排行与最近游玩。平台差异：图标使用 SF Symbols，最近游玩显示系统日期样式而不是“N 天前”，既不复制 Godot 的极光/模糊背板与进入动画，也不引入新的动效；新增 `accent2`/`accent3`/`success` 三个 Godot Lumen token 供进度环使用并纳入配色交叉检查。详情页在有累计时长时显示“游玩时长”一行。运行时类型、启动入口与 RFVP 编码仍属 P4 后续切片。

### 7.10 P4b实施结果：诊断 profile 与性能覆盖层

`HostSettings` schema v6 新增 `diagnosticProfile`（off/baseline/input/render/storage/script/audio/video/plugin/system/full，Debug 默认 baseline、Release 默认 off，与 Godot 一致）与 `debugOverlayMode`（off/summary/detail），v1–v5 旧文件迁移为默认值。profile 的映射只使用 Apple 真实存在的来源：input/plugin/full 启动前下发 `input_trace`/`plugin_trace`/`trace_log`；baseline/render 采集宿主帧工作；input/full 记录宿主输入事件；system/full 在诊断导出写入 backend/内存快照；storage/script/audio/video 在本构建没有采样源，因此不出现在选择器中，设置页与日志都说明原因。覆盖层模式保存后立即作用于运行中的会话，trace 类选项仍是下次启动生效。

性能覆盖层在游戏画面上以等宽英文技术输出显示（与 Godot 覆盖层一致）：后端/API/纹理来源/逻辑与输出尺寸、`tick`/`render`/`presentation` 三个分开的速率和口径说明、帧工作耗时与调度模式、fallback/错误数、进程内存（App/Peak）与系统空闲或进程余量、引擎 graphic/XP3/PSB 缓存；detail 追加帧工作 p50/p95/max、调度 dropped/coalesced/resets、会话计数与缓存明细。GPU 估算在本构建没有来源，覆盖层明确写“not available”而不是猜测。快照由 tick 循环节流刷新（每 30 tick），视图不持有定时器，因此每 tick 的发布不会打断订阅。诊断导出附带 `diagnosticProfile`/`debugOverlayMode` 与 backend/内存/速率上下文。

### 7.11 P4d实施结果：临时高级工具

设置「高级开发工具」不再显示“尚未迁移”占位，而是 Godot `_set_advanced_tool` 对应的四个真实引擎选项：插件调用追踪（`plugin_trace`）、追踪日志（`trace_log`）、控制台日志文件（`console_log_file`）、导出 TJS 脚本（`export_scripts`）。这些开关是**会话级**的：不进入 `HostSettings`、不产生草稿脏状态、重启自动关闭；`plugin_trace` 与 `trace_log` 开启后 30 秒（Godot `ADVANCED_TRACE_TIMEOUT_MS`）由 tick 循环自动关闭，控制台文件与脚本导出没有时限。开关在有会话时立即下发，否则在下次 `initializeEngine` 时应用，已过期的工具会被丢弃并记录 `expired before launch`。诊断导出附带 Godot `_advanced_snapshot` 形状的选项状态与追踪剩余秒数。场景测试入口（重启并跳转到指定界面）仍未迁移，页面保留明确说明。

### 7.12 P4e实施结果：游戏内虚拟控制

`HostSettings` schema v7 新增 `virtualControlMode`（`mouse`/`touch`，默认 mouse，与 Godot 相同）、`virtualControlMenuEnabled`（默认 true）与 `virtualControlKeyboardOpacity`（0.2–1.0，0.05 步进，Godot `snapf` 语义）；v1–v6 旧文件迁移为默认值，损坏值在加载时归一、保存时拒绝。游戏画面上按 Godot `_sync_visibility()` 呈现：只有 `virtualControls && virtualControlMenuEnabled` 才显示右上角入口按钮，按键面板默认关闭、由入口按钮开合；关闭入口等于隐藏整条虚拟控制（Godot 同义）。键盘按键与保持 Ctrl 使用配置透明度，鼠标模式的指针手柄保持完全不透明（Godot “指针保持清晰”）；键盘模式按键透明度文案与说明沿用 Godot 五语言资源。

控制模式在面板内切换（Godot 的 `input_mode_button`）：mouse 模式显示虚拟指针手柄与左键按钮，手柄拖动按显示缩放换算成逻辑画布像素并累加为绝对坐标（`VirtualPointer`，边界收敛到画布内），左键按钮在该坐标发送 down/up；touch 模式隐藏手柄与左键按钮，直接使用真实指针。面板内切换会立即写入偏好（Godot 同样持久化 `virtual_control_mode`）。平台差异：桌面始终保留真实指针输入（Godot mouse 模式会屏蔽画面触摸，这是移动端取向，不在 macOS 复刻）；面板按键集合沿用现有视觉小说推进键，不复制移动端 D-pad/鼠标键/滚动长按。

验证：行为测试用真实会话断言手柄从画布中心开始、拖动累计为绝对坐标并收敛边界、左键发送真实 down/up、模式切换调用 `resetVirtualPointer()`（Godot `_reset_cursor_drag_position`）；CUA 在真实 KAG3 会话中记录 `virtual cursor -> (385,207)/(451,174)/(517,142)`，并验证 `切换模式` 在 `模式 · 虚拟鼠标` 与 `模式 · 直接触摸` 间切换时手柄/左键按钮的显隐与偏好写入。

### 7.13 P4f实施结果：运行时元数据

新增 `GameRuntimeDetector`，按 Godot `GameMetadata.inspect()` 的标记顺序识别当前宿主可驱动的运行时：校验过的 RFVP `.hcb`（文件头 descriptor/start 合理性，端口自 Godot `_hcb_launch_file()`）→ ONScripter（0.txt/00.txt/nscr_sec.dat/nscript.*/onscript.nt*）→ Minori（scr.paz+sys.paz+已知可执行文件）→ Siglus（gameexe.ini/gameexe.dat/scene.pck）→ KiriKiri（XP3 自动挂载或 startup.tjs/ks），并能报告“未识别”。导入门限复用同一检测：Siglus 与校验过的 `.hcb` 目录现在可以加入游戏库，未识别目录仍被拒绝；刷新与托管/引用语义不变。

详情页新增只读「运行时类型」与「启动入口」两行：运行时来自标记检测，状态来自真实的 `engine_probe_runtime_provider(runtime_id, root)`（>0 匹配、0 存在但不识别、<0 本构建未链接该 provider）；KiriKiri 走内置宿主路径，因此 provider 未匹配时显示“使用内置 KiriKiri 宿主路径（无需额外 provider）”，而不是错误地宣称无法启动。启动入口只展示检测到的入口文件（XP3/startup/ONS 脚本/标记/RFVP HCB），不提供覆盖：`engine_open_game` 的 `startup_script` 参数在当前运行时被忽略，提供可点选但无效的下拉会违反“不开放无实现控件”。RFVP 文本编码同样等待链接 RFVP provider 后再提供，当前在 RFVP 游戏详情页显示原因说明。

### 7.14 P5a实施结果：画面增强（对比度自适应锐化）

Godot 的增强实现位于私有 RenderingDevice provider（Anime4K/FSR1/RAVU/CuNNy/NNEDI3/FXAA + 15 条预设链），其 `FrameEffectProvider` 契约直接依赖 Godot RenderingDevice/RID，Apple Metal 呈现路径无法复用，因此本轮先实现一个**完整可验证**的算法：对比度自适应锐化。五抽头核（中心 + 上下左右）按局部对比度加权拉普拉斯，增量被限制在局部对比幅度内，避免光晕；CPU 参考与 Metal shader 使用同一公式，行为测试逐像素对照（最大差 ≤2）。

`HostSettings` schema v8 新增 `frameEnhancement`（off/adaptive_sharpen，未移植的 Godot 算法 id 在加载与保存时都被拒绝）与 `frameEnhancementAmount`（0–1，0.05 步进）；渲染页新增 Godot 同名的「画面增强」选择器与「锐化强度」滑杆，并明确写出 Anime4K/FSR1/RAVU/CuNNy/NNEDI3/FXAA 尚未移植。增强在 Metal 输出缩放之后执行（同尺寸修复语义），资源按 frame revision 管理；分配或 pass 失败时保留原始画面并记录 `lastError`，符合“失败回退原始画面”。能力随原生 Metal 呈现器可用性上报（无 Metal 时显示 Godot 的不可用说明）。smoke 工具新增 `--frame-enhancement`/`--enhancement-amount` 覆盖（仅基准用），在增强开启时把引擎/呈现 RGB 对比从“必须一致”改为“必须有界地不同”。

### 7.15 P5b实施结果：FSR1 RCAS

P5b 首个切片移植 AMD FidelityFX Super Resolution 1 的 **RCAS**（robust contrast adaptive sharpening），因为它是 FSR1 算法集中唯一有公开 MIT 参考（`ffx-fsr/ffx_fsr1.h` 的 `FsrRcasF`）且可独立验证的部分。核函数忠实照搬参考：对 3×3 的 b/d/e/f/h 邻域取环最小值/最大值，`hitMin = min(mn4,e)/(4·mx4)`、`hitMax = (1−max(mx4,e))/(4·mn4−4)`，逐通道 `lobe = max(−hitMin, hitMax)` 后按参考限制在 `[−0.1875, 0]`（`FSR_RCAS_LIMIT`）并乘以强度；`FSR_RCAS_DENOISE` 与中精度倒数未启用（CPU 与 GPU 都用精确倒数）。全黑/全白邻域会让限制分母为 0，参考依赖 GPU 倒数语义，这里在 CPU 与 Metal 两侧都显式把该分支钳为 0，避免 NaN。

`FrameEnhancement` 新增 `fsr1_rcas`（`allCases` 顺序 off → adaptive_sharpen → fsr1_rcas）；Metal 呈现器新增 `rcas_fragment` 与 `rcasPipeline`，与自适应锐化共享强度 buffer 与 texel buffer。渲染页选择器由 `FrameEnhancement.allCases` 驱动，因此自动多出「FSR1 RCAS」，说明文案改为“当前开放已验证的自适应锐化与 FSR1 RCAS”。`FrameEnhancementKernel.fsr1Rcas` 是 Metal pass 的 CPU 参考，行为测试逐像素对照（最大差 ≤2）。

本轮同时修掉一个真实的缓存缺陷：增强 scratch 纹理原先只按 `frameRevision` 缓存，切换算法/强度而源帧不变时会复用上一算法的结果；现在缓存键加入算法与强度（`enhancedConfig`），`clear()` 一并重置。`--frame-enhancement` smoke 覆盖新增 `fsr1_rcas`；许可全文见 `THIRD_PARTY_LICENSES.md`。

### 7.16 P5b 续：FSR1 EASU

接着移植 FSR1 的另一半：**EASU**（edge-adaptive spatial upscaling），参考同样来自 MIT 的 `ffx-fsr/ffx_fsr1.h`（`FsrEasuCon`/`FsrEasuSetF`/`FsrEasuTapF`/`FsrEasuF`）。EASU 与同尺寸修复算法不同：它自己完成到输出分辨率的放大，因此 `FrameEnhancement.fsr1Easu.scalesOutput == true`，由输出 pass 承担（未配置输出尺寸时按 1:1 运行）；`frameEnhancement` 选择器随之多出「FSR1 EASU」，说明文案改为“当前开放已验证的自适应锐化与 FSR1 EASU/RCAS”。

关键实现点：硬件 `gather4` 用四次钳位点采样模拟（同一 2×2 足迹），参考里的近似 `rcp`/`rsqrt` 换成精确值，使 CPU 参考（`FrameEnhancementKernel.fsr1Easu`，输出 RGBA，alpha 置 255）与 Metal `easu_fragment` 逐像素一致（测试 max diff ≤2）。输出 scratch 纹理的缓存键（`outputConfig`）加入采样算法与增强算法，避免切换算法/采样时复用旧帧。许可全文见 `THIRD_PARTY_LICENSES.md`。

已知限制：EASU 依赖硬件 `gather4` 的具体取址语义，本移植用点采样等价模拟；在 1:1（输出分辨率等于输入）时其锐化核会在锐边处产生可见差异，属算法在非放大场景下的行为，产品默认 1080p 放大路径不受影响。未移植的 Anime4K、RAVU、CuNNy、NNEDI3、FXAA 仍不开放。

### 7.17 P6 首片：首次使用协议门

Godot 首次使用前会弹出隐私/免责协议（`LEGAL_AGREEMENT_VERSION = "2026-07-27.4"`），同意后才进入主界面，拒绝则退出。Apple 宿主此前只在「设置 > 关于」里能查看该文档，没有首次门。本片补齐 macOS 侧的首次门：

- `LegalAgreement.version` 与 Godot 常量一致；`LegalAcceptanceStore` 把 `{version, acceptedAt}` 写到库根下的 `legal-acceptance.json`，与可撤销的设置草稿**分开**（丢弃设置改动不能撤回同意），损坏或缺失文件一律视为「未同意」并重新弹门。
- 首次启动（无该文件）弹出不可关闭的 `LegalAgreementView`：标题、首用说明与打包好的五语言协议正文（`privacy_disclaimer_*.txt`），按钮为 拒绝 / 同意并继续。同意写入版本与时间戳；拒绝在 macOS 上退出应用（与 Godot 桌面行为一致）。
- 非交互测试/基准入口用 debug-only 的 `AETHER_HOST_BYPASS_LEGAL_GATE=1` 绕过（对应 Godot 的 `AETHERKIRI_BYPASS_LEGAL_GATE`），smoke/selftest/profile/cold-start/texture-lifecycle/runtime-movie 工具已设置该变量。
- 渠道额外声明（App Store statement）与「已拒绝」页面属 iOS/M4，本片不涉及。

### 7.18 P6 续：内置 Demo

Godot 在首次运行时把打包的多语言 Demo（`builtin_demos/aetherkiri-kag3/data.xp3`）安装进库，并在删除后记住、不再恢复。Apple 宿主此前只能手动导入，没有同等自动安装。本片补齐：

- `BuiltinDemo` 对齐 `scripts/builtin_demo.gd`：`id = "aetherkiri-kag3-demo"`、`version = 4`；把打包的 `data.xp3` 复制到 `<库根>/builtin_games/aetherkiri-demo/data.xp3`，状态写到 `<库根>/aetherkiri_builtin_demo.cfg`（`{removed, installedVersion, installedSize}`）。
- 启动时 `reconciled(_:)` 幂等地把 Demo 条目并入库（保留既有条目的游玩时长/封面/标题），删除后 `removed=true` 并删除安装目录，重启不再恢复。库条目新增只读 `builtinId`/`builtinVersion`（旧索引解码为 nil）。
- 详情页对内置 Demo 显示「内置 Demo」徽标与「删除内置 Demo」（而非「从游戏库移除」），确认框写明「删除后不会自动恢复」。文案五语言。
- `data.xp3` 作为资源随 App 打包（`project.yml`），与 Godot 共用同一份 Demo 资源；非交互测试/基准入口仍走 bypass。
- 测试 `BuiltinDemoTests`：安装、幂等 reconcile、删除记忆、缺失资源降级；CUA 验证首启安装、详情页徽标/删除、重启不恢复。证据：`out/apple_host/evidence/ui-p6-demo-cua/`。

### 7.19 P6 续：VNDB 在线封面

Godot 用 `vndb_cover_resolver.gd` 后台把游戏标题发给 VNDB 并取首个结果的封面。Apple 宿主此前没有在线封面。本片按 spec 的“单独可选联网动作”实现，隐私优先：

- 详情页新增「搜索在线封面」按钮（在「设置封面」旁），**只由用户显式触发**，不做后台自动扫描。`VNDBCoverSearch` 向 `https://api.vndb.org/kana/vn` POST `{"filters":["search","=",标题],"fields":"id,title,image.url,image.thumbnail"}`；请求体只含标题，不含本机路径或存档。
- 结果以候选列表展示（缩略图 + 标题 + VNDB id），选择后下载封面并缓存到库根 `Covers/vndb-<id>.jpg`，再通过既有 `setCover` 指向它；失败保留当前封面并显示原因。`CoverSearchProviding`/`CoverImageLoading` 协议便于测试注入假实现。
- 测试 `CoverSearchTests`：请求形状（只发标题、空标题拒绝）、响应解析（无图行丢弃）、注入式 search/apply（缓存文件 + 索引）、失败保留。CUA 用真实 VNDB 验证「搜索 → 选择 → 缓存到库根 → 详情页出现清除封面」。证据：`out/apple_host/evidence/ui-p6-vndb-cua/`。
- 与 Godot 的差异：本实现不做后台自动查询；候选选择是显式动作，符合 spec 对隐私的要求。

### 7.20 P5b 续：增强 kind/预设/自定义链

Godot 的增强设置是 `frame_enhancement_kind`（off/preset/custom）+ 预设选择 + 自定义算法链编辑器。Apple 宿主此前只有一个扁平算法下拉。本片改为对齐该模型（schema v9）：

- `HostSettings` v9 用 `frameEnhancementKind`（off/preset/custom）、`frameEnhancementPreset`、`frameEnhancementChain`（有序算法 id）替换 v8 的单一 `frameEnhancement`；v8 文件迁移为一步自定义链，v7（无该字段）迁移为 off，加载不改写原文件。`enhancementSteps` 解析出最终链。
- 预设先开放可组合的「均衡清晰（FSR1）」= EASU→RCAS（Godot 的 `fsr1` 预设）；需要未移植算法的 Anime4K/RAVU/CuNNy/NNEDI3 预设不列出。
- 自定义链编辑器：有序「步骤 N · 算法」行、每步算法选择、移除按钮、＋ 添加算法（上限 32，与 Godot 一致）。只列出已验证算法；EASU 只允许作为第一步（本移植把“缩放”固定为链首，其余为输出分辨率下的同尺寸修复）。
- 渲染：`MetalFramePresenter.enhancementChain` 把链首的缩放步（EASU）作为输出 pass，其余按顺序在同尺寸 ping-pong scratch 上执行；缓存键含链、强度与采样算法，切换链在静态帧上也会重跑。单算法链行为与之前一致。
- 测试：`FrameEnhancementTests` 覆盖 v8→v9 迁移、预设解析、自定义链往返、非法链（未移植算法/缩放步非首位/两个缩放步/空链）拒绝，以及两步链（RCAS→自适应锐化）与 CPU 组合逐像素一致。CUA 验证 kind/预设/自定义 UI、保存 v9 与真实启动日志 `frame enhancement fsr1_easu,fsr1_rcas amount=0.50`。证据：`out/apple_host/evidence/ui-p5b-chain-cua/`。
- 本轮同时修掉内置 Demo 的库索引缺陷：Demo 条目的 `directory` 曾不是 UUID，导致含 Demo 的库重载报「索引无法读取」；现改为 `id.uuidString` 并加测试。
