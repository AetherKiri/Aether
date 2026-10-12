# Aether Apple Host (SwiftUI + Metal)

Apple 原生宿主，macOS 先行，直接驱动 `engine_api`。
默认使用软件渲染与 Metal 呈现；设置 `AETHER_HOST_RENDERER=metal` 可启用
P2 原生 Metal 绘制桥。ONS 当前仍走软件帧兜底，G1 按用户要求暂缓，M2 游戏库目录导入与启动流程已接入。

- 设计：`doc/apple_host.md`
- 宿主职责：`doc/apple_host_seam_inventory.md`
- 进度：`doc/apple_host_progress.md`
- Metal 实施与验收：`doc/apple_host_metal_plan.md`

## 构建（仓库根目录）

先按 spec 构建 CMake `aether_apple_host_core` 与 `engine_api`，再运行：

```bash
(cd apps/apple_host && xcodegen generate)
xcodebuild -project apps/apple_host/AetherHost.xcodeproj -scheme AetherHost \
  -configuration Debug -derivedDataPath out/apple_host/derived build
```

## 验证

```bash
mkdir -p out/apple_host
xcrun swiftc apps/apple_host/AetherHost/InputMapping.swift \
  apps/apple_host/AetherHost/GameInputView.swift \
  apps/apple_host/Tests/InputTests.swift -o out/apple_host/input-tests
out/apple_host/input-tests

xcrun swiftc apps/apple_host/AetherHost/MetalFramePresenter.swift \
  apps/apple_host/Tests/MetalPresentationTests.swift \
  -o out/apple_host/metal-presentation-tests
out/apple_host/metal-presentation-tests

# Metal 绘制桥：精确混合、批处理、三角形、回读和 IOSurface 生命周期。
xcrun clang++ -fobjc-arc -std=c++17 -I abi/include \
  -framework Foundation -framework Metal -framework CoreVideo \
  apps/apple_host/HostKit/MetalBridge.mm apps/apple_host/Tests/MetalBridgeTests.mm \
  -o out/apple_host/metal-bridge-tests
out/apple_host/metal-bridge-tests
# 1080p 绘制桥基准（不包含 engine tick/MTKView，不构成 G1 性能验收）：
out/apple_host/metal-bridge-tests --benchmark
out/apple_host/metal-bridge-tests --readback-benchmark
out/apple_host/metal-bridge-tests --batched-readback-benchmark
out/apple_host/metal-bridge-tests --snapshot-benchmark
# Host-level sync/async snapshots, direct scheduling, no screenshots:
python3 tools/apple_host_profile.py demos/aetherkiri-kag3/data --duration 30 --compare-snapshots
# result.json 的 native_cpu_stages 分列取帧接口与快照 CPU 平均/最大耗时。
# 取帧包含 ABI 分发和运行时查询；包含启动/预热，异步快照不含 GPU 完成等待。
# 仅 AETHER_HOST_PROFILE=1 采集阶段时钟，普通运行不增加计时调用。
# 离屏 uncapped benchmark：绕过 CAMetalLayer/60Hz，只比较固定 1/60 engine tick 的提交吞吐；
# `--wait-gpu` 改为每帧等待 1920x1080 offscreen command 完成，用于端到端 completion 对照。
python3 tools/apple_host_profile.py demos/aetherkiri-kag3/data --duration 30 --offscreen
python3 tools/apple_host_profile.py demos/aetherkiri-kag3/data --duration 30 --offscreen --wait-gpu
# 排查关闭后的残留纹理：按需记录分配栈，退役时输出 image+offset 便于 atos 符号化。
# 会增加追踪开销，不用于性能对照；默认不采集栈。
AETHER_HOST_TRACE_TEXTURES=1 python3 tools/apple_host_smoke.py --game kag3 \
  --renderer metal --snapshots async --duration 30
# 原创图层对象图：普通关闭与先失效图层/窗口两轮对照。
# 显式失效必须无残留；普通关闭残留计数用于定位，不作为完整游戏验收。
python3 tools/apple_host_texture_lifecycle.py
python3 tools/apple_host_texture_lifecycle.py --multi-window
python3 tools/generate_apple_metal_shaders.py --check

# KAG3 + ONS 并行，各运行 310 秒，截图验证输入推进、GPU RGB 对比及干净退出。
python3 tools/apple_host_smoke.py
# 快速冒烟（不构成五分钟 G0 验收）：
python3 tools/apple_host_smoke.py --duration 30
# 引擎缩放绘制（重采样）路径的原创夹具；输入驱动重绘，软件与 Metal 两次
# 运行可在同一秒直接对比（P2/P0 同刻差值应为 0）：
python3 tools/apple_host_smoke.py --game-path tests/fixtures/apple_host_stretch \
  --renderer metal --duration 30
# P2 原生 Metal 绘制（ONS 验证软件兜底）：
python3 tools/apple_host_smoke.py --renderer metal
# 异步呈现快照五分钟回归，同时要求关闭时提交/完成计数一致、无在途快照：
python3 tools/apple_host_smoke.py --game kag3 --renderer metal --snapshots async --duration 300
# smoke 默认显式选择 sync，避免继承实验环境变量导致验证模式不明确。
# 每个游戏目录输出 result.json，记录模式、退出码、异步关闭计数及失败原因。
# 记录宿主 tick + 纹理获取耗时；不含独立 MTKView 呈现：
python3 tools/apple_host_smoke.py --duration 30 --renderer metal --profile
# 指定额外自检项目（传其 data 目录）：
python3 tools/apple_host_smoke.py --duration 30 --renderer metal --require-native \
  --game-path /absolute/path/aetherkiri-test/data
# 自检项目的八种交互状态：软件/Metal × 640×480/合成1080p逐像素比较。
# 使用副本并禁用重复 BGM timer，仅验证绘制；输出必须是新目录。
python3 tools/apple_host_selftest.py /absolute/path/aetherkiri-test \
  --output out/apple_host/evidence/selftest-parity
# Image 呈现对照：
python3 tools/apple_host_smoke.py --duration 30 --presentation image
```

