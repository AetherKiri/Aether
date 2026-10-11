# Apple 宿主产品与 UI 对齐 Spec

- 版本：v0.1，2026-10-11；状态：调查完成、实施待推进。
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

状态：已有 = 已有基础功能，不代表完整验收；部分 = 数据/能力/交互不齐；缺失 = 未接入。P 编号对应实施计划。

### 3.1 设置

| 原 Godot 功能/真实语义 | Apple 当前状态 | 目标/依赖 | 阶段 |
|---|---|---|---|
| 分类索引、行标题+解释、保存、脏状态离开提示 | 缺失；460pt sheet，直接持久化，只有“确定” | 主窗口设置页，分类索引，事务草稿，保存/不保存/继续编辑 | P1 |
| 语言：系统+五语言 | 已有；即时写入 | 保留全部选项，保存后生效，界面语言决定翻译目标 | P1 |
| 风格：dark/classic/warm_dark/warm_light，默认 classic | 缺失；跟随系统原生外观 | 恢复四个产品主题；原生控件色彩与主题协调 | P2 |
| iOS 界面比例 | 平台不适用 | M4；macOS 使用响应式布局，不造手机缩放开关 | M4 |
| 游戏内控制菜单入口开关 | 部分；仅整条虚拟按键显隐 | 区分入口可见性、当前控制模式和按键面板显隐 | P4 |
| Keyboard 模式按键透明度 | 缺失 | 模式实现后提供透明度；指针不受影响 | P4 |
| 渲染管线 | 部分；software/metal，未配置时默认 software | 显示「原生 Metal / 软件诊断」；不要用 Godot Native 名称冒充依赖；GPU Bridge 非必迁管线 | P3 |
| 画布 Game Native/Display Fit | 缺失设置；已有 setSurfaceSize 接缝 | 分离游戏逻辑画布、输出纹理和窗口 drawable；保持输入映射 | P3 |
| 缩放 smooth/nearest/linear/bicubic/lanczos | 缺失选择器与完整实现 | 调查 smooth 实际映射，提供有实现的算法；不可把 linear 重命名为 bicubic | P3 |
| 输出 original/1080p/2k/4k，默认1080p | 缺失设置 | 按原版目标尺寸/纵横比规范迁移；不是改变显示器分辨率 | P3 |
| 增强 off/preset/custom | 缺失 | Metal 后处理与能力报告；原始帧降级；P5 前明确不可用 | P5 |
| 15 个增强预设，16 种自定义算法、顺序添加/移除 | 缺失 | 保留重建2×、目标尺寸缩放、同尺寸修复三种语义；不是统一 resize | P5 |
| FPS 开关+60/80/90/120/144，默认关闭、目标80 | 缺失；当前60Hz Timer | ABI fps_limit + 宿主调度；关闭限制也不承诺超显示器FPS | P3 |
| 游戏横屏锁定 | 平台不适用 | 移动端 M4 | M4 |
| 插件核心/完整（krkrsdl3/aether_all） | 缺失 UI/下发 | 已有 engine option，启动前应用并报告实际结果 | P1 |
| 本地 GGUF 翻译选择/清除、目标跟随界面语言 | 已有，能力不足时整段隐藏 | 纳入草稿；能力不足显示原因；加载状态与偏好分开 | P1 |
| Mock 绕过，默认 true | 缺失 UI/下发 | engine option；保存后下次启动生效 | P1 |
| 诊断 profile：off/baseline/input/render/storage/script/audio/video/plugin/system/full | 缺失；只有日志显隐/导出 | 迁移 profile catalog、采样与导出内容；Debug baseline，Release off | P4 |
| 调试覆盖层 off/summary/detail | 缺失 | CPU/tick/GPU/呈现FPS分开命名；进程与GPU估算内存注明统计口径 | P4 |
| 错误弹窗追加最近20行日志 | 缺失 | UI 与引擎 error_dialog_logs 联动，默认关闭 | P1 |
| 插件追踪/trace日志/控制台文件/TJS导出 | 部分；console_log_file硬编码0，其余未提供 | 临时会话工具；不作为普通持久偏好，追踪与trace 30秒自动关闭 | P4 |
| 场景测试：主页/设置/详情/视频库/视频播放器/游戏，运行状态变体 | 缺失 | 独立测试 fixture 与启动参数，退出可恢复；Debug工具 | P4 |
| QQ社群 | 部分；Help有入口、设置没有 | 设置中也可访问；默认不复制启动推广弹窗 | P1 |
| 关于版本、协议查看 | 缺失设置分区 | Bundle实际版本/构建、五语言协议资源、许可证入口 | P1 |
| 首次使用协议状态与分发相关额外声明 | 缺失 | 单独 AcceptanceStore，按分发渠道、版本管理，不能混入可撤销草稿 | P6 |
| IAP库数量解锁、coffee、恢复购买 | macOS无真实provider | macOS不启用数量限制；M4实现真实购买；不画可购买假按钮 | M4 |
| 检查更新、预发布开关、跳过版本 | 缺失 | 渠道策略后实施；用户要求留到最后 | P7 |
| 版本隐藏解锁 | 缺失 | 内部测试替代入口；不列为macOS核心交互或借此绕过正式权益 | P6/M4 |

