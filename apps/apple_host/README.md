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
python3 tools/generate_apple_metal_shaders.py --check

# KAG3 + ONS 并行，各运行 310 秒，截图验证输入推进、GPU RGB 对比及干净退出。
python3 tools/apple_host_smoke.py
# 快速冒烟（不构成五分钟 G0 验收）：
python3 tools/apple_host_smoke.py --duration 30
# P2 原生 Metal 绘制（ONS 验证软件兜底）：
python3 tools/apple_host_smoke.py --renderer metal
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

`--drawable-1080p` 固定实际 Metal 输出为 1920×1080；游戏画面和输入坐标仍遵循
游戏尺寸。要测试完整 1080p 绘制工作，源游戏也必须为 1920×1080。
冒烟检查至少 60 个完成样本、tick 唯一、耗时有效以及输出尺寸正确，
不把运行成功自动当作 16.6ms 性能通过。截图回读会扰动 GPU 队列，正式基准需另行隔离。

### 串行调度基准

默认采用直接呈现：主 RunLoop 的 Timer 同步执行一次 tick、上传/获取纹理并提交
MTKView 绘制，不为每个 tick 额外排队 Task，也不依赖 SwiftUI 更新来提交画面。
布局和游戏输入坐标仍由 SwiftUI/AppKit 管理；窗口缩放会触发独立重绘。
`AETHER_HOST_SCHEDULING=deferred` 保留 SwiftUI 延后呈现作对照。

```bash
python3 tools/apple_host_profile.py <1080p自检目录> --duration 60
```

该工具顺序运行 deferred/direct，关闭截图与测试输入，检查启动、退出、真实
1080p drawable、唯一 tick、无 GPU 错误与零回读，并记录未采样 tick 数。
CSV 新增 tick 到 draw、drawable 获取和命令编码耗时，辅助定位慢帧。
未采样 tick 包含合并/无 drawable/未完成等情况，不直接等同于显示器掉帧。
Timer 仍为 60 Hz；此改动不宣称已实现显示刷新同步或通过 G1。

## M2 游戏库

普通启动显示游戏库。点击「导入游戏」选择包含游戏入口的文件夹或 ZIP，复制完成后
选择「开始游玩」。返回前应在游戏内保存；确认返回会停止游戏。
默认库在 `~/Library/Application Support/Aether/Games`，同级 `library.json`
保存条目与最近游玩时间；源文件夹保留，运行日志和存档落在副本。
支持 KiriKiri/ONS 文件夹（及含 data 的上一级目录），也支持 ZIP 解压后识别入口。
重复导入使用现有副本，损坏索引不覆盖，复制/索引写入失败回滚新副本。

快捷键：⌘O 导入、⌘R 启动、⌘L 返回、⌘, 设置。
设置支持五语言、软件/Metal 绘制和日志开关；绘制变更下次启动生效。
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

详情页和列表右键菜单支持重命名、从库移除。名称保存到索引，不改变目录或存档。
移除只删除列表记录，保留文件；管理副本仍在 Games/<UUID>，可通过「添加外部游戏目录」
选择保留的副本恢复游玩，也可重新复制导入。重新导入原始目录不会自动找回保留副本的存档。
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
运行日志显示开关只控制界面。启动失败记录具体错误，关闭会话后可启动其他游戏。

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
跳过 NUL/换行，取消不发送。此入口不处理游戏内 IME preedit/选区自动同步；游戏发出的 `text_input` 请求另由平台队列处理。

```bash
xcrun swiftc apps/apple_host/AetherHost/KeyInputState.swift \
  apps/apple_host/Tests/KeyInputStateTests.swift -o out/apple_host/key-input-tests
out/apple_host/key-input-tests
xcrun swiftc apps/apple_host/AetherHost/InputMapping.swift \
  apps/apple_host/AetherHost/GameInputView.swift apps/apple_host/Tests/InputTests.swift \
  -o out/apple_host/input-tests
out/apple_host/input-tests
```

可导入原创 `tests/fixtures/apple_host_controls`，通过游戏 HUD 验证 down/up 数量及提交文字。
界面验证证据见 `out/apple_host/evidence/m3-controls/`；G1 继续暂缓。


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


## Purchase 请求基线

Apple 原生宿主当前未链接 Godot 扩展中的 StoreKit provider，因此 `purchase` 请求不会静默挂起或伪造购买成功。宿主解析 `product_id`，回传与现有壳一致的 `result=-1`、`error_response=-1` 和 URL 编码的不可用原因，并记录产品标识；缺少产品标识也会确定性完成。

```bash
xcrun swiftc apps/apple_host/AetherHost/PlatformPurchase.swift \
  apps/apple_host/Tests/PlatformPurchaseTests.swift -o out/apple_host/platform-purchase-tests
out/apple_host/platform-purchase-tests
```

这只是无 StoreKit provider 的降级路径，不代表真实购买、恢复或 entitlement 已验收。完整 StoreKit 接入需单独链接 provider、处理交易生命周期和沙盒商品。