自定义游戏可能在普通场景发布原生纹理，在开场视频发布 CPU 帧；
`--require-native` 检查原生纹理可用性，不要求整段运行都保持原生。

环境变量见 spec。新增 `AETHER_HOST_PRESENTATION=image` 强制 Image 对照，
默认使用 Metal（可用时）；`AETHER_HOST_DEFAULT_FONT` 指定 ONS 字体。
`AETHER_HOST_CAPTURE_AFTER` 同时输出 engine PNG 与 Metal PNG，并记录原尺寸
RGB 最大差值。这是呈现一致性检查；独立软件/原生绘制对比用
`xcrun swift tools/apple_host_compare.swift 软件截图 原生截图`。1080p 完整帧性能待验收。

设置 `AETHER_HOST_METAL_DEBUG=1` 会给共享 Metal queue、present command buffer
和 frame render encoder 加稳定 label，便于 Xcode GPU Frame Capture 与 Instruments
按宿主阶段筛选；默认关闭，不改变提交路径。

### 呈现性能采样

`--profile` 同时记录宿主工作与 tick-to-GPU-completion。后者关联实际提交的
MTKView drawable，包含 SwiftUI 调度、软件上传/原生纹理获取、drawable 获取、
GPU 排队与呈现命令完成；不包含显示器扫描输出。SwiftUI 合并而没有提交的 tick
不算样本，重绘不会重复采样同一 tick。预热 60 tick，最多 10000 样本。
`aetherhost-presentation.csv` 保存 tick、实际 drawable 尺寸、总耗时和 GPU 耗时。

```bash
python3 tools/apple_host_smoke.py --game-path <1080p自检目录> \
  --renderer metal --require-native --duration 30 --profile --drawable-1080p
```

`--profile` 与 `--snapshots direct` 会带上 `AETHER_HOST_ACTIVATE=1`：宿主窗口被完全
遮挡时不会申请 drawable（`nextDrawable` 的 1 秒超时会卡住主线程），因此需要真实
drawable 提交的基准必须有可见窗口。
如果窗口始终无法出帧，工具会直接报错而不是产出空 CSV。手动运行时可用同一环境变量
让测试宿主自行激活并前置窗口。

`--drawable-1080p` 固定实际 Metal 输出为 1920×1080；游戏画面和输入坐标仍遵循
游戏尺寸。要测试完整 1080p 绘制工作，源游戏也必须为 1920×1080。
冒烟检查至少 60 个完成样本、tick 唯一、耗时有效以及输出尺寸正确，
不把运行成功自动当作 16.6ms 性能通过。截图回读会扰动 GPU 队列，正式基准需另行隔离。

呈现门控：窗口无窗口/隐藏/最小化/被遮挡或 drawable 尺寸为 0 时，宿主跳过本次
drawable 申请并记录 `presentation paused/resumed`；被跳过的 draw 不计入 profile 样本。
窗口恢复可见后由下一个 tick 继续出帧，游戏逻辑（tick/音频）不受影响。

### 帧调度与 FPS

宿主不再使用固定 60 Hz Timer 与固定 1/60 tick。`HostFrameClock` 优先使用
CVDisplayLink 跟随显示刷新；无活动显示（或显式 `AETHER_HOST_PACE=timer`）时退回
RunLoop Timer，回调在主线程前合并，避免主线程繁忙时回放积压。`FrameScheduler`
决定每次回调是否推进引擎：关闭 FPS 限制时每个回调一次 tick；启用限制时按目标间隔
放行，每次回调最多一次 tick，超出部分记 `dropped_catch_up` 而不追赶。目标为
60/80/90/120/144，默认关闭、目标 80；高于当前刷新率的目标改用 Timer 源。

每次 tick 传入真实 elapsed 毫秒（带亚毫秒余量），单次上限 100 ms；失焦、隐藏、
最小化、遮挡和系统休眠通过 AppKit/NSWorkspace 通知重置调度时钟并记录
`host lifecycle ...`，退出时停止帧时钟并解绑观察者。tick/render/presentation
分开统计并写入日志与诊断：`tick` 是宿主 `engine_tick` 调用数，`render` 是引擎报告
实际出帧的 tick 数，`presentation` 是 Metal drawable 提交或图像发布数，三者都不等于
屏幕扫描FPS。设置页保存的 FPS 偏好下次启动生效；`AETHER_HOST_FPS_LIMIT=0|60|80|90|120|144`
与 `AETHER_HOST_PACE=auto|display|timer` 只作 smoke/benchmark 覆盖。

