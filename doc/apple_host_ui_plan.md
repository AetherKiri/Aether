# Apple 宿主 UI 与设置对齐实施计划

- 2026-10-11，依据 [产品 UI spec](apple_host_ui_spec.md)。
- 状态：P0调查完成；P1核心实现与行为测试已接入，完整CUA验收待补；P2集合/详情及四主题已接入，完整视觉/无障碍验收待补；P3a–P3d、P4a/P4b/P4d/P4e/P4f、可停靠诊断控制台（含标记/慢帧捕获/快照/截图/自检）与场景测试入口均已实现并通过行为回归与真实CUA；P5a（对比度自适应锐化）与 P5b（FSR1 RCAS/EASU + 双三次/Lanczos 链步骤 + Godot 的 kind/预设/自定义链，AMD MIT 参考 + CPU 对照 + 缓存键修复）已实现并通过行为回归、真实 smoke 与设置页/启动路径 CUA；P6 已接入 macOS 首次使用协议门、内置 Demo 与 VNDB 在线封面并通过行为回归与真实 CUA；P4 其余（RFVP 编码待链接 provider）、P5b 其余 Godot 算法与预设移植、P6 其余（渠道声明）与 P7 尚未实施（视频库暂停维护）。阶段按依赖排序，每轮只提交已验证的完整切片。
- 目标是修正产品结构并补齐真实功能；不在一轮中把所有缺项画成无效果控件。

## P0：调查与规范（本轮）

- [x] 检查Godot页面builder、设置存储/草稿、引擎option、增强实现、库/视频/统计与相关测试。
- [x] 检查Apple对应实现、HostKit接缝、构建与分发范围。
- [x] CUA查看既有Godot导出的库、设置和渲染页面；识别源码与构建能力差异。
- [x] 写功能差异矩阵、目标交互、生效时机、实施顺序和验收口径。
- [x] 修正架构文档中“不追求壳完整对齐”的阶段表述，增加UI迁移跟踪。

产物：[spec](apple_host_ui_spec.md)与本计划。P0轮次仅修改文档；随后已进入P1实施，见下方记录。

## P1：设置事务与产品信息结构（进行中）

2026-10-11 实施记录：

- [x] 版本化JSON存储、旧UserDefaults一次迁移、独立草稿、保存校验与写盘失败隔离。
- [x] 设置进入第四个主导航目的地；独立分组View替换sheet；保存状态与离开确认；窗口delegate代理与退出应用确认已接入。
- [x] 插件加载、Mock、错误日志在真实engine初始化中接入并确认返回成功；关于版本、五语言协议阅读、许可证与社群入口；翻译路径纳入草稿。
- [x] `SettingsStoreTests`与真实`ShellModel`测试通过，包含继续编辑/丢弃/保存导航、重启恢复、关闭回调、校验/写盘失败；实际打包协议/许可资源检查通过；五语言检查通过。
- [ ] 完整CUA：已看到隔离库中的四导航和分组设置页、无修改时保存禁用；随后原生CUA pipe关闭，重连及inventory超时。保存/丢弃/窗口关闭/应用退出的实际点击、五语言最长布局、文件选择取消仍待补，不能以模型测试代替。
- [ ] 渲染回退、统一HostCapabilities及四主题按P2/P3继续；诊断profile与高级工具仍显示未迁移说明。

分成可独立验收的三次切片：

1. `SettingsStore`/`SettingsDraft`/schema migration、纯值校验、生效分类和保存失败处理；迁移现有UserDefaults，不改已选renderer。
2. 主导航四目的地、分组设置页替换sheet、保存/脏状态离开确认、窗口关闭处理；保留Cmd-,与窗口内入口。将`ShellView`拆分为页面、设置组件、命令层，避免继续扩大单文件。
3. 接入已有选项的插件加载、Mock、错误详情；翻译模型纳入草稿；关于版本、协议查看、诊断导出与社群入口；翻译不可用原因可见。

主要改动：`ShellModel.swift`、`ShellView.swift`、`ShellStrings.swift`、`AetherHostApp.swift`、`EngineController.swift`；新增Settings模块、能力模型与测试。协议文本复用Godot五语言资源，通过project.yml打包，不硬编码网页免责声明。

验收：

- 有无修改两种离开流程；保存、丢弃、继续编辑；关闭窗口同样执行。
- 保存失败不会覆盖原有效值；重启后恢复；旧偏好迁移只执行一次，空值和未知枚举有稳定默认。
- 修改模型路径后丢弃不会改变持久配置；保存后实际启动传入正确option顺序和值。
- provider不支持与文件错误有不同反馈；当前游戏/视频禁用菜单与窗口设置入口。
- CUA五语言抽查最长文本、分类切换、文件选择取消、Cmd-,、保存后返回库；不需联网或更改原Godot用户偏好。

## P2：封面集合、详情与视觉体系

2026-10-11 集合/详情实施记录：

- [x] 主侧栏移除游戏/视频条目，恢复封面网格、可选紧凑列表与独立详情；常用动作、复制导入/外部引用均有窗口内入口，移除重复的集合页标题栏操作。
- [x] 游戏/视频名称和路径搜索（多词、大小写、全角、音标折叠）；最近游玩/观看排序；空库与无结果区分；返回恢复搜索与条目滚动锚点。
- [x] 视频真实总时长持久化，旧无时长索引兼容；移除确认清理对应进度与字幕选择并保留原文件；失败保留条目并反馈。
- [x] 行为回归0/1/30条目、刷新、封面清除抑制、缺失详情退出；字幕/播放器/真实总时长回归通过；Debug构建与五语言检查通过。
- [x] CUA连接恢复后隔离fixture点验搜索、Cmd-F、列表切换、Escape详情返回、滚动锚点、无结果、视频移除/取消与磁盘清理；中/英约968×692pt窄窗口及长中日韩英标题抽查，封面文件选择取消通过；最终截图留在`out/apple_host/evidence/ui-p2/`。
- [x] 四套Godot Lumen内容tokens、原生明暗外观、分组表面和突出按钮对比度；设置schema v1→v2读取兼容、未知主题回退、保存/丢弃/重启、写盘失败隔离；默认classic。
- [x] 四主题保存切换CUA点验与截图，深色重启恢复；English界面/渲染分类抽查。原生突出按钮白字与Godot不同，底色按同一强调色降低亮度，测试对比≥5:1；正文/次要文字对三种内容表面对比≥4.5:1；配色字段与Godot源码交叉检查通过；CUA截图中三种暖/深色突出按钮内侧文字/底色采样为5.70/5.55/6.72:1，记录`native-button-contrast.json`。
- [ ] 960×640、1280×800准确尺寸全组合、真实封面比例、VoiceOver/键盘完整操作、五语言全部设置分类及Reduce Motion系统环境仍待验收。新主题代码不添加动画、响应Increase Contrast的次要文字和边框；CUA执行English分类时原生pipe再次关闭，重连同样失败，不能勾选完整验收。运行时搜索依赖P4元数据。

