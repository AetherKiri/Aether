# Apple 原生宿主进度（Living Document）

- 最后更新：2026-10-10
- 关联：[spec](apple_host.md) · [接缝清单](apple_host_seam_inventory.md)

---

## 里程碑状态

| 阶段 | 状态 | 备注 |
|---|---|---|
| M0 接缝盘点 + 骨架 | 🟢 完成 | 交付物 A ✅ v0.2；交付物 B ✅；交付物 C ✅ **G0 达成**：KAG3 demo 实跑、输入透传验证、CPU 基线 ~35%（software@640x480）、日志行为对齐确认；KAG3 + ONS 各 310 秒验收通过 |
| M1 Metal 绘制桥 | 🟢 G1 证据齐（待用户确认标题登记） | 2026-10-11 回归：两款真实标题同刻 P2/P0 差值为 0；合成 1080p 两轮 0 超预算（max 16.27/15.76ms）；取帧停顿已定位修复。详见 [Metal 清单](apple_host_metal_plan.md) |
| M2 SwiftUI MVP | 🟢 目录导入 MVP | 库/导入/启动/返回/设置/菜单快捷键/五语言已接入；G2 的 KAG3+ONS 目录流程经界面验证 |
| M3 功能迁移 | 🟡 进行中 | 诊断与独立视频/文本字幕完成最小流程；其余迁移项待实现 |
| M4 iOS/iPadOS | ⚪ 未开始 | 闸门 G4 |

图例：⚪ 未开始 · 🟡 进行中 · 🟢 完成 · 🔴 阻塞

---

## 环境备忘（macOS 开发机）

- Xcode：`/Applications/Xcode.app`（已验证可构建 AetherKiri 现工程）
- Godot 4.7.2（仅用于现宿主对照）：`/Users/colorcard/Aether/.devtools/godot/Godot.app`
- vcpkg：`.devtools/vcpkg`（含既有 ggml 端口本地修复，见 2026-10-10 日志）
- Rust：`~/.cargo`（stable 1.99）
- 网络：GitHub 经本地代理 `127.0.0.1:10808`（构建/依赖下载需带 `http(s)_proxy`）
- XcodeGen 2.46.0：已安装（`/opt/homebrew/bin/xcodegen`）
- 协作：fork = `ColorCard/AetherKiri`（upstream `AetherKiri/Aether` 的 fork，remote 名 `fork`）；Apple 宿主工作分支 `feature/apple-native-host-m0`（推送到 fork，按需向上游开 PR）

---

## 工作日志

### 2026-10-10
- 完成 macOS 完整构建（Godot 宿主基线）：`out/godot/macos/debug/Aether.app` 可运行
  - 修复两个依赖问题（仅本地 vcpkg）：ggml tag 归档变更（哈希+补丁重建）；libb2 需 `autoconf-archive`
- 完成 macOS 原生菜单栏功能（Godot 宿主 +80 行 main.gd，新增 native_menu.gd）——作为"Apple 体验"路线 A 的首项，已端到端验证
- **启动 Apple 原生宿主（SwiftUI + Metal）迁移项目**：
  - 建立三份文档（spec / 接缝清单 / 本进度）
  - 交付物 A v0.1：宿主职责矩阵（会话/GPU 桥/输入/平台请求/媒体/音频/回收/呈现），确认 23 个 GPU 回调为宿主侧实现、ABI 宿主无关
  - 确认复用资产：`apple_external_texture.mm`（CVPixelBuffer→MTLTexture）、`RuntimeTickPacer`、StoreKit/文件选择 Swift、UI_TEXT 文案
- 建立目录骨架（`apps/apple_host/`、`bridge/apple_host/`）并安装 XcodeGen 2.46.0
- **M0-A 完成（v0.2）**：K 节 7 项盘点全部清零——输入事件 8 类枚举 + POINTER_CANCEL；engine 选项全表；**音频=引擎自带 OpenAL Soft（宿主零工作）**；presentation_sprite 发射方不在公开树（不阻塞）；HostKit API 面 ≈70 方法归档；目录映射表
- **呈现路径结论**：P2 绘制回调（无 ANGLE，贴合 Godot Native）为主路径；P1 IOSurface 需 GPU-bridge/ANGLE（暂缓）；P0 软件回读为 M0 基线
- **M0-B 完成**：`bridge/apple_host/` CMake 目标 `aether_apple_host_core`（SHARED dylib）构建通过
  - 复用 "Phase 2d link flip"：krkr2 glue + 全部 provider 注册 + legacy services 加载时安装（constructor）
  - 产物 `out/macos/debug/bridge/apple_host/libaether_apple_host_core.dylib`（依赖 `@rpath/libengine_api.dylib`）
  - 导出：`aether_apple_host_core_initialize/_engine_api_version`、`aether_krkr2_install_legacy_services`、各 runtime `RegisterRuntimeProvider`
- **M0-C 核心达成（历史性验证）**：`apps/apple_host/` SwiftUI 工程（xcodegen）构建通过并实跑
  - 工程：`project.yml` → xcodegen → `xcodebuild`；双 dylib 自动嵌入 `Contents/Frameworks/` 并签名
  - `HostKit/EngineSession.{h,mm}`：create/open/tick/软件帧回读/平台请求轮询
  - Swift 层：`EngineController`（60Hz tick 循环）+ `ContentView`（画面+日志+控制）
  - **实机验证**：KAG3 demo 完整渲染（640x480 标题画面），`startup state: SUCCEEDED`，tick 728 @60Hz，无崩溃
  - 已知待办：输入透传（G0 交互项）；CPU 基线测量；`krkr2.log` 落到游戏目录需重定向（引擎文件日志选项）
- **M0-C 收尾（G0 达成）**：输入透传实现并验证
  - `InputMapping.swift`：macOS→Windows VK 键码表、修饰键（0x01/0x02/0x04/0x80）、unicode、aspect-fit 坐标映射（对齐 `game_input_mapping.gd`）
  - `GameInputView.swift`：透明 NSView 覆盖层捕获鼠标/滚轮/键盘，自动成为第一响应者
  - `EngineSession` 新增 `sendPointer/sendKey/framePixelSize`；`AETHER_HOST_TEST_INPUT` 确定性冒烟（move→click→Return）
  - 实测：输入事件全部送达引擎（`input pointer type=2/1/3`、`input key vk=0xd`）；CPU 基线 **~31-37%（单核占比，software@640x480）**
  - 日志结论：`console_log_file` 控制 console.log 路径；**随游戏的 `krkr2.log` 为引擎无条件行为（与 Godot 宿主产品一致），接受为产品对齐**（spec §6 不侵入引擎原则）
- **输入坐标修复（关键 bug）**：引擎默认 surface **1280x720** 会把 640x480 内容 letterbox——frame 空间坐标落进画面左上角，点击无效。修复：首帧后 `engine_set_surface_size(frame)`（Game Native，对齐 Godot 产品默认模式）
  - 验证：确定性点击 (320,240) 触发 KAG3 菜单 → 剧情推进（帧导出对比 t=6 标题 vs t=20 对话，截图证据在案）
  - 新增 CI 能力：`AETHER_HOST_CAPTURE_AFTER=秒[,秒]` 引擎帧直出 PNG（不依赖窗口可见性）

---