默认采用直接呈现：帧回调同步执行一次 tick、上传/获取纹理并提交 MTKView 绘制，
不为每个 tick 额外排队 Task，也不依赖 SwiftUI 更新来提交画面。布局和游戏输入坐标
仍由 SwiftUI/AppKit 管理；窗口缩放会触发独立重绘。`AETHER_HOST_SCHEDULING=deferred`
保留 SwiftUI 延后呈现作对照。

```bash
python3 tools/apple_host_smoke.py --game kag3 --renderer metal --snapshots direct \
  --duration 30 --pace timer --fps-limit 80 --lifecycle 4:on,7:off
```

smoke 会解析 `pacing stats:` 并写进 `result.json`：tick/render/presentation 计数、
目标速率上限、`dropped_catch_up`、调度重置次数和 `max_delta_ms`。`--lifecycle`
驱动与 AppKit 通知相同的生命周期处理，用于验证暂停/恢复不产生追赶 tick。

```bash
python3 tools/apple_host_profile.py <1080p自检目录> --duration 60
```

该工具顺序运行 deferred/direct，关闭截图与测试输入，检查启动、退出、真实
1080p drawable、唯一 tick、无 GPU 错误与零回读，并记录未采样 tick 数。
CSV 新增 tick 到 draw、drawable 获取和命令编码耗时，辅助定位慢帧。
未采样 tick 包含合并/无 drawable/未完成等情况，不直接等同于显示器掉帧。
调度已按显示刷新或目标速率运行；这不宣称通过 G1，也不把提交吞吐当作玩家帧率。

## M2 游戏库

普通启动显示游戏库。点击「导入游戏」选择包含游戏入口的文件夹或 ZIP，复制完成后
选择「开始游玩」。返回前应在游戏内保存；确认返回会停止游戏。
默认库在 `~/Library/Application Support/Aether/Games`，同级 `library.json`
保存条目与最近游玩时间；源文件夹保留，运行日志和存档落在副本。
支持 KiriKiri/ONS 文件夹（及含 data 的上一级目录），也支持 ZIP 解压后识别入口。
重复导入使用现有副本，损坏索引不覆盖，复制/索引写入失败回滚新副本。

快捷键：⌘O 导入、⌘R 启动、⌘L 返回、⌘, 设置。
设置支持五语言、软件/Metal 绘制、画布/输出分辨率和 nearest/linear/bicubic/lanczos 采样；渲染变更下次启动生效。
默认字体和许可证随应用打包，普通启动不需要环境变量。
G1 按用户要求暂缓，保留软件默认与 Metal 测试选项。

开发工具页使用 `AETHER_HOST_DEVELOPER=1`；AUTORUN 也自动进入开发页，
原有 smoke/selftest 工具无需修改。`AETHER_HOST_LIBRARY_ROOT=<目录>` 可将库和
偏好键隔离到开发测试范围；产品使用默认目录。

```bash
xcrun swiftc apps/apple_host/AetherHost/GameLibrary.swift \
  apps/apple_host/AetherHost/GameArchive.swift \
  apps/apple_host/Tests/GameLibraryTests.swift \
  -import-objc-header apps/apple_host/HostKit/ArchiveReader.h -larchive \
  -o out/apple_host/game-library-tests
out/apple_host/game-library-tests
```

M2 CUA 验证流程及范围见 `doc/apple_host_progress.md`。平台标准菜单语言由 macOS
选择；应用页面及自定义菜单跟随设置。

「文件」菜单提供导入、外部目录和刷新（⌘R）；「显示」菜单提供游戏库（⌘1）、视频库
（⌘2）、主页（⌘3）和全屏切换（⌘⌃F）。视频库索引保存在 `video-library.json`，支持
导入、重新打开、移除并清理对应播放进度，并按视频路径记住字幕轨道选择。运行游戏时「游戏」菜单提供虚拟按键、文字输入、
运行日志、在访达中显示、重新启动、返回游戏库和诊断导出；重启与返回都会先提示保存。
运行游戏前的窗口全屏状态会在返回游戏库时恢复。游戏运行时导航、设置和导入菜单会按会话状态禁用。

窗口内常驻游戏库/视频库/主页切换和刷新按钮；游戏页提供操作菜单，包含日志、目录、重启和诊断导出。原生菜单与快捷键保留为辅助入口。主页（⌘3）迁移 Godot 的游玩统计：三层进度环与累计时长、作品总数/已游玩/本周活跃/平均时长、近七天足迹、继续阅读、时长排行与最近游玩。累计时长按成功启动的运行会话记录（`playDurationSeconds`，单次上限一天），失败启动与启动中的会话不计时，返回、重启与退出各提交一次；详情页显示每款游戏的游玩时长。帮助菜单提供加入 QQ 交流群入口。

详情页和列表右键菜单支持重命名、从库移除。名称保存到索引，不改变目录或存档。
移除只删除列表记录，保留文件；管理副本仍在 Games/<UUID>，可通过「添加外部游戏目录」
选择保留的副本恢复游玩，也可重新复制导入。重新导入原始目录不会自动找回保留副本的存档。