P1 CUA补验：实际点击继续编辑/丢弃、保存英文后重新翻译、关闭窗口提示与取消退出均有效；没有完成关闭/退出并重启、全部五语言分组与文件选择取消，P1尚不勾选完整验收。

依赖P1的路由与设置结构。

- 主侧栏只含目的地；游戏库恢复自适应封面网格，可选紧凑列表。
- 游戏/视频搜索、数量、空库/无结果区分；最近游玩+标题排序；返回恢复搜索与滚动状态。
- 页内导入、刷新、帮助清晰可见；工具栏围绕当前内容，外部引用与复制导入有清楚含义。
- 游戏详情封面区域可直接编辑，常用动作可见；路径/类型/储存状态与日期分组；重命名/移除保持安全确认。
- 视频集合显示已存进度，移除确认清理对应进度与字幕选择；暂未获得总时长时不伪造百分比。
- 四套Lumen主题token以Swift实现，系统控件匹配主题；不移植Godot控件源码。

验收：临时fixture库覆盖0/1/30条目、长中日英韩标题、缺封面/路径丢失；960×640、1280×800及大窗口；键盘与VoiceOver；主题对比/Reduce Motion。已有封面清除抑制标记、旧索引、外部引用回归必须保持。

## P3：画面基础设置与调度

P3应先完成能力/配置，再逐项实现，禁止一次开放所有尚未验收的下拉选项。

1. renderer命名、默认Metal与可观测软件回退；保留已有用户配置；诊断报告实际路径。
2. 画布、目标输出分辨率、输入映射；复用`EngineSession.setSurfaceSize`，明确原始帧与逻辑surface尺寸。
3. nearest/linear/bicubic/lanczos采样；核对Godot smooth别名，禁止算法名称与实际shader不符。
4. fps_limit透传和宿主调度重构；明确模拟dt策略、渲染节奏与呈现节奏后才开放全部目标帧率。

验收：非对称RGB、棋盘/细线图、640×480与宽屏fixture、resize/fullscreen；输入坐标、边界release、截图对齐、FrameLease清理；GPU失败回退。对60与高刷新调度测量“时间推进正确、限频有效、呈现无异常”，不复用提交吞吐数宣称屏幕FPS。

不得改已有engine/provider ABI来装配UI；如发现缺能力，先记录边界与兼容方案。Metal直通生命周期保持，不恢复正常帧CPU回读。

## P4：会话数据、诊断与控制

范围调整（2026-10-12）：项目聚焦视觉小说，视频库/播放器暂停维护，不再作为 P4 交付项；已有视频实现保留，只做不破坏兼容性的修复。

可以在P3基础画面功能稳定后按模块独立推进。

- 会话时长：schema加可选累计字段，单调时钟累积；覆盖失败启动、重启、返回、进程退出；先明确暂停是否计时，采用“运行会话时长”并按标签展示。
- 主页：总时长/已玩/近周、最近5项、排行；迁移Godot既有统计算法，不能把lastPlayed推导的活动图标成精确日历记录。
- 运行时元数据与可配置入口；legacy文件入口与provider目录根语义分别遵守`GameLaunchEntry`；RFVP编码只对识别出的对应runtime提供。
- 诊断profile、覆盖层、调试控制台（概览/事件/日志过滤与暂停/输入/插件）、问题标记/上下文和导出；复用profile catalog语义，明确Apple采样字段与Godot的差异。日志显隐不代替采样配置。
- 高级临时工具、30秒追踪自动关闭、场景fixture入口；应用退出/重启不能自动重开临时追踪。
- 虚拟控制模式、入口与透明度；失焦/弹窗/退出释放全部按键。
- （暂停）视频控件自动显隐、键盘/鼠标、全屏状态恢复；字幕自动发现与选择记忆回归。

验收：会话累计不重复、失败启动不计时；旧schema可读、原子保存；profile导出包含实际信息；临时开关到期；焦点/按键释放；无障碍操作不因自动隐藏丢焦点。视频相关验收项暂停（见上方范围调整）。

## P5：增强管线（独立渲染工作包）

依赖P3的原始帧、输出尺寸与能力模型，不能归类为“补设置页面”。

- 提取Godot增强参数/算法语义并记录依赖与许可；先做基线缩放/锐化，再迁移重建与恢复算法。
- Metal后处理消费FrameLease，处理pass、临时纹理和目标缓存独立管理；原始画面降级可验证。
- 对齐15预设/16算法自定义链、顺序、2×重建和同尺寸pass语义；全部实现前只启用已通过验收的能力。
- 不支持构建/设备与运行失败显示具体原因，并保留用户配置以供未来可用时恢复。

验收：Godot原版同输入确定性图片对照，文字/人物线条/纹理；明确容差与差异而非一律要求RGB零差；GPU数值稳定、失败回退、资源清理、1080p/4k负载报告。设置保存、切链、resize不得造成旧frame lease悬空或双重缩放。

## P6：产品补齐与发布前一致性

- 内置多语言Demo打包、安装版本、移除记忆；默认库首次体验验收。
- VNDB封面独立可选联网动作、明确请求用途/失败反馈，缓存落宿主目录；不覆盖手动封面，不向外发完整本机路径。
- 首次协议与渠道额外声明状态迁移，阅读/接受/拒绝路径；测试使用隔离状态，不替用户接受协议。
- 版本/许可/品牌资源与发布包核对；合法渠道权益能力单列，不以隐藏入口替代真实provider。
- 完整对齐矩阵复核，每项标成已验收/明确差异/平台不适用/延后。