### 2026-10-10：输入收尾与 M1 呈现基础
- 延续工作区的 NSEvent local monitor 修复，实际窗口点击 KAG3 菜单已进入剧情。
- 修复鼠标事件调用 `isARepeat` 的 AppKit 异常；SwiftUI teardown 改为正确的 static 协议方法。
- 游戏画布显式填满可用区域；黑边事件透传；捕获按压后画外松开仍发送 release；窗口失焦/销毁发送 POINTER_CANCEL；Command 快捷键和工具栏文本输入透传。
- `InputTests.swift` 覆盖画布映射、画外 release、取消按压、窗口失焦、快捷键、文本焦点和 teardown。
- `MetalFramePresenter.swift` + MTKView：RGBA 软件帧上传、Metal shader、等比呈现；可切换 Image 对照，失败回退。
- GPU 离屏测试通过：通道、上下方向、预乘 alpha、横/竖黑边、clear。截图增加 Metal PNG 和 RGB max diff。
- ONS 既有 smoke 启动通过；新增可交互、无限循环的 `apple_host_ons_input` fixture 与 `tools/apple_host_smoke.py`，用于五分钟 G0 验收。
- ABI 回调数校正：主表 17 + batch 2 + external 4 = 23；详细迁移契约与 G1 检查见 [Metal 实施清单](apple_host_metal_plan.md)。
- **G0 五分钟补验通过**：KAG3 + ONS 交互 fixture 各运行 310 秒，输入前后画面变化、305 秒末帧有效、exit code 0 且 engine destroyed；6/20/305 秒三组 engine/Metal RGB 最大差值均为 0。
  - 本地证据：`out/apple_host/evidence/g0-kag3/`、`out/apple_host/evidence/g0-ons/`（忽略构建产物，不入 Git）。
  - 最终源码构建 `BUILD SUCCEEDED`；输入和 GPU 离屏测试通过；最终构建 Metal/Image 各双 runtime 30 秒冒烟通过，证据 `final-metal/`、`final-image/`。
  - 长时运行包含确定性引擎输入；真实 AppKit 鼠标链路另经窗口点击 KAG3 菜单验证。长时测试不等同于五分钟人工连续操作。
- 后续 P2 实施结果见下节；真实标题 G1 和 1080p 性能验收仍待完成。

### 2026-10-10：M1 P2 原生 Metal 绘制桥

- 新增 `HostKit/MetalBridge.mm`，安装 23 个 ABI 回调；九组 compute kernels 从 Godot 参考源码生成，整数混合规则保留。未知/不适用模式显式返回 false。
- 原生 KAG 帧通过 GPU 快照进入 MTKView，正常 tick 无 CPU 回读；诊断截图和 Image 对照按需回读。ONS 使用软件帧兜底。
- 修复原生路径 CPU 截图读到黑色占位帧、初始 surface 拉伸及输入坐标不一致的问题。
- 实现嵌套批处理、依赖同步、重叠快照、稳定回读请求及 IOSurface 生命周期保护；begin-read 当前同步完成，异步调度待优化。
- 最终构建通过；输入、Metal 呈现和独立桥测试均通过。桥测试覆盖混合/三角形/批处理/外部纹理，结束后 textures=0、reads=0、failures=0。
- 最终 30 秒双 runtime 冒烟：`out/apple_host/evidence/p2-final-metal/`、`p2-final-image/`、`p2-final-software/` 均通过；原生 KAG Metal 的 native_readbacks=3（仅截图），failures=0。
- 独立软件与原生路径 KAG 标题截图 640×480：RGB max diff=0，changed pixels=0。对话动画提示的相位差尚未做确定性逐帧验证。
- P2 五分钟连续运行通过：KAG3 + ONS 各 310 秒，输入推进、6/20/305 秒截图和干净退出通过，GPU/回读 RGB 差值均为 0；证据 `out/apple_host/evidence/p2-long/`。生命周期保护补丁后的最终构建另通过上述 30 秒测试。
- **G1 尚未通过**：本机游戏库仅演示内容，至少两款 verified_games 真实标题及 1080p 完整帧 ≤16.6ms 待验收。

### 2026-10-10：M1 性能证据补充

- 增加独立桥 1080p 基准：清屏 + 8 层全屏 alpha 混合 + GPU 快照，预热 10 帧、采样 60 帧；覆盖 CPU 编码和 GPU 完成等待，不包含引擎 tick/MTKView。
- Apple M1 Max、macOS 15.7.1、Debug：批处理关闭 p50/p95/max=5.012/10.118/12.700ms；开启=3.579/6.132/12.903ms。证据 `out/apple_host/evidence/p2-bridge-benchmark.log`。
- 补测 padded stride 下的局部更新，验证偏移正确且未修改矩形外像素。桥测试通过，结束 textures=0/reads=0/failures=0。
- 新增 `AETHER_HOST_PROFILE=1` 与冒烟工具 `--profile`，输出宿主 tick + 纹理获取的单调时钟耗时；明确排除 MTKView，跳过 60 tick，最多 10000 样本。
- 构建与带 profile 的 KAG3/ONS 30 秒测试通过。640×480：KAG3 p50/p95/max=0.491/1.091/12.132ms（1701 样本），ONS=0.289/0.376/0.879ms（1708 样本）。证据 `out/apple_host/evidence/p2-profile/`。
- 以上均是组件或宿主工作测量，不能替代 G1 1080p 完整帧性能验收。真实标题和 tick-to-drawable 关联测量仍待完成。

### 2026-10-10：用户提供 aetherkiri-test 自检项目

- 来源 `/Users/colorcard/AetherKiri/demos/aetherkiri-test/data`；首次按原脚本运行软件/Metal，各 30 秒，启动、音频定时逻辑、指针输入及退出通过。运行使用本地副本，原目录未写入日志/存档；没有验证扬声器实际音频输出。
- **发现并修复真实端序错误**：`clear_rgba` 参数名 argb，但引擎传入的已是 AABBGGRR；宿主再次交换 R/B 导致动态青色十字与按钮边框变黄。移除重复交换，新增非对称 RGB 与青色 clear 回归。
- 修复后原项目第 20 秒动态截图与独立软件截图 RGB max diff=0。证据 `out/apple_host/evidence/selftest-metal-fixed/`；桥测试与宿主构建通过。
- 新增 `tools/apple_host_selftest.py`：复制源脚本、禁用重复 BGM timer（仅确定性绘制对照），分别以 640×480 和修改 SW/SH 的合成 1920×1080 运行软件/Metal。
- 首帧、鼠标十字、Z 层级切换、S 图案显隐、C 整组显隐/恢复，共八状态 × 两分辨率的 16 组独立软件/Metal RGB 对比全部为 0；四运行的呈现对比也全部为 0，输入均改变画面，干净退出，原生回读仅八次截图，GPU failures=0。
- 最终证据 `out/apple_host/evidence/selftest-parity-final/result.json` 保存来源哈希、派生修改、交互时序、比较结果与 profile。最初验证期间旧二进制的 `selftest-parity/` 结果作废，验收仅引用最终构建结果。
- 1080p 原生宿主 tick+纹理获取 p50/p95/max=0.876/1.622/26.549ms（891 样本）；四用例并行，且不含 MTKView，不构成完整帧性能验收。尾部慢帧与完整呈现时序仍需进一步测量。
- **G1 仍未达成**：这是一个合成自检项目，不能计为两款 verified_games 真实标题。

### 2026-10-10：夏雪 ～summer snow～ 原生宿主实跑

- macOS arm64 Debug AppleHost，renderer=godot_native + Metal，800×600；通过宿主正常初始化/打开界面启动授权游戏副本。
- 已观察启动页、品牌动画、标题背景/人物/按钮；点击新游戏后进入开篇剧情，推进多段中文对白，海滩背景正常呈现。
- 已向副本空槽保存，读档界面出现正确缩略图/摘要；推进后读取该槽，恢复海滩和保存时对白，再次输入仍能推进。未使用游戏包附带全 CG 存档。
- 检查日志发现 krflash.dll 未注册、KAG 默认设置补丁的 kag 成员缺失提示；上述已验证流程未被阻断，不声明 Flash/完整游戏流程已兼容。未验证后续剧情人物组合、长时间重复存读、结局、全部视频和实际音频输出。
- 开场电影返回 CPU 帧，普通场景返回原生 GPU token，宿主正常切换两种呈现来源。冒烟工具此前错误地把自定义游戏也要求为三次 native 回读；现在严格计数只对始终 native 的内置 KAG fixture 生效，自定义游戏检查原生能力及 GPU 执行状态。
- 第一轮独立软件/Metal 各 60 秒均完成输入、截图、退出；原生桥 failures=0，三次 engine/Metal 呈现 RGB 对比均为 0。native_readbacks=1 是另两次截图位于 CPU 视频帧，非额外回读。第一轮 native 冒烟因旧计数断言误报，不能引用为整体工具 PASS。
- 第一轮第 55 秒为电影渐变画面，两进程时间相位不同，RGB max diff=65；不能声称全游戏逐帧渲染一致。补测加入回车序列仍停留于电影，不作为静态标题逐像素证据。
- 修正检测工具后，软件/Metal 各 60 秒均 PASS，证据 `natsuyuki-metal-title/`、`natsuyuki-software-title/`。三次呈现 RGB 对比均为 0，桥 failures=0；目录名称中的 title 不代表最终截图为静态标题。完整实跑摘要见 `natsuyuki-live/result.json`。
- 800×600 原生宿主工作耗时（不含 MTKView）p50/p95/max=0.978/4.148/106.058ms，3503 样本，包含启动/视频切换，且与其他运行并行；尾部慢帧未定位，不构成完整帧 G1 性能通过。
- 本次未改动引擎/私有插件，无兼容修复提交；沿用 feature/apple-native-host-m0 的未提交宿主工作。AetherInternal gitlink=bdf151cd，本地目录未初始化，不声明当前二进制具备完整私有插件闭包。
- 证据在 `out/apple_host/evidence/natsuyuki-live/`、`natsuyuki-metal/`、`natsuyuki-software/`。人工窗口观察由 CUA 记录；自动证据与人工存读流程独立。
- 尚未更新 verified_games 支持表：这里只记录代理观察，待用户确认游戏工作后按技能要求更新中英文列表。G1 两款真实标题与完整帧性能仍未完成。