详情页显示只读的「运行时类型」与「启动入口」：标记识别沿用 Godot `GameMetadata`
（KiriKiri 的 XP3/startup、ONScripter 脚本、Siglus 的 gameexe/scene、Minori 的
scr.paz+sys.paz+可执行文件、校验过文件头的 RFVP `.hcb`），状态来自真实
`engine_probe_runtime_provider`。Siglus 与校验过的 `.hcb` 目录现在也能导入。
启动入口不提供覆盖——`engine_open_game` 的 `startup_script` 参数在当前运行时被忽略；
RFVP 文本编码同样等到链接 RFVP provider 后再提供，当前显示原因说明。

渲染设置提供 Godot 同名的「画面增强」，并采用 Godot 的 kind 模型：关闭 / 预设 / 自定义。
当前开放三个**有 CPU 参考并逐像素对照**的算法：**对比度自适应锐化**（五抽头局部对比度
加权拉普拉斯，增量限制在局部对比幅度内以避免光晕）、**FSR1 RCAS**（AMD FidelityFX
Super Resolution 1 的 robust contrast adaptive sharpening）与 **FSR1 EASU**（edge-adaptive
上采样），后两者忠实移植
`ffx-fsr/ffx_fsr1.h` 的 `FsrRcasF` 与 `FsrEasuF`（MIT，全文见
`THIRD_PARTY_LICENSES.md`；EASU 的硬件 `gather4` 用四次钳位点采样等价模拟）。RCAS 与
自适应锐化是输出缩放后的同尺寸修复（强度 0–1 按 0.05 步进）；EASU 自己完成到输出
分辨率的放大。预设开放可组合的 均衡清晰（FSR1）=EASU→RCAS、自然柔和（双三次）=bicubic→RCAS、
锐利细节（Lanczos）=lanczos→RCAS；自定义模式提供有序算法链编辑器（每步算法选择、添加/移除、
上限 32，缩放步骤 EASU/双三次/Lanczos 只允许作为第一步），其余步骤按顺序在同尺寸 scratch 上执行。
分配或 pass 失败会保留原始画面。Godot 的 Anime4K/RAVU/CuNNy/NNEDI3/
FXAA 与依赖它们的预设位于私有 RenderingDevice provider，需要逐个移植到 Metal 并做参考
对照，当前在选择器与设置页说明中明确未开放。smoke 可用 `--frame-enhancement
adaptive_sharpen|fsr1_rcas|fsr1_easu --enhancement-amount 0.5` 做基准覆盖（仅测试入口，不写入偏好）。
首次启动会依次显示 Godot 同版本的两份文档门：先隐私/免责协议（`2026-07-27.4`，
`privacy_disclaimer_*.txt`），再 App Store 额外声明（`2026-08-04`，
`ios_app_store_statement_*.txt`），正文均取自打包的五语言资源，按钮为
拒绝 / 同意并继续；同意按文档写入库根 `legal-acceptance.json` 的
`{privacy, statement}` 条目（与可撤销的设置草稿分开，旧单文档文件自动迁移到
privacy），两份都同意后才进库。拒绝在 macOS 退出应用。非交互测试/基准入口用
debug-only 的 `AETHER_HOST_BYPASS_LEGAL_GATE=1` 绕过（对应 Godot 的
`AETHERKIRI_BYPASS_LEGAL_GATE`）。
首次运行还会把打包的多语言 Demo（`data.xp3`，与 Godot 共用同一份
`builtin_demos/aetherkiri-kag3` 资源）安装进库：复制到
`<库根>/builtin_games/aetherkiri-demo/` 并在 `aetherkiri_builtin_demo.cfg` 记录状态。
详情页显示「内置 Demo」徽标与「删除内置 Demo」，删除会清除安装目录并记住，重启不再恢复。
详情页的「搜索在线封面」是**显式**的联网动作：只把游戏标题发给 VNDB
（`api.vndb.org/kana/vn`），不发送本机路径或存档；候选封面下载后缓存到库根
`Covers/vndb-<id>.jpg` 并写入封面路径，失败时保留当前封面。宿主不做后台自动查询。
「添加外部游戏目录」直接引用所选目录（支持 data 包装目录），不复制；存档和运行文件写入引用目录。
同模式重复添加沿用条目，复制与外部引用可分别管理。外部目录移动或丢失时需重新添加。
旧索引默认按管理副本读取，损坏索引仍保留并禁止修改。
当前 macOS 构建未启用 App Sandbox；外部引用尚未实现 security-scoped bookmark。
ZIP 导入复用 macOS 系统 libarchive，不依赖 Homebrew 或外部解压进程。支持平铺或嵌套最多 8 层的
单个游戏入口、data 包装目录及 ZIP64；__MACOSX 不参与入口识别。多个入口拒绝自动选择。
限制解压后总文件字节 32 GiB、10 万条目；拒绝链接、绝对/越界路径、加密、重复或大小写/Unicode 冲突路径。
ZIP 源文件保留；解压到私有临时目录，再复制入库，成功/失败均清理临时目录，索引保存失败回滚新副本。
按源 ZIP 路径去重，重复导入保留副本及存档；源 ZIP 更新不会自动替换已导入游戏。
文件名编码支持范围取决于系统 libarchive 的转换能力，无法转换时拒绝；RAR/7z、密码输入、
导入取消/字节进度与磁盘清理仍待扩展。大包导入需要临时解压及最终副本的空间。

```bash
python3 tools/apple_host_archive_test.py
```

此工具生成原创 ZIP 样本并运行压缩包导入与游戏库回归，证据位于 `out/apple_host/evidence/m2-archive/`。


## M3 诊断日志