M4：真实StoreKit、数量与coffee权益、restore、移动端横屏/安全区/界面比例独立计划，macOS当前数量不限。Minori和G1不成为P1–P6阻塞。

## P7：更新器（最后）

分发渠道确定后再接入检查更新、预发布偏好、忽略版本与失败反馈。App Store渠道不套用自更新下载流程；目前不实现。

## 检查与交付纪律

- 修改前检查工作区，单轮单commit并push，仅提交相关改动。
- 数据/设置/option/调度变化用行为测试；普通间距/字体修改不写镜像测试。
- 每个UI切片构建通过后CUA验证，不把编译当交互验收。
- CUA使用隔离fixture库与设置域；截图记录窗口、语言、主题、构建、已验证动作，证据留`out/apple_host/evidence/`，不提交真实游戏路径或存档。
- 进度只勾选实际完成的模块；M2已完成MVP不等于设置与产品完整迁移。
- 每次更新spec表中状态与必要的实际差异；尚未开放的功能不标为已完成。


## 复核后的执行队列与阶段门槛

本次复核以已提交 `aba88a61` 为起点。P1/P2已有实现继续保留，补验与P3可独立工作并行排期；完整CUA不能因连接失败被勾选。该文档复核轮保留的P3能力/回退草稿，已在后续P3a切片完成行为验证，见下方记录。

| 顺序 | 完整切片 | 核心交付 | 通过条件 |
|---|---|---|---|
| 1 | P1/P2验收收尾 | 设置事务、集合/详情、四主题现有实现 | 完成保存/丢弃/继续、关闭/退出重启、五语言全分类、两种窗口尺寸、键盘/VoiceOver；留隔离fixture证据 |
| 2 | P3a能力与安全回退 | 启动前能力说明；请求/实际renderer与presentation；失败原因与诊断报告 | 无设备/呈现器失败、原生不支持、部分激活失败均测试；清理后新会话可重试；运行中呈现降级不能伪称引擎已切软件 |
| 3 | P3b画布与输出 | 版本化偏好、Game Native/Display Fit、original/1080p/2k/4k | 非对称图像和点击坐标对齐；resize/fullscreen不丢lease；重启持久化与旧配置兼容 |
| 4 | P3c缩放 | nearest/linear先验收，再实现bicubic/lanczos；smooth语义核对 | 同输入与Godot确定性图像对照；名称与shader一致；不提前开放未实现算法 |
| 5 | P3d调度 | FPS开关与目标、真实dt策略、engine限频和呈现统计 | 60/高刷新/无限制口径分开；同一剧情时长不加速；前台/失焦/暂停策略明确 |
| 6 | P4会话与内容（完成：P4a/P4f） | 会话累计→主页统计；运行时元数据/启动入口只读 | 失败启动不计时、重启不重复、旧索引兼容；provider 探测与根目录语义已验收；编码待链接 provider |
| 7 | P4诊断与输入/控制（完成：P4b/P4d/P4e） | profile→覆盖层→临时工具；控制模式/透明度 | profile 导出内容匹配；30 秒追踪自动关闭；面板/入口/透明度与模式切换已验收；控制台与场景测试入口仍待迁移 |
| 8 | P5增强 | 基础缩放/锐化→重建/恢复→预设/自定义链 | 每算法先实现后开放；参考图与负载报告、故障退回原始画面、切链/resize资源生命周期 |
| 9 | P6发布一致性 | Demo、可选VNDB、首次协议、品牌/许可证 | Demo移除后不重装；手动封面不覆盖；协议接受状态独立；最终差异矩阵逐项结案 |
| 10 | P7更新器 / M4平台项 | 更新器最后；真实IAP和移动端独立安排 | 按分发渠道选择真实provider，不用macOS假购买或自更新套用App Store |

每个设置切片都包含：字段/默认值/迁移、窗口内入口与五语言说明、真实执行、生效时机、当前有效值、失败路径、行为测试和CUA。若底层缺能力，先完成可审查的实现设计与参考fixture，不能只提交下拉菜单。

P3a重点验证部分Metal激活失败后的资源清理：不得在已打开游戏上销毁引擎重试；启动前的安全重建与运行中的显示降级必须区分。P3a已通过Debug构建、故障行为与30秒直通回归；页面CUA仍待验收。

各轮最终回复报告本轮切片、已验证/未验证范围、一个commit和push结果。不能通过更新进度文案掩盖尚未完成的运行功能；Minori、G1与更新器的原有暂缓顺序保持。


## P3a实施记录：能力检测与安全回退

- [x] 预启动设备/呈现器与真实翻译provider能力；五语言原因与未迁移说明；原生Metal/软件诊断命名；保存偏好保持不变。
- [x] 初始化失败清理部分激活会话，再创建软件会话；真实错误码保留，不支持与失败区分；双重初始化拒绝。
- [x] 请求/实际引擎/呈现分别记录到界面与诊断；开发入口新建诊断会话后完整状态重新发布。
- [x] 运行中显示失败退图像、游戏继续，引擎管线不变；清理FrameLease；重复回调幂等；下次启动重试原选择。
- [x] `python3 tools/apple_host_settings_tests.py`通过：新RendererBehaviorTests实际部分激活失败两次后原生重试成功、KAG3软件/原生启动、显示失败后画面/tick继续、lease/generation清理、报告、真实ABI错误码；原设置/集合/五语言回归通过。
- [x] Debug应用构建通过；`python3 tools/apple_host_smoke.py --game kag3 --duration 30 --renderer metal --presentation metal --snapshots direct --output out/apple_host/evidence/ui-p3a-native`通过，输入推进、三时点CPU/GPU截图对照和干净退出，证据在指定目录；只是短回归，不宣称新五分钟门槛。
- [ ] 页面CUA：P3a专属预启动状态仍待补验；P3b设置页已在真实构建窗口完成CUA，不将该证据扩展为P3a完整验收。