增强预设源于 `main.gd` 的 `settings.frame_enhancement_mode.*`；算法源于同文件的算法描述与自定义编辑器。默认值以 `_load_shell_settings` 与变量声明为基线，迁移时用测试锁定，不能凭翻译文案推断。

### 3.2 产品页面与会话

| 区域 | Godot 基线 | Apple 当前差异 | 目标/阶段 |
|---|---|---|---|
| 导航 | 稳定四页入口，窗口内可访问 | 主侧栏只有三页，游戏条目混入导航，设置仅gear sheet | 目的地侧栏四项，菜单同步；P1/P2 |
| 游戏库 | 封面卡片、数量、搜索、最近游玩排序再按标题、导入/引导 | 条目侧栏，自动进入首个详情，无搜索，无同等排序 | 封面网格为默认，可选列表；搜索标题/运行时/路径；P2 |
| 详情 | 封面编辑、运行时类型、路径、最近游玩、时长、启动入口、RFVP编码、重命名/移除 | 仅标题/日期/储存类型；封面操作藏入管理菜单 | 编辑封面在封面区域可发现；管理菜单作补充；其余按能力逐项补齐；P2/P4 |
| 导入/刷新 | 探测元数据、目录/文件入口、封面/启动入口回填 | 目录/ZIP复制或外部引用已有；刷新主要重新读取索引和封面发现 | 保留托管/引用差异；Apple当前主要按KAG/ONS文件名、XP3及Minori PAZ识别，与Godot多runtime元数据探测不齐；扩展已链接provider的入口识别，刷新不覆盖手动配置；P2/P4 |
| 内置Demo | 多语言Demo安装、版本与删除记忆 | Apple未接入同等自动安装 | 沙盒测试后打包安装，可移除且重启不恢复；P6 |
| 在线封面 | VNDB请求、候选标题、索引 | 未迁移 | 单独可选联网操作，失败保留手动封面；P6 |
| 主页 | 总时长、已玩、近周、最近5款、时长排行、活动/里程碑 | 仅游戏/视频数量和最近1款；无时长数据 | 先补准确会话时长，再恢复内容；原版周活动按lastPlayed推导，非完整历史日记；P4 |
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

现有 shell UserDefaults 首次迁移进版本化存储；保留用户已选software/metal与翻译路径。全新安装以原生Metal为产品默认，初始化失败可回退软件并显示原因；这是目标，当前源码默认仍是software。不要静默覆盖既有选择。Godot配置导入是显式功能，不自动覆盖不同产品储存目录；库schema兼容与设置迁移分别处理。

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

当前60Hz Timer与固定1/60 tick，无法通过新增144选项实现144FPS。P3必须明确模拟时间、引擎render限频和MTKView呈现的关系；不得提高Timer频率同时仍每tick推进1/60而加速剧情。产品显示的FPS必须标明呈现/渲染统计，提交吞吐benchmark不作为玩家帧率。

### 4.4 视觉与可访问性

Lumen四套主题保留内容层、强调色、圆角与封面比例；系统字体负责可读正文，展示标题可参考已有字体资源。原生菜单、文件选择器和窗口控件遵循系统行为；不复制大面积光效或强制动画来证明对齐。动画响应Reduce Motion，主题须验文字/控件对比度。

所有图标动作有可见标签或可发现的文本说明及VoiceOver名称。核心入口不依赖hover；键盘支持焦点移动、Enter打开详情、Escape返回/关闭非破坏性弹窗、Cmd-F搜索。实际快捷键和禁用状态使用共享action，不在不同View重复定义。

## 5. 完成标准

每个功能需同时有：窗口内入口、数据持久化/有效值、实际执行、生效时机、失败处理、五语言与必要的自动化/CUA证据。不能以“已有翻译键/已有按钮/编译通过”勾选迁移完成。

每阶段按[计划](apple_host_ui_plan.md)验收并更新进度。全量功能对齐仍未完成；本 spec 不将当前MVP标成成品，也不改变性能证据的适用范围。