设置或「游戏 → 导出诊断日志」（⌘⇧D）可保存本地文本报告。
宿主/引擎启动日志与最后会话信息保留在库同级 `Diagnostics/`，退出后仍可导出。
每个宿主日志最多 1 MiB，保留当前与上一轮；报告另附最后游戏目录两种已知
引擎日志的尾部（各最多 1 MiB），不会打包游戏文件和存档。
报告注明缺失、文件时间与截断大小，日志可能含较早会话、路径或引擎打印的文本。
游戏运行中「游戏」菜单的「诊断控制台」会在右侧停靠一个可停靠面板（对齐 Godot 的调试
控制台）：概览（renderer/presentation/frame/output/fpsLimit/tick/回退）、性能（tick/render/
presentation 速率、frame ms、pacing、会话计数与缓存，均注明不等于屏幕扫描 FPS）、输入
（控制模式/指针/IME/全屏/影片）、插件（加载模式 + 当前游戏运行时/入口/信号 + 真实
`engine_probe_runtime_provider` 结果 + 翻译可用性）、日志（暂停 + 过滤）；底部可复制摘要
或导出诊断日志。动作区还对齐 Godot 的调试控制台：问题标记（类型取自 `MARKER_TYPES`，
上限 8，与 `DiagnosticSession.MAX_MARKERS` 一致）、慢帧捕获（武装后记录下一个 host work
超过 20 ms 的帧，阈值同 Godot `slow_frame_threshold_ms`）、保存快照（JSON，含完整性能明细）、
截图（PNG）与自检（session/engine/renderer/storage）；这些文件写入库同级的
`Diagnostics/`。面板打开时即使覆盖层关闭也会刷新性能快照。
「高级开发工具」还提供**场景测试**（对齐 Godot `settings.scene_test`）：选择首页/设置/
游戏详情/视频库/视频播放器/游戏界面后「进入场景」，顶部显示「场景测试模式」横幅；所选
场景持久化在 Godot 的键 `aether_kiri/scene_test`，重启仍会进入，直到「退出场景测试」。
Godot 的独立默认/加载/启动状态选择器未镜像（加载态在此为瞬态）。
运行日志显示开关只控制界面。启动失败记录具体错误，关闭会话后可启动其他游戏。

「设置 → 诊断」提供 Godot 同名的诊断模式与调试悬浮信息两档：

- 诊断模式（Debug 默认 `基础`，Release 默认 `关闭`）沿用 Godot 目录。Apple 能执行的
  部分为：`输入/插件/完整` 在启动前下发 `input_trace`/`plugin_trace`/`trace_log`，
  `基础/渲染` 采集宿主帧工作，`输入/完整` 记录输入事件，`系统/完整` 在导出里写入
  backend/内存快照。`存储/脚本/音频/视频` 在本构建还没有采样源，因此不出现在选择器，
  设置页与日志会说明原因（不伪造采样）。trace 类选项下次启动生效。
- 调试悬浮信息 `关闭/简要/详细` 保存后立即作用于运行中的游戏：显示后端/API/纹理/尺寸、
  `tick`（宿主 `engine_tick` 次数）、`render`（引擎实际出帧的 tick 数）、
  `presentation`（drawable 提交或图像发布）三个分开的速率与口径说明、帧工作耗时、
  调度模式、fallback/错误、进程内存（App/Peak）与系统空闲/引擎缓存；`详细` 追加
  p50/p95/max、dropped/coalesced/resets、会话计数与缓存明细。GPU 内存估算在本构建
  没有来源，覆盖层明确标注不可用而不是猜测。返回游戏库后覆盖层自动消失。

「设置 → 高级开发工具」提供 Godot 同名的四个**临时**引擎开关：插件调用追踪
（`plugin_trace`）、追踪日志（`trace_log`）、控制台日志文件（`console_log_file`）、
导出 TJS 脚本（`export_scripts`）。它们不写入设置文件、不产生未保存状态、重启自动
关闭；前两个开启后 30 秒由 tick 循环自动关闭，后两个没有时限。已有游戏会话时立即
下发，否则在下次启动游戏时应用（已过期的会在日志中记为 `expired before launch`）。
场景测试入口（重启并跳转到指定界面）尚未迁移，页面保留说明。

游戏内虚拟控制对齐 Godot `game_virtual_controls.gd`：`虚拟按键` 打开时，游戏画面
右上角出现入口按钮，点击开合按键面板；关闭「游戏内控制菜单」等于隐藏整条虚拟控制。
面板按键与「保持 Ctrl」使用「Keyboard 模式按键透明度」（0.2–1.0、0.05 步进），
鼠标模式的指针手柄保持完全不透明，拖动手柄按显示缩放移动游戏指针，「左键点击」
在该位置发送点击；面板内可切换 虚拟鼠标/直接触摸，选择立即写入偏好。桌面始终保留
真实指针输入（Godot mouse 模式会屏蔽画面触摸，属移动端取向，不在 macOS 复刻）。

```bash
xcrun swiftc apps/apple_host/AetherHost/DiagnosticStore.swift \
  apps/apple_host/Tests/DiagnosticStoreTests.swift -o out/apple_host/diagnostic-store-tests
out/apple_host/diagnostic-store-tests
```

此阶段未实现崩溃报告采集、结构化诊断队列全量接入或媒体功能迁移；G1 继续暂缓。