下一切片：P3d调度；P1/P2/P3a的剩余CUA补验继续独立推进；P5增强保持独立工作包。

## P3b实施记录：画布与输出

- [x] `HostSettings` schema v3 增加 `canvasMode` 与 `outputResolution`；v1/v2 配置和旧 UserDefaults 迁移到 `original`，新安装默认 `1080p`，保存前完整校验。
- [x] `Game Native` / `Display Fit` 与 `Original` / `1080p` / `2K` / `4K` 接入设置页和五语言文案。输出保持游戏原始比例并受目标尺寸上限约束；逻辑输入画布维持原始尺寸。
- [x] Metal 路径在 GPU 命令中完成输出缩放，同一帧复用中间纹理，新 frame revision 不复用仍可能在 GPU 使用的目标；软件路径使用等价 RGBA 缩放并在分配失败时回退原始帧。
- [x] 输入指针、IME 插入符和诊断状态使用逻辑画布到输出尺寸的同一映射；诊断同时显示逻辑画布与实际输出尺寸。
- [x] `python3 tools/apple_host_settings_tests.py`、Debug 构建和 KAG3 30 秒 Metal direct smoke 通过。1080p smoke 输出为 1440×1080，逻辑帧为 640×480，`leases_acquired/submitted/completed=446`、`leases_live=0`、`lease_failures=0`、Metal RGB max diff=0。
- [x] CUA 使用构建产物真实窗口验证渲染设置：可见“画布模式”和“输出分辨率”，切换到“适应显示”与“1080p”，保存后显示“设置已保存”且保存按钮禁用。

下一切片：P3d 调度（FPS 与模拟时间策略）；P5 增强继续保持独立，不提前开放未实现控件。

## P3c实施记录：采样算法

- [x] 核对 Godot 语义：`smooth` 是 `linear` 的兼容别名；默认算法为 `bicubic`；`nearest`、`linear`、`bicubic`（Catmull-Rom 4×4）和 `lanczos`（半径 3）分别对应真实采样核。
- [x] `HostSettings` schema v4 持久化 `upscaleAlgorithm`；v1/v2/v3 旧配置迁移为 linear，新安装默认 bicubic，保存时规范化 smooth。
- [x] Metal presenter 实现四种 GPU 采样核；输出中间纹理只在目标尺寸或 frame revision 变化时重建，最终 drawable pass 不重复应用输出核。软件路径实现同核 CPU fallback，并保留失败回退原始帧。
- [x] 设置页提供四语言采样选择器与负载说明；诊断记录有效采样算法；smoke 工具支持 `--sampling-algorithm`。
- [x] 行为测试覆盖 smooth 迁移、四种 CPU/GPU 采样结果对照和持久化；KAG3 Metal direct 30 秒 smoke 已分别通过 nearest、linear、bicubic、lanczos，均无 RGB 差异、呈现失败或未完成 lease。
- [x] CUA 在真实构建窗口验证四个选项可见、双三次可切换并保存成功；随后恢复原有线性偏好。

## P3d实施记录：FPS 与调度

- [x] `HostSettings` schema v5 新增 `fpsLimitEnabled=false`、`targetFPS=80`；v1–v4 文件缺字段迁移为默认值，只接受 60/80/90/120/144，保存前完整校验。
- [x] 设置页渲染分类提供五语言 FPS 开关与目标选择；关闭时显示“跟随显示刷新（当前）”，启用时显示五个目标值；文案说明真实经过时间与下次启动生效。
- [x] 启动前真实下发 `fps_limit`：关闭为 `0`，启用为目标值；`AETHER_HOST_FPS_LIMIT` 仅作 smoke/benchmark 覆盖，不写入偏好。
- [x] 宿主调度改为独立帧时钟：CVDisplayLink 优先跟随显示刷新，无活动显示或显式要求时退回 RunLoop Timer；启用限制时由 `FrameScheduler` 按目标间隔放行 tick，每次回调最多一次 tick，超出部分丢弃为 `dropped_catch_up`。
- [x] 每次 tick 传入真实 elapsed 毫秒（含亚毫秒余量），单次上限 100 ms；失焦/隐藏/最小化/遮挡/系统休眠通过 AppKit 与 NSWorkspace 通知重置调度时钟并记录状态，退出时停止帧时钟并解绑观察者，不产生追赶爆发。
- [x] 分开记录 tick/render/presentation：`engine_tick` 调用数、`engine_get_frame_rendered_flag` 实际出帧数、drawable 提交/图像发布数；日志与诊断注明三者都不等于屏幕扫描FPS。
- [x] `python3 tools/apple_host_settings_tests.py` 通过：新增 60/120 Hz 合成脉冲的调度单元测试（目标 80 不被超过、累计模拟毫秒一致、迟到回调丢弃追赶、100 ms 上限），设置迁移/目标校验/engine option 值，真实引擎下发与真实 elapsed 调度。
- [x] Debug 构建通过；KAG3 30 秒 smoke：软件（original 输出、Timer 跟随显示）113.1 tick/s、Metal 限制 80（Timer）76.0 tick/s 不超过目标、Metal 跟随显示（DisplayLink）112.9 tick/s；三次运行均 RGB max diff=0、`lease_failures=0`、`leases_live=0`、Metal failures=0，脚本化生命周期事件重置调度且 `max_delta_ms<=100`。
- [x] CUA 在真实 Debug 窗口验证渲染页默认关闭并显示跟随显示刷新、五个目标值、选择 120 FPS 后保存为“设置已保存”且保存禁用，重启后仍为启用 120 FPS。

## P4a实施记录：会话时长与主页统计