### 2026-10-10：收束游戏验证，推进 M1 呈现测量

- 用户要求结束当前游戏试验并继续项目开发；《夏雪》补充推进到乡间道路、森林背景，关闭测试引擎，保留副本存档及本地证据。未扩展为全游戏兼容承诺。
- 新增 tick 与实际 MTKView drawable 提交的关联采样，覆盖引擎、纹理获取/上传、SwiftUI 调度、drawable 获取、GPU 排队及命令完成。去重同 tick 重绘，跳过被合并而未提交的 tick；预热 60 tick、上限 10000，游戏重开时重置并隔离旧回调。
- 新增 `AETHER_HOST_DRAWABLE_1080P=1`，固定真实屏幕呈现目标 1920×1080。CSV 逐样本记录实际尺寸、总耗时与 GPU 耗时；冒烟增加样本量、尺寸、唯一 tick 与有效耗时检查。
- Xcode Debug 构建、Metal 呈现测试及 1080p 30 秒原生冒烟通过；三次截图呈现 RGB 差值 0、GPU failures=0。含截图轮的最大耗时约 1.4 秒，对应同步截图阻塞，不作为日常基准。
- 单独无截图、无回读 1080p 自检：1739 个已完成呈现样本，p50/p95/max=4.310/6.696/30.181ms，1 个样本超过 16.6ms；宿主工作 p95=2.406ms。证据 `out/apple_host/evidence/presentation-profile-1080p-clean/`。
- **G1 仍待验收**：测量终点为 GPU 命令完成，尚非屏幕扫描输出；仍有慢帧和两款真实标题要求。下一项优先改善 Timer/SwiftUI 呈现调度并记录漏呈现比例，随后完成 G1，再进入 M2 产品壳。

### 2026-10-10：M1 主线程直接呈现

- 移除主 RunLoop Timer 内的逐帧 Task 排队；在同一主线程回调中完成 tick、纹理获取/上传和 MTKView 绘制提交。SwiftUI 管理布局与输入层，原生纹理/CPU 软件帧共享直接提交路径。
- `AETHER_HOST_SCHEDULING=deferred` 保留延后呈现作比较。CSV 增加 tick-to-draw、drawable 获取、编码耗时；宿主工作日志明确直接模式包含 MTKView 提交，排除异步 GPU 完成。
- 新增 `tools/apple_host_profile.py`，顺序运行两个模式，避免并行 GPU 干扰、截图和输入扰动，记录呈现样本、未代表的 eligible tick 与慢帧阶段。
- 1080p 自检串行 30 秒：deferred p50/p95=4.659/7.948ms，direct=1.674/3.423ms；样本分别 1731/1674。证据 `out/apple_host/evidence/presentation-scheduling-comparison/`。该短期结果说明调度延迟降低，不能推断长期帧率。
- 两模式仍有约 1 秒尾部等待，阶段记录定位到 drawable 获取（GPU 约 0.1ms）。限制在途 drawable 的试验没有消除此问题，且 ONS 回归暴露呈现停滞，已撤下；相关试验结果不作为交付验收。
- 最终 Debug 构建、Metal 呈现测试、KAG3 原生及 ONS 软件兜底各 30 秒冒烟通过；三次截图各 RGB 差值为 0、GPU failures=0、干净退出。最终证据 `out/apple_host/evidence/presentation-direct-final/`。
- **G1 保持未通过**：保留可见慢帧数据，下一项调查 drawable 可用性与窗口可见状态/刷新节奏，避免将 p95 改善误判为最大帧预算达标。

### 2026-10-10：按用户调整进入 M2 产品壳

- 用户明确要求跳过当前 G1，完成后续后再优化；更新 D9，不再以 G1 阻止 M2。G1 保留未验收状态，未改写为通过。
- 正常启动进入原生游戏库，单窗口持有一个引擎会话；开发路径工具页由 `AETHER_HOST_DEVELOPER=1` 或现有 AUTORUN 显式进入，原回归工具继续可用。
- `GameLibrary` 托管复制选中的 KiriKiri/ONS 游戏目录，也识别上一级包含 data 的目录；索引保留来源、导入时间和最近游玩时间。源目录不会被作为运行目录；存档/侧车日志写入副本。复制在线程任务执行，临时目录完成后移动，索引原子写入失败则回滚副本。
- 重复导入选择既有条目，保留副本存档；拒绝递归导入库父目录、符号链接和目录伪装脚本；加载时校验 UUID 目录路径，损坏索引保留且停止覆盖。
- 基础设置：简体中文、繁体中文、英文、日文、韩文；软件/Metal（测试中）绘制，下次启动生效；运行日志开关。偏好持久化，测试库使用独立键前缀。平台标准菜单按系统语言显示。
- 原生菜单/快捷键：⌘O 导入、⌘R 启动、⌘L 返回、⌘, 设置；返回明确提示先在游戏内保存，确认后销毁会话并回库。失败启动/导入显示错误，库仍可用。窗口关闭与应用退出清理会话。
- 应用内打包共享 CJK 默认字体及 OFL 许可，不再要求普通用户传入默认字体路径。
- **G2 目录流程已通过人工 CUA 验证**：空库→NSOpenPanel 导入 KAG3→启动/点击/回车→返回→退出/重启恢复记录；再导入 ONS→输入将白底推进到红底→返回→设置 Metal→再次启动 KAG3 原生纹理；英文及 Metal 设置跨重启恢复，无效文件夹错误后仍能启动既有游戏。所有游戏路径通过界面选择，无脚本修改或环境变量指定游戏路径。
- 库事务测试覆盖副本隔离、重复导入/存档保留、索引重载、data 目录识别、伪入口/链接/递归拒绝、写入失败回滚、索引路径逃逸拒绝。Debug 构建通过；最终开发模式 KAG3/ONS 各 30 秒回归通过，输入、三次截图 RGB 对比及干净退出均通过，GPU failures=0。证据 `out/apple_host/evidence/m2-library-ui/`、`m2-final-regression/`。
- 本阶段导入范围为文件夹复制；压缩包、外部目录引用/沙盒书签、库编辑/移除、其他 provider 的入口识别仍待扩展。冷启动 ≤2s 未单独测量，不宣称已达成；M3 视频/IAP/诊断/更新等尚未实施。

### 2026-10-10：M3 诊断首项