## M3 独立视频与文本字幕

工具栏「打开视频」或 ⌘⇧O 选择本地文件，源文件只读。空格暂停/继续；
播放页支持进度条、±10 秒、倍速、音量、字幕及返回。
同名 UTF-8 SRT/VTT/ASS/SSA 自动载入，也可选择引擎列出的内嵌文本字幕。
文本保留换行与重叠，暂不呈现 ASS 样式/动画/绘图或位图字幕。
游戏与独立媒体互斥，退出/关闭停止解码；进度每 5 秒及控制/关闭时保存，
同一路径重新打开会恢复，片尾则从头播放。记录保存在库同级 `media-progress.json`，
保留最近 200 项；内嵌字幕提取目录在关闭后清理。现阶段视频为 CPU RGBA 基线。

```bash
# 需要现有 Debug 核心库与本机 ffmpeg；只生成测试素材，不下载视频。
python3 tools/apple_host_media_test.py
```

此工具生成短视频并验证字幕、解码、暂停/跳转/倍速、结束重播与进度恢复。
它不验证实际听音或全部视频编码；视频库管理及其它 Minori 平台请求接入仍待推进。


## M3 屏幕按键与文字输入

游戏页「虚拟按键」或设置开关显示回车/空格/Esc/方向/PgUp/PgDn 与保持 Ctrl。
实体键与屏幕键共享按下状态；隐藏、失焦、弹窗及关闭释放按键。
「输入文字」使用原生输入框，先选中游戏内编辑控件再提交；最多 2048 个 Unicode 标量，
跳过 NUL/换行，取消不发送。这是手动兜底入口；游戏内编辑控件的合成输入与插入符同步见下节，
游戏发出的 `text_input` 请求另由平台队列处理。

```bash
xcrun swiftc apps/apple_host/AetherHost/KeyInputState.swift \
  apps/apple_host/Tests/KeyInputStateTests.swift -o out/apple_host/key-input-tests
out/apple_host/key-input-tests
xcrun swiftc apps/apple_host/AetherHost/InputMapping.swift \
  apps/apple_host/AetherHost/GameTextInput.swift \
  apps/apple_host/AetherHost/GameInputView.swift apps/apple_host/Tests/InputTests.swift \
  -o out/apple_host/input-tests
out/apple_host/input-tests
```

可导入原创 `tests/fixtures/apple_host_controls`，通过游戏 HUD 验证 down/up 数量及提交文字。
界面验证证据见 `out/apple_host/evidence/m3-controls/`；G1 继续暂缓。

## M3 游戏内文字输入（IME 与编辑控件同步）

游戏层出现可编辑的 KiriKiri 文本控件（如 KAG 的 `[edit]`）时，宿主轮询
`engine_get_text_input_state`，并在该控件同时发布插入符与接受合成输入
（`attention_point_valid` + `ime_active`）时启用合成输入——判定与 Godot 壳的
`_sync_game_text_input_state` 一致。失焦、隐藏窗口、返回游戏库或关闭会话都会结束合成。

- 画布视图成为 AppKit 的文本输入客户端：合成内容经 `ime_preedit` /
  `ime_preedit_cursor` 选项下发（Siglus 消费该选项；KiriKiri 传统层忽略它，改在提交时
  接收文本），提交文本经 `TEXT_INPUT` 进入游戏。
- 候选窗口跟随游戏插入符：`attention_x/y` 用与指针一致的等比映射换算到视图坐标。
- 合成期间回车/取消/退格/方向键/Home/End/PgUp/PgDn 仍以引擎按键事件下发；未映射的
  命令回退到原始按键路径。未聚焦文本控件时按键路径与改动前完全一致。
- ⌘V 把剪贴板文本作为提交文本送入游戏（Godot 的 macOS 窗口同为文本输入客户端）。
- 宿主只记录状态变化与提交标量数量，不记录输入正文。

```bash
python3 tools/apple_host_ime_test.py
```

该工具运行状态解析、激活判定、合成去重、命令映射与插入符几何测试，并生成「直达输入页」
夹具（复制仓库内 KAG3 demo，把 `first.ks` 跳转到其自带的计算题输入页）。输入框获得焦点时
宿主日志打印 `game text input active`，提交后打印标量数量，离开输入页打印
`game text input inactive`。真实输入法合成（候选窗内容）需在系统输入法下人工确认。


## M3 平台 dialog 弹窗

`dialog` 请求使用现有壳的 URL 表单协议，支持标题/消息、限长输入、是/否及自定义按钮。
响应通过 HostKit 回传 `result=<id>&text=<URI encoded>`。队列顺序呈现，宿主弹窗打开时延后；
待回复暂停游戏输入及额外请求轮询，继续引擎 tick。失败显示实际错误并保留输入可重试，
关闭游戏清空队列；重复或旧回复不发送。自定义按钮只提交游戏提供的编号，编号 0 支持 Escape。

```bash
# --host-abi 需要先完成 Debug 宿主构建；不依赖私有 runtime。
python3 tools/apple_host_dialog_test.py --host-abi
```

工具运行协议/队列与真实 HostKit ABI 错误路径测试，并构建独立 UI fixture。
UI fixture 的 ACK 为测试回调；当前公开核心无法验证私有 provider 的实际请求/成功响应。
界面证据在 `out/apple_host/evidence/m3-dialog/`。通用 `text_input` 已由下节接入；Minori 音频、文字框及其它平台请求仍待迁移。