- [x] `LibraryGame` 新增 `playDurationSeconds`：旧索引缺字段读取为 0、负值归一为 0；`GameLibrary.addPlayDuration` 原子保存并沿用 Godot 上限（单次会话最多一天，非正贡献忽略）。
- [x] `EngineController` 只在 `startup state: SUCCEEDED` 后用单调时钟开始会话；`consumePlaySeconds()` 终结会话并返回自上次提交以来的秒数。返回游戏库、重启、应用退出各提交一次：失败启动/启动中不计时，重复返回与重启不重复计数。
- [x] `PlayStats` 迁移 Godot `_dashboard_stats`：总时长、已游玩、近七天活跃、平均时长（截断到整分钟）、时长排行（>=60s 前5）、最近游玩（前5）、七天足迹与活跃天数、`DASH_MILESTONES` 里程碑、按本地小时的问候语；主页不再显示视频计数卡。
- [x] 主页重建为 Godot 内容结构：三层进度环 + 中心累计时长、问候与统计副标题、三条图例、打开库入口、四张统计卡、近七天足迹、继续阅读卡、时长排行与最近游玩；详情页新增“游玩时长”。图标用 SF Symbols，不复制极光/模糊背板与进入动画。
- [x] `ThemePalette` 增加 Godot `accent_2`/`accent_3`/`success` 三个 token 并纳入 `tools/apple_host_settings_tests.py` 的配色交叉检查。
- [x] `python3 tools/apple_host_settings_tests.py` 通过：新增旧索引兼容、时长/问候格式化、固定日历下的统计算法、上限累加，以及真实引擎的会话累计（启动中/被拒绝的启动不计时、重复返回不加时、重启先提交）；五语言目录新增 `%s` 说明符防护。
- [x] Debug 构建通过；CUA 用隔离 fixture 库（3 条，10740s）验证主页数值（2 小时 · 59 分钟、平均 59m、里程碑 60%、3/3、3/7、七天足迹与排行/最近列表），并用“继续→返回游戏库”实测真实会话把条目从 5400s 累加到 5452s。证据：`out/apple_host/evidence/ui-p4a/`。

## P4b实施记录：诊断 profile 与性能覆盖层

- [x] `HostSettings` schema v6 新增 `diagnosticProfile`（11 档，Debug 默认 baseline/Release off）与 `debugOverlayMode`（off/summary/detail）；v1–v5 迁移、取值校验与往返保存。
- [x] profile 映射到真实来源：input/plugin/full 启动前下发 `input_trace`/`plugin_trace`/`trace_log`；baseline/render 采宿主帧工作；input/full 记录输入事件；system/full 导出系统快照；storage/script/audio/video 无 Apple 采样源，不出现在选择器并在设置页/日志说明原因。
- [x] 性能覆盖层：后端/API/纹理/尺寸、tick 与 render 与 presentation 分开的速率和口径说明、帧工作耗时、调度状态、fallback/错误、进程内存与系统空闲/引擎缓存；detail 追加 p50/p95/max、dropped/coalesced/resets、会话计数与缓存明细；GPU 估算明确标注本构建不可用。
- [x] 覆盖层保存后立即作用于运行中的会话；快照由 tick 循环每 30 tick 节流刷新，视图不持有定时器（每 tick 发布不会打断订阅）；返回游戏库后覆盖层消失。
- [x] `python3 tools/apple_host_settings_tests.py` 通过：profile 目录/可用性/映射、schema v6 迁移与校验、覆盖层文本组合（含内存口径与 detail 增量），以及真实引擎的 profile 下发、`renderer_info`/`memory_stats`/帧工作采样/导出上下文。
- [x] Debug 构建通过；CUA 验证诊断设置页（默认基础、可用档位过滤、存储等不可用档位不再可选、选择完整档位显示真实映射、悬浮信息三档、保存状态）与真实 KAG3 覆盖层（tick 111.3/s、render 11.2/s、presentation 111.3/s、App/Peak/System free/Cache、p50/p95/max、会话与缓存明细），返回后会话计时正常提交。证据：`out/apple_host/evidence/ui-p4b/`。

## P4d实施记录：临时高级工具

- [x] 设置「高级开发工具」接入 Godot `_set_advanced_tool` 的四个真实引擎选项：`plugin_trace`、`trace_log`、`console_log_file`、`export_scripts`；五语言标签/说明沿用 Godot 文案。
- [x] 会话级语义：不写入 `HostSettings`、不产生草稿脏状态、重启自动关闭；`plugin_trace`/`trace_log` 开启后 30 秒由 tick 循环自动关闭并下发 "0"；`console_log_file`/`export_scripts` 无时限。
- [x] 应用时机：有会话时立即下发并在被拒绝时回滚 UI 状态；否则在 `initializeEngine` 应用，已过期项丢弃并记录 `expired before launch`；诊断导出附带选项状态与剩余秒数。
- [x] `python3 tools/apple_host_settings_tests.py` 通过：新增工具目录/30 秒到期/无时限项/快照/重置单测，以及真实引擎的预启动应用、运行中关闭、`appliedSettingOptions` 不含临时工具。
- [x] Debug 构建通过；CUA 验证高级页四个开关与说明、切换不产生未保存状态；真实 KAG3 会话日志显示 `plugin_trace=1`/`trace_log=1` 应用、引擎 `engine_set_option: plugin_trace/trace_log=true`，30 秒后自动 `expired after 30 s` 且下发 `false`。证据：`out/apple_host/evidence/ui-p4d/`。

## P4e实施记录：游戏内虚拟控制

- [x] `HostSettings` schema v7 新增 `virtualControlMode`（mouse/touch，默认 mouse）、`virtualControlMenuEnabled`（默认 true）与 `virtualControlKeyboardOpacity`（0.2–1.0，0.05 步进）；v1–v6 迁移、加载归一与保存校验。
- [x] 游戏画面按 Godot `_sync_visibility()` 呈现：入口按钮（右上角）与面板开合分离；关闭入口等于隐藏整条虚拟控制；面板默认关闭。
- [x] 按键与保持 Ctrl 使用配置透明度，鼠标模式指针手柄保持完全不透明（Godot“指针保持清晰”）；键盘模式按键透明度文案沿用 Godot 五语言资源。
- [x] 面板内切换 mouse/touch 并立即持久化：mouse 显示可拖动指针手柄与左键按钮（拖动差值换算为逻辑画布像素、绝对坐标收敛到画布内），touch 隐藏两者、沿用真实指针；桌面始终保留真实指针输入（不复刻移动端画面屏蔽）。
- [x] `python3 tools/apple_host_settings_tests.py` 通过：新增透明度 snap/clamp、模式取值、Godot 入口/面板可见性矩阵与虚拟指针收敛单测，以及 schema v7 迁移/校验。
- [x] Debug 构建通过；CUA 验证会话起始只有入口按钮、点击后出现面板与指针手柄、按键透明度 0.5 下手柄仍清晰（首次布局重叠已修复重验）、`左键点击` 在虚拟指针坐标发出真实 down/up 并推进剧情、`回车` 按键推进剧情。证据：`out/apple_host/evidence/ui-p4e/`。
- [x] 补验完成（解锁后重跑）：CUA 拖动手柄产生 `virtual cursor -> (385,207)/(451,174)/(517,142)`；`切换模式` 切到 `模式 · 直接触摸` 后手柄与左键按钮消失、切回恢复，且 `virtualControlMode` 立即写入偏好。另有真实会话行为测试覆盖手柄居中/累计/边界收敛/真实 down-up 与模式切换重置。