- 新增 `DiagnosticStore`：宿主与 ABI 启动日志带 UTC 时间落盘，单文件上限 1 MiB，保留当前及上一轮；最后一次游戏会话的 UUID、时间、目录、绘制方式、API、状态、错误与关闭信息原子写入 `session.json`。设置中的日志显示开关只影响页面，不关闭证据记录。
- 设置和「游戏」菜单提供五语言「导出诊断日志」，快捷键 ⌘⇧D；通过 NSSavePanel 保存 UTF-8 文本，完成后在 Finder 选中。报告含应用/系统信息、当前及上一轮宿主日志、最后运行游戏目录的 `krkr2.log` / `aetherkiri-engine.log` 尾部，各最多 1 MiB。缺失日志明确标记，文件修改时间和尾部大小可见；日志可能跨会话，不将侧车文件误称为当前会话全量日志。不会打包游戏资源与存档，日志本身可能含路径及引擎打印的文本。
- 普通路径在游戏库同级 `Diagnostics/`（默认 `~/Library/Application Support/Aether/Diagnostics`），而非早期规划的 `~/Library/Logs/Aether/`；测试工具为每个进程隔离库/诊断目录，避免并行回归写入同一日志。
- 启动失败从 `engine_get_last_error` 取得实际错误；关闭前抽取剩余启动日志。错误落盘后回库，下一次启动创建新会话并清除上一错误；正常返回记录 stopped，失败保留 failed。此项不实现进程级崩溃捕获、自动重启或结构化诊断 ABI 全量迁移。
- CUA 使用独立库导入抛出 `M3_DIAGNOSTIC_FAILURE_SENTINEL` 的测试游戏；关闭引擎弹窗后宿主显示实际启动错误并回库。通过菜单导出失败报告，退出/重启后经设置再次导出，均保留脚本异常和终止原因；同一进程再次失败后能直接启动正常 KAG3、接收回车并返回。证据 `out/apple_host/evidence/m3-diagnostics/`，源游戏库及原文件不受测试修改。
- 存储测试覆盖轮转/大小上限、重启恢复、尾部截取、缺失日志、资源/存档排除、符号链接拒绝、保护日志文件免被导出覆盖、新会话清除旧错误、写入失败。Debug 构建与 KAG3/ONS 各 30 秒 Metal/软件兜底回归通过；输入、三次呈现 RGB 对比、GPU failures=0 与清理退出正常。最终回归证据见 `m3-final-isolated-regression/`。
- **G1 仍暂缓**，本项完成不代表 M3 全部功能迁移已完成。下一项推进视频/字幕接缝与最小播放流程。

### 2026-10-10：M3 独立视频与文本字幕

- 新增 `MediaSession`，直接复用宿主无关 `engine_media_*` C ABI 和已有 FFmpeg/OpenAL 管线，不引入新的解码依赖。媒体句柄在引擎之前销毁，重复关闭安全，失败打开清理后可继续打开文件；即使底层打开返回成功，也检查是否实际存在视频流。
- 原生工具栏与「视频」菜单提供「打开视频」（⌘⇧O）；文件只读播放，不复制/写回源视频。游戏/视频互斥，播放页支持暂停/继续（空格）、进度条跳转、±10 秒、0.5–2×、音量与返回游戏库；窗口关闭和退出停止媒体线程并清理临时字幕。
- `VideoSubtitles` 解析 UTF-8 SRT/VTT/ASS/SSA 文本，支持 CRLF/BOM、标记清理、重叠去重、时间边界和向后跳转。匹配同名外置字幕自动选择，内嵌文本轨道通过 ABI 列出/提取到应用临时目录，可切换及关闭。每个字幕文件读取上限 1 MiB；此阶段仅文本呈现，不支持 ASS 样式/动画/定位/绘图或位图字幕。
- 暂停时设置倍速保持暂停；继续和片尾重播应用所选倍速。片尾界面保留总时长，清空字幕/恢复位置；播放位置负值夹至零，避免开始阶段丢失首条字幕。解码器异步寻址，界面恢复位置可能与保存秒数存在短暂偏差，不声明逐帧精确寻址。
- 每 5 秒及暂停/跳转/关闭保存进度到 `media-progress.json`，同一路径再次打开时恢复，保留最近 200 项；结束与临近结尾位置下次从头播放。索引损坏时保留原数据并记录错误。视频会话错误/状态接入 M3 诊断日志与导出。
- `tools/apple_host_media_test.py` 生成 18 秒 MPEG-4/AAC/MKV（内嵌 SRT + 同名外置 SRT）的本地样本，顺序运行字幕/进度、MediaSession 和 MediaController 三组测试。覆盖真实帧更新、暂停时钟、跳转后新帧、调速、字幕提取/切换/关闭、EOF/重播、恢复位置、失败打开后的恢复及清理；三组均 PASS，证据 `out/apple_host/evidence/m3-media-final-tests/`。
- CUA 验证菜单选视频、首帧/中文字幕、暂停后设置 2× 仍保持暂停、进度条跳转、内嵌字幕与外置字幕、音量变化；退出时保存 5 秒，重启打开恢复到约 5 秒；片尾/重播、返回与无效视频错误恢复已验证。证据 `out/apple_host/evidence/m3-media/`。
- 最终 Debug 构建通过，原诊断存储测试通过；KAG3 原生/ONS 软件兜底各 30 秒回归 PASS，输入推进、三次呈现 RGB 差值 0、GPU failures=0、干净退出。证据 `out/apple_host/evidence/m3-media-game-regression/`。同一界面进程播放/关闭视频及无效文件后，仍完成 KAG3 导入、启动、回车和确认返回。
- 视频当前为 RGBA 回读 + SwiftUI 图像的基线，非视频零拷贝；此项没有音频听音确认，也未覆盖所有封装/编码、长视频、旋转/SAR/HDR 色彩。独立视频库复制管理、字幕选择记忆、全屏/快捷手势及 Minori `minori_movie` 请求仍待迁移。**G1 保持暂缓。**

### 2026-10-10：M3 屏幕按键与提交文字

- 游戏页及设置提供五语言虚拟按键开关，记忆显示偏好；按键包括回车、空格、Esc、方向键、PgUp/PgDn 与保持 Ctrl。作用由游戏决定，不改写游戏脚本。
- `KeyInputState` 合并实体/虚拟来源的按键所有权，重叠期间不产生多余 down/up，保留实体键重复；隐藏控件、进入设置/文字/返回确认弹窗、窗口失焦与关闭会释放按键。游戏画布失去 first responder 时也释放实体键与捕获鼠标；暂停输入期间仍允许鼠标松开事件。
- 原生「输入文字」弹窗提交完成后的 Unicode 标量，经 `TEXT_INPUT` 进入游戏，过滤 NUL/CR/LF，一次最多 2048 个标量；取消不发送，宿主仅记录数量。此项是手动提交文字入口，尚未迁移游戏内 IME preedit、光标/选区同步及自动输入框检测，也不等同于平台 `dialog`/`text_input` 请求处理。
- 新增原创 `tests/fixtures/apple_host_controls/startup.tjs`，画面显示 down/up 与已收到文字。CUA 独立库验证回车/空格/左箭头、保持 Ctrl 后打开文字弹窗、隐藏栏、设置及返回确认再取消：最终 down=7/up=7、text=你好A；取消后未再提交。重启恢复显示且 Ctrl 为 off；补验其余六个键，隐藏应用时日志确认 Ctrl down/up 与 released。画面与宿主日志在 `out/apple_host/evidence/m3-controls/`。
- `KeyInputStateTests` 覆盖来源重叠、重复、释放、Unicode/长度过滤；`InputTests` 增补焦点/窗口切换松键与取消幂等断言，两组 PASS。Debug 构建成功，KAG3/ONS 各 30 秒回归通过，呈现对比差值 0、GPU failures=0、正常退出，证据 `m3-controls-game-regression/`。
- 核对现有 Godot 后纠正接缝清单：文本输入依赖输入状态与 TEXT_INPUT；公开壳处理 `dialog` 的 URL 表单请求。2026-10-11 补查 C++ 扩展确认 `text_input` 三字段为标题/消息/初始文字（并非长度参数）；前次仅检查 GDScript 的结论不完整，接缝清单已纠正。平台请求、Minori 媒体仍为下一项；**G1 保持暂缓。**

### 2026-10-10：M3 平台 dialog 请求