## M3 Minori 运行时影片

`minori_movie` 六个 TAB 字段指定绝对路径、宽、高、x、y 和可跳过标记。
影片借用正在运行的游戏引擎，按游戏画布坐标覆盖，保留原画布的输入与缩放。
可跳过影片支持点击、回车、空格、Esc；播放期间隔离游戏输入，跳过键的重复与松开不泄漏到游戏。
自然结束/跳过分别回传 `result=complete` / `result=skipped`，先关闭解码器再响应，允许 provider 删除缓存。
错误回传一次 error，关闭游戏不回传完成。这里不保存独立视频的恢复位置。
导入识别公开 Minori profile 的 scr.paz、sys.paz 与四种 EXE 标记，不执行 EXE；实际档案有效性由核心检查。

```bash
# 需要已有 Debug 核心、宿主构建和 ffmpeg。
python3 tools/apple_host_runtime_movie_test.py --run-host
```

工具生成无音轨 AVI，验证真实解码与借用引擎生命周期，再在实际宿主运行结束、跳过和关闭三种情形。
`AETHER_HOST_TEST_RUNTIME_MOVIE` 仅 Debug autorun 使用，注入协议并以明确的测试 ACK 替代真实响应。
测试与界面证据在 `out/apple_host/evidence/m3-runtime-movie-native-host/`，不代表真实 Minori VM 已验收。
完整 Minori 剧情还依赖音频、文字框、选择与存档等请求迁移；G1 继续暂缓。


## M3 通用 text_input 请求

请求为标题、提示、初始文字三个 TAB 字段，最多分割两次，保留初始值里的 TAB。
原生输入框预填并选中初始文字；Return 确认，Escape 取消。
确认响应 `result=ok<TAB>正文`，包括空正文；取消响应 `result=cancel`，不回传草稿。
正文按单行处理，移除 NUL/CR/LF，不进行 URI 编码，也不套用手动文字入口的 2048 字限制。
`dialog` 与 `text_input` 共用 FIFO；待回复暂停游戏输入及额外请求轮询，继续 tick/渲染。
提交失败保留输入与错误，支持重试；宿主 sheet 暂缓后保留草稿，关闭游戏清空队列与草稿。
格式错误请求按原壳行为回传取消；取消响应失败则显示错误供重试。

```bash
python3 tools/apple_host_text_input_test.py
python3 tools/apple_host_dialog_test.py --host-abi
```

测试覆盖协议、初始值、混合队列、草稿保留与失败路径，并生成独立原生 UI fixture。
fixture 使用明确的测试 ACK，不代表真实 runtime 发请求及成功响应已验收。
真实 HostKit ABI 的未初始化/不支持响应错误已验证；Minori 标题适配仍暂缓。
证据 `out/apple_host/evidence/m3-text-input/` 与 `m3-text-input-dialog-regression/`。


## 冷启动基准

使用原创 controls fixture，每轮启动全新宿主进程和隔离库，测量进程启动到首个 `startup state: SUCCEEDED` 日志的时间，随后检查正常引擎销毁。基准不包含导入时间，也不复用上轮进程。

```bash
python3 tools/apple_host_cold_start_benchmark.py --runs 5 --renderer software
python3 tools/apple_host_cold_start_benchmark.py --runs 5 --renderer metal \
  --output out/apple_host/evidence/cold-start-metal
```

当前 Apple M 系列 Debug 环境结果：软件绘制 p50/p95/max=0.398/0.482/0.502 秒；Metal 绘制 p50/p95/max=0.326/0.331/0.331 秒，5/5 轮正常关闭，均低于 2 秒目标。该结果是本机 Debug、原创小型 fixture 的基线，不代表大型真实游戏或发布构建性能。证据位于 `out/apple_host/evidence/cold-start/` 和 `cold-start-metal/`。


## 五语言文案审计

宿主界面文案覆盖简体中文、繁體中文、English、日本語、한국어。文案表按 key 提供五个非空值，语言设置同步页面、菜单、弹窗和游戏影片控件；游戏脚本与游戏内文字不翻译。

```bash
xcrun swiftc apps/apple_host/AetherHost/ShellStrings.swift \
  apps/apple_host/Tests/ShellStringsTests.swift -o out/apple_host/shell-strings-tests
out/apple_host/shell-strings-tests
```

测试会检查 key 覆盖、五语言数量、非空值、locale 映射及缺失 key 回退。


## 本地翻译模型

设置页「本地翻译模型」按 `engine_is_text_translation_available()` 显隐，与 Godot 壳一致。
选择外部 GGUF 模型后，宿主在打开游戏前透传 `text_translation.model_path`、
`text_translation.target_language`（跟随界面语言）与 `text_translation.enabled`；
「停用本地翻译」清空路径且不删除磁盘上的模型文件。模型必须存在、可读且为 `.gguf`。
未链接私有翻译 provider 时引擎返回“不支持”，宿主记录引擎返回的实际原因后继续启动；
Debug 自测可用 `AETHER_HOST_DEBUG_TRANSLATION=1` 强制显示该分区，仅用于宿主页面验证。

```bash
python3 tools/apple_host_translation_test.py
```