## P4f实施记录：运行时元数据

- [x] 新增 `GameRuntimeDetector`：按 Godot `GameMetadata.inspect()` 顺序识别 KiriKiri（xp3/startup.tjs/ks）、ONScripter、Siglus、Minori 与校验过的 RFVP `.hcb`，并区分“未识别”；HCB 头校验端口自 Godot。
- [x] 导入门限复用同一检测：Siglus 与校验过的 `.hcb` 目录现在可导入，未识别目录仍拒绝；托管/引用与刷新语义不变。
- [x] 详情页新增只读「运行时类型」与「启动入口」：状态来自真实 `engine_probe_runtime_provider`；KiriKiri 走内置宿主路径时显示对应说明而非“无法启动”；启动入口不做覆盖（ABI 忽略 `startup_script`），RFVP 编码等待链接 provider 后提供并显示原因。
- [x] `python3 tools/apple_host_settings_tests.py` 通过：新增标记检测、HCB 校验、导入门限与真实 provider probe 断言（ONScripter 匹配夹具并拒绝 KAG；未知 id 返回负值）。
- [x] Debug 构建通过；CUA 在真实窗口验证 KAG3 详情（KiriKiri + 内置宿主说明 + 入口 startup.tjs）与 ONScripter 夹具详情（ONScripter + provider 已匹配 + 入口 0.txt）。证据：`out/apple_host/evidence/ui-p4f/`。

## P4实施记录：可停靠诊断控制台

- [x] 游戏内「游戏」菜单新增「诊断控制台」开关；打开后在右侧停靠 380pt 面板（关闭时若「显示运行日志」开启则恢复原日志面板）。
- [x] 五标签：概览（renderer/presentation/frame/output/fpsLimit/tick/回退）、性能（与覆盖层同源的技术行 + pacing/session/cache）、输入（控制模式/指针/IME/全屏/影片）、插件（加载模式 + 当前游戏运行时/入口/信号 + 真实 provider probe + 翻译可用性）、日志（暂停 + 过滤）。
- [x] 面板打开时引擎在覆盖层关闭的情况下也刷新快照（`diagnosticsConsoleActive`）；底部「复制摘要」写入剪贴板，「导出诊断日志」复用既有导出。
- [x] Debug 构建通过；CUA 验证菜单开关、面板停靠与概览/性能/插件标签真实数据。证据：`out/apple_host/evidence/ui-p4-console-cua/`。
- [x] 问题标记（Godot `MARKER_TYPES`，上限 `MAX_MARKERS=8`）+ 保存快照（JSON，含完整 metrics）+ 截图（PNG）+ 自检（session/engine/renderer/storage，记录到 session）；`DiagnosticTests` 覆盖 marker cap。CUA 验证四项动作真实产出。证据：`out/apple_host/evidence/ui-p4-console-actions/`。
- [x] 慢帧捕获（Godot `slow_frame_threshold_ms = 20`）：`SlowFrameCapture` 状态机 + `armSlowFrameCapture()`，tick 的 host work 超阈值时记录 `slowFrameCaptured` 并解除武装；控制台新增按钮；`DiagnosticTests` 覆盖状态机。CUA 验证真实捕获 `20.17 ms`。证据：`out/apple_host/evidence/ui-p4-slow-frame/`。

## P4实施记录：场景测试入口

- [x] 高级区去掉「尚未迁移」占位，改为真实控件：场景选择器（首页/设置/游戏详情/视频库/视频播放器/游戏界面）+ 说明 + 进入场景；处于场景测试模式时按钮变为退出场景测试。
- [x] `SceneTestStore` 用 Godot 的键 `aether_kiri/scene_test` 持久化；进入即导航并显示顶部「场景测试模式」横幅，重启后重新进入，退出清除键并返回库。
- [x] 与 Godot 的差异：不镜像独立的默认/加载/启动状态选择器（加载态为瞬态）；视频播放器场景打开库里第一个视频。
- [x] 测试 `SceneTestTests`（Godot 键、往返、清除、未知值降级）；Debug 构建通过；CUA 验证进入 + 横幅、重启仍进入、退出清除。证据：`out/apple_host/evidence/ui-p4-scene-test/`。

## P5a实施记录：画面增强（对比度自适应锐化）