- 原生壳接入 `dialog` 平台请求：按现有 Godot URL 表单解析 title/message/text_field/maximum_characters/yes_no/buttons，自定义按钮保留 Int32 编号和文字；响应经 `engine_submit_platform_response` 发送 `result=<id>&text=<URI encoded>`，严格转义空格、加号、&、= 与 Unicode。输入长度按 Unicode 标量计数，不截断代理对；非文本弹窗不回传文字。
- `PlatformDialogController` 按 FIFO 保留请求，在当前 sheet 完成关闭后再呈现下一项；宿主设置/手动文字/返回确认打开时延后呈现。待响应期间停止额外轮询，当前一次 drain 最多 256 项、每项现有 ABI 缓冲 4096 字节；引擎继续 tick/渲染，游戏输入暂停并释放持有键。关闭引擎清空请求，旧 UUID/重复完成不能回传到下一会话。
- 成功响应仅提交一次；失败保留弹窗、文字和实际错误，可重试。简单确认与是/否弹窗提供 Escape/取消（result=0）；自定义按钮仅返回请求提供的编号，只有编号 0 的按钮提供 Escape，不凭空添加取消编号。文本 Return 使用首个自定义按钮，默认确认使用 1。
- `EngineSession` 增加响应 wrapper，明确返回未初始化/不支持运行时的 NSError；普通壳与开发页面均安装原生 sheet。日志只记录排队数量、result 和失败，不主动记录弹窗标题、消息或回复正文。
- `tools/apple_host_dialog_test.py --host-abi` 编译/运行解析队列测试、HostKit 真实 ABI 错误路径，并构建独立 SwiftUI 测试 App。覆盖编码/字数/无效载荷、自定义编号、FIFO、宿主弹窗延后、重复/旧响应、失败重试、会话清理；测试通过。公开核心的未激活 provider 不支持响应，错误被 wrapper 正确传回。
- CUA 使用生产 parser/controller/view 的独立测试 App，验证中文 `你好+&EXTRA` 截为 `你好+&`、响应失败后原文字保留、重试得到 result=7 和 URI 编码正文，后续是/否与取消按顺序提交；最终版本另验证自定义按钮 Escape 不提交未知编号、Return 重试、中文是/否及肯定/确认响应。证据 `out/apple_host/evidence/m3-dialog/`。这个测试 App 使用明确的测试 ACK 回调，不代表已验证私有 Artemis/Minori provider 实际发请求及接收响应；该真实运行时验收仍待取得 provider。
- Debug 构建、KAG3/ONS 各 30 秒回归 PASS；输入推进、呈现对比与正常退出通过，证据 `m3-dialog-game-regression/`。本项未接入其它平台 operation、Minori 媒体、自动 IME 或 IAP；**G1 保持暂缓。**

### 2026-10-11：M3 Minori 运行时影片

- `RuntimeMovieController` 接入公开 provider 的六字段 TAB 协议，严格验证绝对路径、Int32 坐标、正尺寸与可跳过标记。按原游戏画布的 aspect-fit 比例呈现指定矩形；影片不改变游戏输入坐标，五语言提供跳过按钮。
- `MediaSession` 区分自有与借用引擎，影片借用游戏引擎；自然结束/跳过分别发送一次 complete/skipped，错误发送一次 error。先销毁媒体再回应，避免 provider 删除缓存时仍占用文件；关闭游戏先清理媒体，再销毁引擎且不回传完成。响应失败报告实际错误，不重复推进 VM。
- 播放期间释放已有捕获、暂停游戏键鼠及手动文字提交；可跳过时点击/Enter/Space/Esc 结束，消耗跳过键的重复、松开及鼠标松开。结束后下一次新输入正常送达。
- 游戏库增加公开两类 Minori profile 的 scr.paz + sys.paz + 四种 EXE 标记识别与复制测试。仅标记识别，不执行 EXE，核心启动时检查档案内容；未宣称支持全部 PAZ 标题。
- `tools/apple_host_runtime_movie_test.py --run-host` 生成无音轨 AVI，真实核心测试覆盖首帧、EOF、可跳过/不可跳过、错误恢复、重复完成、提交拒绝、借用引擎不被销毁与输入隔离。实际 Xcode 宿主中结束、跳过、提前关闭三例 PASS，ACK 分别 complete、skipped、无响应，正常销毁引擎。证据 `out/apple_host/evidence/m3-runtime-movie-native-host/`。
- CUA 在实际宿主游戏页验证影片矩形、跳过按钮及返回游戏；跳过后 HUD down=0/up=0，再按 a 得到 down=1/up=1、text=a。界面证据 ui-frame.png 与 ui-resumed.png。组合独立测试 App 曾在 KiriKiri 启动阶段崩溃，未认定原因；验收改用实际 Xcode 宿主并保留失败日志，未将失败 harness 作为交付工具。
- Debug 构建、游戏库测试、既有三组媒体测试、KAG3 原生/ONS 软件兜底各 30 秒回归通过，呈现对比差值 0、正常退出。证据分别为 `m3-runtime-movie-media-regression/` 与 `m3-runtime-movie-game-regression/`。
- 本轮请求由 Debug hook 注入，响应是明确的测试 ACK；尚无有效 Minori 游戏验证真实 VM 发请求与接收响应，也未验收实际听音。Minori 音频、文字框/选择/存档、`text_input` 请求仍待迁移；**G1 保持暂缓。**

### 2026-10-11：调整推进优先级

- 按用户要求暂缓 Minori 游戏适配，保留现有影片实现；音频、文字框、选择、存档及真实游戏验收暂不继续。
- 优先完善通用游戏库：重命名、移除、外部目录引用；随后推进压缩包导入与通用 `text_input` 平台请求，再安排 IAP、更新和翻译。此处调整计划，尚未实现新增功能。
- G1 继续暂缓；当前顺序同步写入根目录 `AGENTS.md`，供后续对话接续。

### 2026-10-11：M2 游戏库编辑与外部目录

- 库详情页及右键菜单增加重命名、移除；名称限制 1–200 个字符、去首尾空白并拒绝控制字符。写入成功后才更新界面；失败保留原记录，重命名错误在输入弹窗中呈现。
- 移除仅删除索引记录，确认框明确文件和存档保留，不执行磁盘删除。管理副本保留在 Games/<UUID>，可从库存储位置找到并添加外部引用恢复；重新导入原目录不自动恢复旧副本存档。磁盘清理待后续独立设计。
- 添加外部游戏目录入口使用原目录，data 包装目录解析至实际入口；显示外部目录标记与存档写入提示。复制模式仍默认，按模式去重，旧索引缺失 externalPath 时按副本读取。外部引用使用绝对路径；本阶段未启用 App Sandbox/security-scoped bookmark，移动目录后需重新添加。
- GameLibraryTests 通过：旧索引、名称持久化/校验、时间与目录保持、外部引用/重复添加、从引用创建副本、非破坏移除、保留副本重新引用及写入失败；现有复制隔离/回滚/路径防护测试也通过。Debug 宿主构建成功。
- CUA 在隔离库添加原创 fixture 的外部目录，重命名为“外部测试 🎮”，成功启动、返回并确认移除；列表清空而 startup.tjs 保留。证据 `out/apple_host/evidence/m2-library-edit/`，用户实际游戏库未修改。
- 下一项为压缩包导入与通用 text_input；Minori 适配及 G1 继续暂缓。

### 2026-10-11：M2 ZIP 导入

- 原生导入面板同时选择目录或 ZIP，外部目录入口仍只选择目录；五语言提示复制策略、32 GiB/10 万条目限制及失败原因。解压/复制在后台执行，期间禁用重复导入与库修改。
- `GameArchive` 复用系统 libarchive 的稳定读取 ABI，自行创建普通文件，不调用归档磁盘写入器。逐项拒绝绝对/越界路径、反斜线/盘符、软硬链接、特殊文件、加密、重复及大小写/Unicode 路径冲突；按声明和实际输出限制总字节，检查完整读取/CRC 错误。
- 私有临时目录解压后搜索最多 8 层的唯一游戏入口（忽略 __MACOSX；识别入口后不向游戏资源内继续搜索），随后复用目录复制/原子索引流程。标题与 sourcePath 使用原 ZIP，按 ZIP 路径去重并保留已有存档；临时目录成功/失败清理，索引失败回滚新副本，源 ZIP 不改写。
- `tools/apple_host_archive_test.py` 生成平铺、包装、中文、ZIP64 及危险/损坏样本；GameArchiveTests 与既有 GameLibraryTests 均 PASS。覆盖存档/源文件保留、重复导入、越界/链接/大小写父目录冲突、加密标记、CRC、非 ZIP、空包、多入口、规模限制、临时清理与写入失败回滚。Debug 构建通过，无外部解压工具运行依赖。
- CUA 在隔离库导入含原创 controls fixture 的 ZIP，成功启动与回车（down=1/up=1）、返回；导入 traversal.zip 正确显示中文错误，保留原记录并恢复操作。证据 `out/apple_host/evidence/m2-archive/`，未修改用户游戏库。
- 此阶段不支持 RAR/7z/密码、取消/字节进度，也不声明全部 ZIP 编码/压缩方式或大包性能已验收；大包需临时解压与最终复制空间。下一项为通用 text_input，Minori 与 G1 继续暂缓。