该工具运行设置/选项映射与模型校验测试，并记录当前核心是否链接私有翻译 provider。
真实模型加载（LOADING/READY/FAILED）、推理质量与耗时需该 provider 接入后另行验收。

## 平台请求应答策略

除 `open_browser` 这类无需应答的操作外，每个 operation 都会显式回传响应；
`call_native` 与原壳一致返回 `result=`。未处理的 operation 计入会话诊断
`unhandledPlatformRequests` 并写入宿主日志，避免 runtime 静默等待。
`minori_select`、`softpal_*` 窗口族、`softpal_http_get` 等缺口见
`doc/apple_host_seam_inventory.md` D 节。

## Purchase 请求基线

Apple 原生宿主当前未链接 Godot 扩展中的 StoreKit provider，因此 `purchase` 请求不会静默挂起或伪造购买成功。宿主解析 `product_id`，回传与现有壳一致的 `result=-1`、`error_response=-1` 和 URL 编码的不可用原因，并记录产品标识；缺少产品标识也会确定性完成。

```bash
xcrun swiftc apps/apple_host/AetherHost/PlatformPurchase.swift \
  apps/apple_host/Tests/PlatformPurchaseTests.swift -o out/apple_host/platform-purchase-tests
out/apple_host/platform-purchase-tests
```

这只是无 StoreKit provider 的降级路径，不代表真实购买、恢复或 entitlement 已验收。Debug 验证可设置 `AETHER_HOST_TEST_PURCHASE=product_id=com.aether.coffee%2Bbeta` 注入实际宿主进程；公开核心会拒绝 provider 响应并正常退出。由于 macOS 应用单例，注入进程不应与已运行的普通宿主窗口同时启动。完整 StoreKit 接入需单独链接 provider、处理交易生命周期和沙盒商品。

## `open_browser` 请求边界

Apple 宿主只为运行时 `open_browser` 请求打开带主机名的 `http` 或 `https` URL。空值、相对路径以及 `file`、`javascript` 等其他 scheme 会被拒绝并写入宿主日志。

```bash
xcrun swiftc apps/apple_host/AetherHost/PlatformBrowser.swift \
  apps/apple_host/Tests/PlatformBrowserTests.swift -o out/apple_host/platform-browser-tests
out/apple_host/platform-browser-tests
```

解析层不直接执行系统打开动作，便于在无 UI 的测试环境中覆盖拒绝边界。

Debug 宿主可用 `AETHER_HOST_TEST_OPEN_BROWSER=https://example.com` 注入一次真实请求，
用于确认平台分发和系统浏览器联动；该开关只编译进 Debug 路径。
直通帧租约可用 `AETHER_HOST_DIRECT_RENDER=1` 开启，或运行：

```sh
python3 tools/apple_host_smoke.py --game kag3 --renderer metal --snapshots direct --duration 30
```

该模式让宿主会话持有引擎 Metal 纹理，提交时验证渲染代际和命令队列；持有中的
纹理再次写入会执行写时分离，关闭会话会主动释放仍被 SwiftUI 保留的帧。诊断中的
`leases_*` 和 `frame_detach_copies` 用于确认提交、GPU 完成和复用边界。截图与
跨队列回读仍使用不可变快照。

直通模式在 krkrz 的 GPU frame publication 点直接推送最新纹理；每帧不再调用
`engine_get_godot_native_frame_texture`，也不再为 sink 反查
`TVPHostGetLatestGodotGpuFrame`。旧查询接口仍保留给软件/兼容路径，推送缓存按
RenderSession generation 校验，关闭或下一次会话不会接受旧 token。

frame publication sink 的函数指针使用 acquire/release 原子存取，reset、重新安装和
绘制线程通过同一封装同步。回调在 frame mutex 释放后执行，不形成引擎状态锁与
MetalBridge 锁的锁序依赖；sink 是进程常驻函数，不捕获已销毁的宿主 session。

### Settings regression tests

After building the Debug Apple host and its native libraries, run:

```sh
python3 tools/apple_host_settings_tests.py
```

The runner builds an isolated command-line target using the real `ShellModel`
(and HostKit), then checks migration, draft isolation, navigation, save/discard,
write failures, engine option acknowledgements, bundled documents and the
five-language catalog. It uses temporary library roots. Native window-close,
application-quit and layout verification still require CUA.

### iOS 18 核心构建（I0）

当前迁移只启用KiriKiri，ONS/Siglus暂缓。以下是核心归档构建，不产生可安装App：

```bash
python3 tools/apple_host_ios_build.py --sdk iphonesimulator --configuration Debug
python3 tools/apple_host_ios_build.py --sdk iphoneos --configuration Debug
```

使用已配置的 `VCPKG_ROOT`，否则使用仓库 `.devtools/vcpkg`。`--dry-run`显示命令，`--configure-only`仅配置；产物/日志/状态位于 `out/apple_host/ios/{device,simulator}/{debug,release}/`。专用triplet以18.0为最低版本，不改变Godot旧构建；两平台缓存隔离。当前依赖仍由仓库vcpkg manifest解析；provider关闭不等于全部无关依赖已从manifest移除。

iOS host core为静态库，App须链接完整依赖闭包并显式引用 `aether_apple_host_core_initialize`；仅看到两个 `.a` 文件不能证明provider已注册或游戏能运行。运行验收见 [迁移实践](../../doc/apple_host_ios_plan.md)。