- [x] 结论：Godot 增强实现位于私有 RenderingDevice provider（`FrameEffectProvider` 依赖 RenderingDevice/RID），Metal 路径无法复用，必须逐个算法移植并做参考对照；本轮先交付一个完整可验证的算法。
- [x] 实现对比度自适应锐化：五抽头局部对比度加权拉普拉斯，增量限制在局部对比幅度内避免光晕；CPU 参考与 Metal shader 同公式，逐像素对照最大差 ≤2。
- [x] `HostSettings` schema v8 新增 `frameEnhancement`（off/adaptive_sharpen；未移植的 Godot 算法 id 加载归一、保存拒绝）与 `frameEnhancementAmount`（0–1、0.05 步进）；渲染页新增 Godot 同名「画面增强」与「锐化强度」，并写明 Anime4K/FSR1/RAVU/CuNNy/NNEDI3/FXAA 尚未移植。
- [x] Metal 在输出缩放后执行同尺寸修复 pass，资源按 frame revision 管理；分配或 pass 失败保留原始画面并记录原因；能力随原生 Metal 呈现器可用性上报（无 Metal 时显示 Godot 不可用说明）。
- [x] smoke 工具新增 `--frame-enhancement`/`--enhancement-amount`；增强开启时把引擎/呈现 RGB 对比从“必须一致”改为“必须有界地不同（≤160）”，并在 result.json 记录。
- [x] `python3 tools/apple_host_settings_tests.py` 通过（15 组）：核函数 identity/对比度自适应/增量限幅/alpha 保留/平坦区无操作、Metal 与 CPU 参考一致、关闭恢复原始帧、schema v8 迁移与校验。
- [x] Debug 构建通过；真实 30 秒 Metal direct smoke：关闭时引擎/呈现 RGB max diff=0/0/0，开启（0.5）时 121/123/123（呈现被锐化、引擎帧未变），两次都通过启动/输入/截图/退出与 lease 检查。CUA 验证渲染页「画面增强」只有 关闭/对比度自适应锐化 两项、选择后出现 50% 强度滑杆、保存写入 v8 偏好，真实会话日志 `frame enhancement adaptive_sharpen amount=0.50`。证据：`out/apple_host/evidence/ui-p5a-off/`、`ui-p5a-on/`、`ui-p5a-cua/`。

## P5b实施记录：FSR1 RCAS + EASU（Godot 算法逐个移植）

- [x] 结论：Godot 算法集中，FSR1 的 RCAS 与 EASU 都有公开 MIT 参考（`ffx-fsr/ffx_fsr1.h`）且可独立验证，作为 P5b 先移植；Anime4K/RAVU/CuNNy/NNEDI3/FXAA 需要更大的实现与许可评估，暂不开放。
- [x] 实现 `FrameEnhancementKernel.fsr1Rcas` 与 Metal `rcas_fragment`：忠实照搬参考的环最小值/最大值、`hitMin`/`hitMax`、逐通道 lobe 与 `[−0.1875, 0]` 限制、`(lobe·ring+e)/(4·lobe+1)` 解析；全黑/全白邻域的 0 分母在 CPU 与 GPU 两侧显式钳为 0，避免 NaN；`FSR_RCAS_DENOISE` 与中精度倒数未启用。
- [x] `FrameEnhancement` 新增 `fsr1_rcas`（顺序 off → adaptive_sharpen → fsr1_rcas）；渲染页选择器由 `allCases` 驱动自动多出该算法，说明文案改为“当前开放已验证的自适应锐化与 FSR1 RCAS”。许可全文写入 `THIRD_PARTY_LICENSES.md`。
- [x] 修复真实缓存缺陷：增强 scratch 纹理原先只按 `frameRevision` 缓存，切换算法/强度而源帧不变时会复用上一算法结果；缓存键加入算法与强度（`enhancedConfig`），`clear()` 一并重置。测试用“同一帧上先跑自适应再跑 RCAS”回归该缺陷。
- [x] `python3 tools/apple_host_settings_tests.py` 通过：RCAS identity/对比/alpha/黑白色有限性、Metal 与 CPU 参考一致（≤2）、缓存键回归、schema v8 往返 `fsr1_rcas` 且仍拒绝 `fsr1_easu`。
- [x] Debug 构建通过；真实 30 秒 KAG3 Metal direct smoke（`--frame-enhancement fsr1_rcas --enhancement-amount 0.5`）与 30 秒软件回归 smoke 均通过；RCAS smoke 的引擎/呈现 RGB max diff=44/14/14（有界、非零），日志含 `frame enhancement fsr1_rcas amount=0.50`。证据：`out/apple_host/evidence/ui-p5b-rcas/`、`ui-p5b-software/`。
- [x] CUA 验证渲染页「画面增强」只有 关闭/对比度自适应锐化/FSR1 RCAS 三项、选择后出现 50% 强度滑杆、保存写入 v8 偏好；随后经真实产品路径（游戏库 → 开始游玩）启动 KAG3，Diagnostics 日志出现 `frame enhancement fsr1_rcas amount=0.50`。证据：`out/apple_host/evidence/ui-p5b-cua/`。

- [x] FSR1 EASU：`FrameEnhancementKernel.fsr1Easu` 与 Metal `easu_fragment` 移植 `FsrEasuCon`/`FsrEasuSetF`/`FsrEasuTapF`/`FsrEasuF`；硬件 `gather4` 用四次钳位点采样模拟、近似 `rcp`/`rsqrt` 换精确值，CPU 与 GPU 逐像素一致（≤2）。EASU 自己完成输出放大（`scalesOutput`），由输出 pass 承担；`outputConfig` 缓存键加入采样/增强算法。渲染页选择器多出「FSR1 EASU」，文案改为“当前开放已验证的自适应锐化与 FSR1 EASU/RCAS”。
- [x] EASU 验证：Debug 构建通过；30 秒 KAG3 Metal direct smoke（`--frame-enhancement fsr1_easu`）通过（放大输出 1440x1080 视觉正确，源尺寸 parity 捕获因 EASU 1:1 锐化核而有大差异，smoke 对放大类增强只要求非零效果）。证据：`out/apple_host/evidence/ui-p5b-easu/`。

## P5b实施记录：增强 kind/预设/自定义链

- [x] `HostSettings` schema v9：用 `frameEnhancementKind`（off/preset/custom）、`frameEnhancementPreset`、`frameEnhancementChain` 替换 v8 的单一 `frameEnhancement`；v8→一步自定义链、v7→off 迁移；`enhancementSteps` 解析最终链。加载不改写原文件。
- [x] 预设：先开放可组合的「均衡清晰（FSR1）」= EASU→RCAS（Godot `fsr1`）；需要未移植算法的预设不列出。
- [x] 自定义链编辑器：有序步骤行（步骤 N · 算法 + 说明）、每步算法选择、移除按钮、＋ 添加算法（上限 32）；只列已验证算法，EASU 只允许作为第一步。
- [x] 渲染：`MetalFramePresenter.enhancementChain` 把链首缩放步（EASU）作为输出 pass，其余在同尺寸 ping-pong scratch 上按序执行；缓存键含链/强度/采样算法。单算法链与旧行为一致。
- [x] 测试：`FrameEnhancementTests` 覆盖 v8→v9 迁移、预设解析、链往返、非法链拒绝、两步链与 CPU 组合一致；Debug 构建通过；30 秒 KAG3 Metal direct smoke 通过。
- [x] CUA：kind/预设/自定义 UI、保存 v9、真实启动日志 `frame enhancement fsr1_easu,fsr1_rcas amount=0.50`。证据：`out/apple_host/evidence/ui-p5b-chain-cua/`。
- [x] 附带修复：内置 Demo 条目 `directory` 改为 `id.uuidString`（原先导致含 Demo 的库重载报索引无法读取），`BuiltinDemoTests` 增加 save/load 回归。