### 2026-10-11：Purchase 请求降级基线

- Apple 宿主接入 `purchase` operation 的解析与确定性错误响应：提取 URL 表单 `product_id`，回传 `result=-1`、`error_response=-1` 和“App Billing unavailable”，避免公开宿主在没有 StoreKit provider 时让游戏永久等待；日志只记录产品标识，不记录其他请求正文。
- `PlatformPurchaseTests` 覆盖普通/编码/缺失 product_id 和响应格式；Debug 宿主构建通过。通过 Debug-only `AETHER_HOST_TEST_PURCHASE` 在实际宿主进程注入请求，日志确认进入 Purchase 分支、公开核心返回“不支持平台响应”，随后正常 tick/退出并销毁引擎。现有 StoreKit 实现位于 Godot 扩展，未被 Apple 原生宿主链接，本项不伪造购买成功。CUA 可正常查看宿主库界面；macOS 应用单例使注入环境进程未能绑定为独立 AX 窗口，故本次 UI 证据以进程日志为准。
- 更新器按用户要求留到最后；真实 StoreKit 购买/恢复/entitlement、沙盒商品和交易生命周期仍待 provider 接入。

### 2026-10-11：`open_browser` URL 边界

- Apple 宿主对通用 `open_browser` 平台请求增加可测试解析层：去除首尾空白，只接受带主机名的 `http`/`https` URL。
- 空值、相对路径和其他 URL scheme 会被拒绝并记录日志；系统打开失败也会记录 scheme，避免运行时请求静默丢失或触发任意本地 scheme。
- `PlatformBrowserTests` 与 Debug Xcode 构建通过；未对真实网页做 CUA 导航，因为本项只验证请求边界，不改变宿主界面。
- Debug 宿主增加 `AETHER_HOST_TEST_OPEN_BROWSER` 一次性注入开关，后续可用 CUA 观察系统浏览器实际联动。

### 2026-10-11：五语言文案审计

- 宿主已有的简体中文、繁體中文、English、日本語、한국어文案表增加只读审计接口；`ShellStringsTests` 检查 80+ key 的五语言数量、非空值、locale 映射和缺失 key 回退，测试通过。
- 语言设置继续覆盖宿主页面、菜单、弹窗、游戏控制栏和影片跳过控件；游戏脚本与游戏内文本保持原样。后续若新增文案，测试会阻止缺失语言值进入构建。

### 2026-10-11：通用宿主冷启动基准

- 新增 `tools/apple_host_cold_start_benchmark.py`：每轮启动全新 Debug 宿主进程、独立库目录和原创 controls fixture，测量从进程启动到首个 `startup state: SUCCEEDED`，检查正常退出与 `engine destroyed`，输出每轮、p50、p95、最大值及 2 秒目标判定。
- 5 轮软件绘制结果 p50/p95/max=0.398/0.482/0.502 秒；5 轮 Metal 绘制结果 p50/p95/max=0.326/0.331/0.331 秒，均达到本地 2 秒目标。基准不包含导入，不代表大型真实游戏或发布构建；证据 `out/apple_host/evidence/cold-start/` 和 `cold-start-metal/`。
- 下一步转入 IAP、更新与翻译逐项迁移；Minori 与 G1 继续暂缓。

### 2026-10-11：M3 通用 text_input 平台请求

- 对齐原 C++ 壳的三字段 TAB 协议：标题、提示、初始文字，最多分割两次；确认发送 result=ok + TAB + 正文，取消仅 result=cancel，允许空正文并保留 Unicode/正文 TAB，不使用 URL 编码。按单行控件过滤 NUL/CR/LF，不继承手动 TEXT_INPUT 的 2048 字限制。
- 复用原生平台 sheet 与统一 FIFO，按请求 operation 调用 HostKit 响应；初始值自动选中，Return 确认、Escape 取消。待回复隔离游戏输入并停止额外轮询，继续引擎 tick；重复与旧 UUID 无效，关闭游戏清理队列、草稿和错误。
- 提交失败保留当前输入与错误，明确重试；宿主弹窗暂缓时保存草稿和失败状态，不因重新呈现自动重试。格式错误请求自动排队回传取消，取消提交失败保留可重试弹窗。
- `PlatformTextInputTests` 与既有 `PlatformDialogTests` 通过，覆盖三字段/空值/初始值 TAB/中文 Emoji/取消隐私、混合 FIFO、暂缓草稿、失败重试、无效请求及清理。HostKit ABI 补验 text_input 的不支持响应错误，保留原未初始化/关闭检查；Debug 构建成功。
- CUA 使用生产 parser/controller/view 的独立 UI fixture，确认预填选中初始文字；你好😀&=+% 在首次失败后保留，Return 重试回传原正文，再完成 dialog、Escape 取消输入、自动取消无效请求。ACK 为明确测试回调，真实 provider 发请求/接收成功响应仍未验收；本项不继续 Minori 标题适配。
- 证据 `out/apple_host/evidence/m3-text-input/`、`m3-text-input-dialog-regression/`；KAG3/ONS 回归结果见下方最终验证记录。IME preedit/选区自动同步仍待迁移，Minori 与 G1 继续暂缓。

### 2026-10-11：M3 本地翻译设置与平台请求覆盖

- 新增 `TranslationSettings`/`TranslationStatus`：把引擎通用选项 `text_translation.model_path`、`text_translation.target_language`、`text_translation.enabled` 接入宿主，目标语言跟随界面语言，选项顺序与取值对齐 Godot 壳的 `_apply_engine_options`。模型路径去首尾空白、限制 `.gguf`、要求存在且可读，并持久化到偏好。
- 设置页新增「本地翻译模型」分区：选择 GGUF 模型 / 停用本地翻译 / 已选模型 / 状态行（未启用、加载中、已加载、失败）与统计明细（后端、模型大小、已翻译、失败次数）；加载中在游戏页显示提示。分区按 `engine_is_text_translation_available()` 显隐，与 Godot 壳一致；本机构建未链接私有 provider（探针实测 available=0），仅在 Debug 覆盖 `AETHER_HOST_DEBUG_TRANSLATION=1` 时显示，用于宿主自测。
- 选项在 `initializeEngine` 内、打开游戏前应用；被引擎拒绝时记录实际错误并继续启动，不中断会话。本机日志确认三个键按顺序下发且返回引擎真实原因 "local-model text translation is unavailable in this build"，游戏仍正常启动。真实模型加载、推理质量与耗时需链接私有 provider 后单独验收。
- 平台请求覆盖补齐：`call_native` 按原壳回传 `result=`；把「无响应类」（`open_browser`）与「未处理」分开记录，未处理请求累计后写入会话诊断 `unhandledPlatformRequests`，避免运行时静默等待。接缝清单 D 节补记 Godot 壳已应答但宿主尚未实现的 `softpal_*` 窗口族、`minori_select` 与 `softpal_http_get`。
- `TranslationSettingsTests` 与 `tools/apple_host_translation_test.py` 通过（选项映射/模型校验/状态文案 + 引擎可用性探针）；`ShellStringsTests` 覆盖新增 18 个五语言 key；purchase/browser/input/dialog 测试与 KAG3+ONS 各 30 秒冒烟通过。CUA 验证分区显隐、选型、重启保持、停用与选项应用日志。本轮未改动引擎与 provider ABI。

### 2026-10-11：M3 游戏内文字输入（IME 与编辑控件同步）