## P5b实施记录：双三次/Lanczos 链步骤与预设

- [x] `FrameEnhancement` 新增 `bicubic`/`lanczos`（`scalesOutput` + `samplingAlgorithm` 映射）；链的缩放步骤覆盖 `upscaleAlgorithm`，符合 Godot 链语义。
- [x] 预设列表扩到 3 项：均衡清晰（FSR1）、自然柔和（双三次）、锐利细节（Lanczos）；自定义链首步可选 EASU/双三次/Lanczos。
- [x] `MetalFramePresenter` 用链的缩放步骤做输出 pass（EASU 或采样），其余步骤仍按序同尺寸执行；`scalingConfig` 含“有效采样 + 缩放步骤”。
- [x] 测试：`allCases`/预设/采样映射断言、lanczos+RCAS 链往返、非法链（缩放步骤非首位/两个缩放步骤）拒绝、bicubic+RCAS 与单独 bicubic、单独 lanczos 都不同；Debug 构建通过；30 秒 KAG3 Metal smoke 通过。
- [x] CUA：预设列表三项、保存 `preset=bicubic`、真实启动日志 `frame enhancement bicubic,fsr1_rcas amount=0.50`。证据：`out/apple_host/evidence/ui-p5b-sampling-cua/`。

下一切片：P5b 其余部分（评估 Anime4K/RAVU/CuNNy/NNEDI3/FXAA 的许可与负载并逐个移植，逐步放开对应预设）；视频库/播放器暂停维护。

## P6实施记录：首次使用协议门（macOS 首片）

- [x] `LegalAgreement.version = "2026-07-27.4"`（对齐 Godot 常量）；`LegalAcceptanceStore` 把 `{version, acceptedAt}` 写到库根 `legal-acceptance.json`，与可撤销的设置草稿分开；缺失/损坏/版本不符一律视为未同意并重新弹门。
- [x] 首次启动弹出不可关闭的 `LegalAgreementView`：标题 + 首用说明 + 打包好的五语言协议正文（`privacy_disclaimer_*.txt`）+ 拒绝 / 同意并继续。同意写入版本与时间戳；拒绝在 macOS 退出应用（对齐 Godot 桌面行为）。
- [x] debug-only `AETHER_HOST_BYPASS_LEGAL_GATE=1` 供非交互入口绕过；smoke/selftest/profile/cold-start/texture-lifecycle/runtime-movie 工具已设置。
- [x] `python3 tools/apple_host_settings_tests.py` 通过：新增 `LegalAcceptanceTests`（版本门、持久化、损坏文件、过期版本、debug 绕过）；Debug 构建通过。
- [x] CUA 验证：全新库弹门并显示五语言协议正文、同意后写 `legal-acceptance.json`、重开不再弹门。证据：`out/apple_host/evidence/ui-p6-legal-cua/`；30 秒软件回归 smoke 通过（工具带 bypass）。证据：`out/apple_host/evidence/ui-p6-legal-smoke/`。

## P6实施记录：内置 Demo

- [x] `BuiltinDemo` 对齐 `scripts/builtin_demo.gd`：`id="aetherkiri-kag3-demo"`、`version=4`，把打包的 `data.xp3` 复制到 `<库根>/builtin_games/aetherkiri-demo/`，状态写 `<库根>/aetherkiri_builtin_demo.cfg`。
- [x] 启动时幂等 reconcile 入库（保留既有条目的游玩时长/封面/标题）；删除写 `removed=true` 并删安装目录，重启不再恢复。库条目新增只读 `builtinId`/`builtinVersion`（旧索引兼容）。
- [x] 详情页对内置 Demo 显示「内置 Demo」徽标与「删除内置 Demo」（而非「从游戏库移除」），确认框写明删除后不恢复；五语言文案。
- [x] `data.xp3` 随 App 打包（`project.yml`），与 Godot 共用同一资源；非交互入口走 bypass。
- [x] 测试：`BuiltinDemoTests`（安装、幂等 reconcile、删除记忆、缺失资源降级）全通过；Debug 构建通过。
- [x] CUA：首启安装 17MB Demo、详情页徽标/删除、确认删除后库为空且重启不恢复。证据：`out/apple_host/evidence/ui-p6-demo-cua/`。

## P6实施记录：VNDB 在线封面

- [x] 详情页新增「搜索在线封面」按钮（显式触发，不做后台自动扫描）；`VNDBCoverSearch` 向 `https://api.vndb.org/kana/vn` POST `{"filters":["search","=",标题],"fields":"id,title,image.url,image.thumbnail"}`，请求体只含标题，不含本机路径/存档。
- [x] 候选列表（缩略图 + 标题 + id）；选择后下载封面缓存到库根 `Covers/vndb-<id>.jpg` 并 `setCover` 指向；失败保留当前封面并显示原因。`CoverSearchProviding`/`CoverImageLoading` 便于测试注入。
- [x] 测试：`CoverSearchTests`（请求形状/只发标题/空标题拒绝、响应解析丢弃无图行、注入式 search/apply 缓存与索引、失败保留）全通过；Debug 构建通过。
- [x] CUA：真实 VNDB 搜索「Aether Demo」→ 选候选 → 缓存 `Covers/vndb-v21873.jpg` → 详情页出现清除封面。证据：`out/apple_host/evidence/ui-p6-vndb-cua/`。

下一切片：P6 其余（渠道额外声明）与 P5b 其余算法/预设链并行评估；视频库/播放器暂停维护。