- 新增 `GameTextInputState`/`IMEPreeditTracker`/`IMECommandMap`/`GameTextCaret`：轮询 `engine_get_text_input_state`（available/ime_active/ime_mode/attention/selection/text），仅在该控件同时发布插入符且接受合成输入（`attention_point_valid && ime_active`）时启用合成输入，判定与 Godot 壳 `_sync_game_text_input_state` 一致。插入符 `attention_x/y` 用与指针一致的等比映射换算到视图坐标（新增 `InputMapping.mapCanvasToView`）。
- 画布视图成为 AppKit 文本输入客户端：合成内容经 `ime_preedit_cursor`（"start,length"）与 `ime_preedit` 选项下发，提交文本经 `TEXT_INPUT`（按标量发送，跳过 NUL/CR/LF）。合成期间回车/取消/退格/方向/Home/End/PgUp/PgDn 映射回引擎按键事件，未映射命令回退原始按键路径；未聚焦文本控件时按键路径与改动前一致。⌘V 作为提交文本送入游戏。
- 失焦、隐藏窗口、返回游戏库与关闭会话都会结束合成；关闭会话重置状态与 tracker。宿主只记录状态变化与提交标量数量，不记录正文。`ime_preedit` 目前仅被 Siglus provider 消费，KiriKiri 传统层忽略该选项、只接收提交文本——接缝清单 C 节已注明。
- `GameTextInputTests` 与 `tools/apple_host_ime_test.py` 通过（状态解析、激活判定、合成去重、命令映射、插入符几何）；工具同时生成「直达输入页」夹具（复制仓库内 KAG3 demo，`first.ks` 跳转到自带计算题 `[edit]` 页）。
- CUA 实机验收（隔离库导入夹具）：进入计算题页后日志出现 `game text input active (ime_mode=3, caret=51,146)`；输入 28、退格清空、⌘V 粘贴「你好」均在游戏输入框正确呈现；点击 OK 后游戏按 `str2num(f.input) == f.ans` 判定并显示「正解です！」，随后日志 `game text input inactive`。插入符随输入移动（51→79→101）。真实输入法合成的候选窗内容仍需系统输入法下人工确认。
- 本轮未改动引擎、ABI 与 provider。

### 2026-10-11：下一步排序盘点（库封面图 / 全屏 / 视频库）

- 盘点 Godot 壳后确认三项 macOS 侧仍存在的产品缺口：① 游戏库封面图（`native_cover_file_picker_open`、`detail.set_cover`/`detail.clear_cover`、`_resolve_cover_path` 的「相对游戏根 / 绝对路径」两种存储、自动发现，以及 VNDB 在线抓取 `_process_next_vndb_cover`）；② 全屏切换（`menu.fullscreen`，五语言）；③ 视频库（`nav.videos` 分区：导入/移除并清除进度、字幕轨道记忆、桌面端引导文案），其中条目数量受 IAP 商品 `com.aether.list.limit`（"永久解锁视觉小说库和视频库中的全部目录项目"）门控。
- 排序结论：下一步做 **库封面图（手动选择 + 自动发现 + 显示/清除，不含 VNDB）+ 全屏切换**——两者都属于「游戏库/通用宿主」，无私有依赖、无网络、可用界面与单测验收；随后做 **视频库**（不含 IAP 数量限制，理由见下）；VNDB 抓取与 IAP 数量限制单列，需联网/商店能力时再评估。
- 视频库的数量限制在 macOS 上暂不启用：该解锁项依赖真实 StoreKit 购买，而 macOS 当前 purchase 只能返回降级响应，启用限制会让用户永久无法解除。接缝清单 M 节已记为该决策点。

### 2026-10-11：Metal 取帧停顿根因与修复

- 复现并定位长期记录的「约 1 秒慢帧」：同工具 30 秒 1080p 串行基准中每轮恰好 1–2 个样本超过 900ms，933–981ms 全部落在 `drawable_acquire_ms`，其余样本取帧仅 0.03–0.05ms。根因是窗口无法出帧时仍调用 `nextDrawable`，其默认 1 秒超时把主线程卡满；SDK 头确认 `allowsNextDrawableTimeout = NO` 是「永久阻塞」而非「非阻塞」。
- 修复：新增 `PresentationGate`，无窗口/隐藏/最小化/被遮挡/drawable 尺寸为 0 时不申请 drawable，本 tick 丢弃并在下一次 tick 重试，状态变化写宿主日志且不计入 profile 样本；`shutdown()` 先挂起 presenter；无头基准用 `AETHER_HOST_ACTIVATE=1` 显式前置窗口，profile 工具与 `smoke --profile` 已默认启用，无样本时工具直接报「窗口被遮挡」而不是产生空 CSV。
- 证据（同工具同素材 30 秒 1080p）：修复前 deferred/direct max=968.18/959.61ms；修复后 max=68.46/18.92ms，无 >100ms 样本，取帧耗时全程 ≤0.05ms。直接提交（产品默认）最大 18.92ms、1 个样本超过 16.6ms。deferred 剩余尾部（68ms）来自 SwiftUI 延后调度本身。
- 回归：`MetalPresentationTests` 增补门控用例（通过）；KAG3+ONS 各 30 秒冒烟通过；TJS 自检四运行 16/16 像素对照仍为 0 差异（`out/apple_host/evidence/selftest-gate-022034/`）。模式覆盖同时归档：单源内核实现 20 个模式，多源模式 4/9/21/22 与 12/13/14 分别由 blend_rect2/3 承担，模式 6 无发射方。
- 本轮未改动引擎与 ABI；G1 仍未验收（缺两款真实标题与完整帧采样口径），但报告的慢帧已不再是取帧停顿。

### 2026-10-11：G1 回归验收（两款真实标题 + 1080p 完整帧）

- 真实标题 ①《夏雪》（KiriKiri，800×600，克隆副本运行，原目录不写入）：Metal 路径 `startup state: SUCCEEDED`、`native GPU frame` 取得原生纹理、桥 `failures=0`（textures=17、native_copies=652、仅截图 1 次回读）、三处同刻 engine/Metal RGB 差值 0、指针与回车推进、干净退出。55 秒 1080p 输出运行到真实场景（角色设定画面），桥 `failures=0`、同刻差值 0。证据 `g1-natsuyuki-metal/`、`g1-natsuyuki-software/`、`g1-natsuyuki-1080p/`。
- 真实标题 ②《40日40夜之雨》（ONScripter，800×600）：runtime provider `open_game => OK`，标题画面与 START/LOAD/EXIT 菜单正确渲染，三处同刻 RGB 差值 0，输入改变画面，干净退出。该 runtime 发布 CPU 帧（桥 textures=0），验证的是呈现与输入路径。证据 `g1-rain40-metal/`。
- 1080p 完整帧：合成 1920×1080 原生内容两轮各 60 秒、直接提交、窗口可见、无截图无输入——**两轮均 0 个样本超过 16.6ms**（#1 n=3519 p50/p95/p99/max=1.42/2.95/4.88/16.27ms；#2 n=3510 1.36/3.67/10.80/15.76ms）。真实标题《夏雪》1080p 输出 55 秒：p50/p95/p99=2.17/5.91/8.00ms，5/1216 个样本超预算，集中在开场影片与场景切换附近。含并行负载时同一素材曾出现 13/3495 离群，正式基准要求安静串行环境（已写入工具与 README）。证据 `g1-1080p-clean-1/`、`g1-1080p-clean-2/`、`g1-natsuyuki-1080p/`。
- P2/P0 覆盖矩阵：内核级由 `metal-bridge-tests` 覆盖混合（精确 alpha 算术、多源、box blur/mosaic）、遮罩三角形、普通三角形、越界/重叠、回读快照、批处理与 IOSurface 外部纹理；整帧级由上述两款标题的同刻 RGB 差值与 TJS 自检 16/16 零差异共同覆盖。
- 未列入前请用户确认：两款标题都不在 `doc/verified_games.md` 现有列表，按项目约定该表（含中英文）更新需用户确认后登记。G1 的其余证据已齐，闸门状态与采样方法写入 [Metal 实施清单](apple_host_metal_plan.md)。

### 2026-10-11：外部目录流程实测与交接

- 用真实标题走通「添加外部游戏目录」链路：把《夏雪》克隆副本登记为外部引用（`library.json` 记录 `externalPath`，不复制文件、不写原目录），经产品界面启动后 `startup state: SUCCEEDED`、`frame size 800x600`、`surface size -> 800x600 (game native)`，画面依次呈现汉化声明页、开场场景（含交叉淡入）与标题画面六个菜单项，会话以 `state: stopped`、`engine destroyed` 干净结束（ticks=13428，`unhandledPlatformRequests=0`）。这是 M2 外部引用路径第一次用真实标题端到端验证。
- 该次运行使用**软件绘制**（库默认设置，session.json `renderer=software`），验证的是宿主会话/库/输入/呈现链路，不构成 P2 桥证据；P2 证据仍是本日前的 smoke 与 profile 运行。
- 指针与键盘确实到达引擎：`input pointer type=1 at (204,236)`、`input key down vk=0xd`；游戏自身光标随后续点击移动。菜单点击未能完成，原因不是输入映射，而是 cua 坐标为真实系统点击、宿主窗口不在最前时点击落到别的窗口（宿主因此没有任何指针日志）。可行做法已写入 Metal 清单「交接与遗留」。
- 出处提示：《夏雪》本机副本带第三方推广水印与汉化补丁声明（禁商业使用、24 小时内删除、禁广泛转载、严禁移植到 PC 以外平台）；《40日40夜之雨》未见同类声明。登记公开列表前需要用户确认并考虑该声明。
- 用户已要求把后续工作交给另一代理：本期只做到「证据齐 + 文档更新」，`verified_games` 登记、更深流程验证（存档/读档）与剩余 Metal 项（异步回读、deferred 尾部）移交接手方。测试宿主进程已停止，临时副本位于 `/tmp/aether-g1.WOmIO8/`（克隆自 Downloads，可随时删除）。

### 2026-10-11：内核层小项（借鉴上游硬化项）

- 背景：对照 wamsoft/krkrz 与 krkrz_dev 的现代化线后，挑出「不改 ABI、不改行为、可验证」的小项落到我们的核（`packages/AetherKrkr`）。
- 修掉 6 处 release 构建 UB：`core/visual/LoadJXR.cpp` 三处与 `core/visual/gl/ResampleImage.cpp` 三处把暂存缓冲写成「只 `reserve()` 再按 `&buf[0]` 写」。`reserve()` 不改变 `size()`，该写法本身是 UB，且 release 会读到 debug 里已零初始化的字节。改为两种构建统一使用定长缓冲——也就是让 release 与一直作为像素对照基准的 debug 行为一致。
- 一处微优化：`LocaleConfigManager::GetText` 未命中时对同一 key 做两次哈希（`operator[]` 插入后再 `operator[]`），改为 `find` + `emplace`，保留记忆化语义与返回引用的稳定性。
- 新增原创夹具 `tests/fixtures/apple_host_stretch`：用 `Layer.stretchCopy` 的 stLinear/stCubic 覆盖现有夹具都没有的重采样路径，输入驱动重绘（冒烟工具可用）。它首次做到**跨渲染器同刻对比**：软件与 Metal 两次运行在 6/20/25 秒的 engine 帧 RGB 差值均为 0；Metal 运行内 engine/Metal 同刻差值同样为 0。
- 回归：核心库与宿主重编译通过；Metal 桥/呈现/输入/游戏内文字输入套件通过；KAG3+ONS 各 30 秒冒烟通过；`apple_host_stretch` 软件与 Metal 各 30 秒冒烟通过；`apple_host_selftest` 16/16 零差异。另有一次自检在 1080p 的 19/22 秒出现局部差异，重跑干净——判定为该自检「按键后 1 秒采样、两进程相位可能差一 tick」的固有抖动，与本次改动无关（Debug 下 ResampleImage 的分支本来就与改动后等价）。
- 提交：子模块 `packages/AetherKrkr` 提交 `c8c1b1e`（PR 分支 `fix/core-staging-buffers`），父仓同步 gitlink 与夹具。spec 的「不改引擎核心」非目标补充了说明：不做架构/ABI 改写，允许正确性类最小修补（与该包既有兼容修复惯例一致）。
- 已按子仓库贡献流程开 PR：[AetherKiri/AetherKrkr#3](https://github.com/AetherKiri/AetherKrkr/pull/3) —— 分支 `fix/core-staging-buffers` 基于最新 `main` 且只含本次 1 个提交（head `c8c1b1e`），改动 3 个文件；仓库没有 CI 工作流，GitHub 报告 `MERGEABLE`、检查项为空。PR 标题、正文与子仓库提交信息**只写内核视角**（改动内容、安全性论证、模块级验证），不出现宿主/本项目/夹具/自检等本仓语境（按用户要求重写过一次）。**合并后**需把父仓 gitlink 从 `c8c1b1e` 重新指向 `main` 上的结果提交；该分支保留到合并完成（父仓当前 pin 的正是 PR head）。

## 下一步队列

1. [x] 接缝清单 v0.1（交付物 A）+ 三份文档建立
2. [x] `xcodegen` 2.46.0 安装
3. [x] K 节 TASK 1-7 逐项盘点（见清单 v0.2）
4. [x] `bridge/apple_host/` CMake 目标 `aether_apple_host_core`（**交付物 B**）
5. [x] `apps/apple_host/` SwiftUI 工程骨架 + EngineSession + 软件帧上屏（**交付物 C 核心**）
6. [x] 输入透传（`engine_send_input`）+ CPU 基线 + 日志行为确认（**G0 达成**）
7. [x] **M1/G1 回归**：drawable 慢帧定位修复；两款真实标题同刻 P2/P0 差值 0；合成 1080p 两轮 0 超预算。仅剩「把两款标题登记进 verified_games（需用户确认）」这一形式项（2026-10-11）
8. [x] **M2 目录 MVP**：库→导入→游玩→返回→冷启动恢复；设置、菜单/快捷键、五语言
9. [x] **M3 首项**：诊断日志落盘/导出，启动错误详情与回库恢复
10. [x] **M3 独立媒体**：视频播放控制、文本字幕、进度恢复
11. [x] **M3 屏幕输入**：虚拟按键、原生提交文字、焦点释放
12. [x] **M3 dialog 实现**：原生平台请求弹窗与响应；私有运行时实机验收待补
13. [x] **M3 Minori 影片实现**：同游戏引擎播放、矩形呈现、输入隔离与完成响应；真实 VM 验收待补
14. [x] **M2 游戏库扩展**：重命名、只移除记录、外部目录引用（macOS 非沙盒基线）
15. [x] **M2 ZIP 导入**：单游戏入口识别、受限解压与复制入库
16. [x] **M3 通用 text_input 实现**：原生初始值输入、混合队列及协议响应；真实 provider 验收待补
17. [x] **通用功能**：Debug 冷启动基准（软件/Metal，本地原创 fixture）
18. [x] **M3 Purchase 降级基线**：无 StoreKit provider 时确定性完成请求；真实 IAP 待接入
19. [x] **M3 翻译**：本地翻译模型设置、选项透传与状态展示；真实模型加载待私有 provider
20. [x] **通用宿主**：`call_native` 应答、未处理请求可观测、接缝清单 D 节补全 softpal_*/minori_select
21. [x] **M3 游戏内文字输入**：编辑控件合成输入、提交文本、插入符与候选窗定位；真实输入法候选窗人工确认待补
22. [ ] **库功能：封面图（下一步）**：手动选择/清除、游戏目录自动发现、列表与详情页显示、偏好随索引持久化；VNDB 在线抓取单列
23. [ ] **通用宿主：全屏切换（下一步，随封面图一起）**：游戏页与菜单入口、五语言文案、退出恢复
24. [ ] **M3 视频库**：列表/导入/移除（含进度清理）、字幕选择记忆、桌面引导文案；IAP 数量限制在 macOS 暂不启用
25. [ ] **M3 后续**：IAP provider 与更新器逐项迁移（macOS 上 purchase 与现产品同为降级响应，真实 IAP 属 iOS/M4 范围）
26. [ ] **Minori 暂缓**：音频/文字框/选择/存档及真实游戏验收，待用户重新安排
27. [x] 同步 spec、接缝清单与进度
28. [ ] **交接给后续代理（2026-10-11 移交）**：用户确认后登记 `verified_games`（含中英文，注明平台/范围与出处、汉化声明考量）；可选做更深流程验证（存档/读档）；剩余 Metal 项为 `begin_read/poll_read` 异步回读与 deferred 调度尾部
29. [x] **内核层小项（2026-10-11）**：release UB 暂存缓冲 6 处 + `LocaleConfigManager::GetText` 单次查找；新增重采样夹具 `apple_host_stretch`（含跨渲染器同刻对比）。子模块 `c8c1b1e`，PR [AetherKrkr#3](https://github.com/AetherKiri/AetherKrkr/pull/3)

## 变更记录

| 日期 | 变更 |
|---|---|
| 2026-10-10 | 项目立项；文档骨架；接缝清单 v0.1 |
| 2026-10-10 | 接缝清单 v0.2（K 项清零）；M0-B 宿主核心库构建通过 |
