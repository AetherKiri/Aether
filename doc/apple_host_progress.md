# Apple 原生宿主进度（Living Document）

- 最后更新：2026-10-11
- 关联：[spec](apple_host.md) · [接缝清单](apple_host_seam_inventory.md) · [UI spec](apple_host_ui_spec.md) · [UI 计划](apple_host_ui_plan.md) · [iOS 移交说明](apple_host_ios_handoff.md)

---

## 里程碑状态

| 阶段 | 状态 | 备注 |
|---|---|---|
| M0 接缝盘点 + 骨架 | 🟢 完成 | 交付物 A ✅ v0.2；交付物 B ✅；交付物 C ✅ **G0 达成**：KAG3 demo 实跑、输入透传验证、CPU 基线 ~35%（software@640x480）、日志行为对齐确认；KAG3 + ONS 各 310 秒验收通过 |
| M1 Metal 绘制桥 | 🟢 G1 证据齐（待用户确认标题登记） | 2026-10-11 回归：两款真实标题同刻 P2/P0 差值为 0；合成 1080p 两轮 0 超预算（max 16.27/15.76ms）；取帧停顿已定位修复。详见 [Metal 清单](apple_host_metal_plan.md) |
| M2 SwiftUI MVP | 🟢 目录导入 MVP | 库/导入/启动/返回/封面/全屏/设置/菜单快捷键/五语言已接入；G2 的 KAG3+ONS 目录流程经界面验证 |
| M3 功能迁移 | 🟡 进行中 | 诊断与独立视频/文本字幕完成最小流程；设置/产品完整对齐按 UI spec 的 P1–P6 推进，不能将 MVP 视为完整迁移 |
| M4 iOS/iPadOS | ⚪ 未开始 | 闸门 G4；起步交接见 [iOS 移交说明](apple_host_ios_handoff.md) |

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

### 2026-10-11：P1 设置事务与分组页面

- 增加SettingsStore/SettingsDraft，版本化文件、一次旧偏好迁移、保存前校验、损坏文件保留；有效配置与编辑草稿隔离。失败保存取消待定离开/退出请求，原值与草稿保留。
- 设置成为第四主导航目的地，分组页面替换sheet；保存与离开确认已接入，关闭窗口保留SwiftUI原delegate，退出应用处理未保存设置。游戏/视频启动也经过草稿离开检查。
- 接入插件加载/Mock/错误日志的实际engine options；真实初始化应答测试通过。翻译模型草稿、关于版本/社群、五语言协议与GPL/附加许可/第三方许可证资源已接入。
- Debug构建、存储测试（含未知枚举稳定回退）、真实ShellModel导航/保存/失败测试、打包文档和五语言检查通过；工具为`tools/apple_host_settings_tests.py`。
- 本轮30秒回归：KAG3 Metal direct输入推进、截图、退出通过；ONS软件帧经Metal呈现的对应口径也通过。证据`settings-p1-smoke/kag3/`与`settings-p1-ons/`。最初把ONS加入direct租约检查触发全零租约断言，该模式不适用于软件帧，不作为ONS验收；未修改断言来制造通过，30秒测试也不替代五分钟G0。
- CUA仅完成隔离库的四导航、分组设置和初始保存禁用状态；随后原生连接pipe关闭，重连失败、inventory超时。窗口关闭/退出/完整五语言布局仍待实际CUA补验，P1不标为完全验收。


### 2026-10-11：Godot 产品与 Apple UI 对齐调查

- 已检查原版页面/设置builder、草稿存储、engine options、画面增强边界、内容与会话数据、对应测试及Apple实现。CUA查看既有Godot导出游戏库、设置与渲染页，未修改偏好。源码为功能基线，导出能力可能落后。
- 调整设计方向：主导航四目的地、封面集合与独立详情；设置分组/草稿/保存语义恢复，原生控件承载同等功能；关键操作保留窗口内入口。
- 已形成 [完整差异与目标 spec](apple_host_ui_spec.md) 与 [分阶段计划](apple_host_ui_plan.md)。P0完成，P1–P7尚未实施；本轮仅文档改动，当前应用UI未更改。
- 下一步优先P1：版本化SettingsStore/草稿、分组设置页、保存离开确认、已有兼容性option和关于功能接入；随后P2封面库/主题，P3基础画面设置，P4会话诊断，P5增强。更新器仍最后，Minori/G1继续暂缓。

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
- 排序结论：库封面图与全屏切换已完成；视频库、主页和原生菜单对齐随后完成。VNDB 抓取与 IAP 数量限制单列，需联网/商店能力时再评估。
- 视频库的数量限制在 macOS 上暂不启用：该解锁项依赖真实 StoreKit 购买，而 macOS 当前 purchase 只能返回降级响应，启用限制会让用户永久无法解除。接缝清单 M 节已记为该决策点。

### 2026-10-11：游戏库封面、全屏与 Game 菜单完善

- 游戏库索引新增封面路径与清除抑制标记：游戏目录内使用 `game://` 相对路径，外部图片保留绝对路径；启动和导入时自动扫描根目录、`data`、`assets`、`image`、`images` 下的常见封面文件名。清除只修改索引，不删除图片，并阻止下次启动重新自动发现。
- 详情页支持手动选择/清除封面，列表缩略图和详情大图显示封面；封面索引重载、老索引兼容、自动发现和手动路径均由 `GameLibraryTests` 覆盖。VNDB 在线抓取仍不在 macOS 宿主范围内。

### 2026-10-11：Apple 菜单与库路由对齐

- 文件菜单补齐刷新并统一使用 `⌘R`；开始游玩不再占用该快捷键。
- 原生显示菜单补齐游戏库 `⌘1`、视频库 `⌘2`、主页 `⌘3` 和全屏 `⌘⌃F`；游戏运行时导航、设置和导入动作禁用。
- 视频库索引保存为 `video-library.json`，可从库中重新打开视频；移除条目会同步清除 `media-progress.json` 中的进度，字幕选择按视频路径保存到 `media-subtitles.json`。主页显示游戏/视频数量和最近游玩条目，帮助菜单提供 QQ 交流群入口。
- 游戏页和 Game 菜单均提供全屏切换，进入游戏前的窗口状态在返回游戏库时恢复；Game 菜单的全屏项跟随窗口通知同步勾选状态。
- Game 菜单补齐运行中操作：日志显示开关、在访达中显示当前游戏目录、带保存提示的重新启动；运行中/库态的禁用状态随会话切换更新。CUA 已验证库态禁用、运行态菜单、重启确认/重启会话、全屏切换和日志面板。

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

### 2026-10-11：兼容三连（platformTag / 三态回执 / 插件解析顺序）

- 依据：对照上游 `doc/GenericPluginLoading.md`（插件解析顺序、generic 下 Win32 API 空 stub 化、「游戏把 `kirikiriz_generic` 误当主机判定、应改用 `System.platformTag`」）。
- **`System.platformTag`**：新增静态属性与 `TVPGetPlatformTag()`（`core/base/SystemIntf.{h,cpp}`、`core/environ/stubs/ui_stubs.cpp`），返回 `windows/linux/macos/android/ios/unknown`。与返回架构名的 `System.platformName`（ARM64/x86_64）区分。实机验证：夹具画面显示 `tag=macos`。
- **三态回执**：`core/utils/DebugIntf.h` 定义 `TJSCompatState{loaded,unimplemented,unavailable,failed}` 与 `TVPAddCompatReceipt()` / `TVPGetCompatReceiptsJSON()`（实现放在已有 spdlog 与有界存储的 `core/plugin/PluginCallTracer.cpp`）。每个 `(feature,state)` 只上报一次，输出稳定可 grep 的一行 `[Compat] feature=… state=… detail=…`，并作为 `compat_receipts` 字段进入 `engine_get_plugin_debug_info`（glue 侧 `bridge/krkr2_runtime/src/krkr2_legacy_engine_api.cpp`）。已接入调用点：插件加载路径（proxy/mock stub → `unimplemented`；无实现 → `unavailable`）与桩类（`dmmcloud.dll` → `unavailable`；`layerExSubImage/Color/Mosaic` 回调 → `unimplemented`）。
- **插件解析顺序**：核实结论是**无需改动**——我们不做 PE DLL 磁盘搜索，`TVPLoadPlugin → TVPLoadInternalPlugin → ncbAutoRegister::LoadModule` 走的是「模块名 → 注册表」；`tTVPPluginHolder` 的 exe 邻目录回退在本树里是 `#if 0` 且该类已无调用方（死代码），上游修的顺序问题（generic 版缺少 storage 优先）不适用于本架构。已在文档记录该判断。
- 新增原创夹具 `tests/fixtures/apple_host_compat`：探针覆盖 platformTag、缺失插件、layerEx*/dmmcloud 兼容类，输入驱动重绘，结果同时画进画面与引擎日志。证据 `out/apple_host/evidence/kernel-compat-receipts/`（Metal 30 秒冒烟 PASS，engine/Metal 同刻差值 0），回执行 `tests/fixtures/apple_host_compat/krkr2.log:17`。
- **回执照出一处既有缺陷，并已修复**：`NCB_ATTACH_CLASS` 把成员写在类对象上，只有**挂载之后创建**的实例才看得到。夹具里 `primary` 是 link 之前建的（`typeof primary.mosaic` = undefined、调用报 `Member "mosaic" does not exist`），而 link 之后新建的图层正常（`lateMosaic` = Object，回执也照出来了）——所以不是 ncbind 失效，而是**挂载时机依赖**：游戏若在创建图层之后才 `Plugins.link`，功能会静默丢失。
- 修法（先例是引擎已为同类原因预加载 `krkrgles.dll`）：把**纯成员挂载**的 16 个兼容模块加入启动预加载清单（`core/plugin/PluginImpl.cpp`）——addFont、fpslimit、json、layerExAreaAverage、layerExColor、layerExMosaic、layerExSubImage、messenger、msdfrender、qrcode、saveStruct、shellExecute、stdio、tasktray、tftSave、toml、windowExProgress；带类注册或存储介质副作用的模块仍按需加载，`plugin_load_mode=aether_all` 本来就全载。
- 修复验证：夹具中 link **之前**创建的图层现在 `mosaic0=1`、`subImage=1`、`colorize=1`，并触发 `mosaic`/`copySubImage`/`colorize` 三条 `unimplemented` 回执；KAG3+ONS 各 30 秒冒烟通过；真实标题《夏雪》800×600 原生 Metal 路径 30 秒通过（桥 `failures=0`、同刻差值 0）。证据 `out/apple_host/evidence/kernel-eager-natsuyuki/`。
- 仍未处理的小项（另行跟进）：`new DMMCloud()` 报 `Invalid argument count`（类已注册但构造签名不匹配）；夹具里 `new Zlib().version()` 报成员不存在（需确认是兼容类注册问题还是探针写法问题）。
- 回归：核心与宿主重编译通过；KAG3+ONS 各 30 秒冒烟通过；`apple_host_compat` Metal 30 秒冒烟通过（同刻差值 0）。本轮未改 ABI、未改既有返回值。
- 已按子仓库贡献流程开 PR：[AetherKiri/AetherKrkr#4](https://github.com/AetherKiri/AetherKrkr/pull/4) —— 分支 `feat/compat-platform-tag-and-receipts` **重绕到最新 `main`**（原分支叠在上一个 PR #3 的提交上，已 `rebase --onto origin/main`），现在含 2 个提交（`9f39cfa` 回执+platformTag、`8be4bbc` 挂载顺序修复），head `8be4bbc`；仓库无 CI 工作流，GitHub 报告 `MERGEABLE / CLEAN`。PR 标题与正文已同步为「report … and drop the link-order dependency」，正文同样只写内核视角。**合并后**需把父仓 gitlink 从 `8be4bbc` 重新指向 `main` 上的结果提交。

### 2026-10-11：Metal 内容 serial publication 去重

- `GodotTexture2D` 增加内部 `ContentSerial()`；成功的 CPU/GPU 写入才推进内容 serial。
- Apple host 的 surface 缩放缓存按源句柄+内容 serial 去重 GPU copy；GPU publication 按源句柄、内容 serial 与输出尺寸去重 sink 推送。CPU fallback 会清除去重 key。
- 同一 Debug 构建、KAG3、30 秒、1920x1080 drawable 对照：软件上传基线 host-work p50/tick-to-GPU 为 `1.067/1.677 ms`；旧 Metal snapshot 为 `0.893/1.317 ms`；当前 Metal direct 为 `0.217/0.890 ms`。
- Metal direct 仅 `462` 次 acquire、`202` 次 lease 提交，`1338` 次 `published_acquire_fast_unchanged`；旧 snapshot 为 `1748` 次 native 查询和 snapshot。direct 输入、截图、退出通过，RGB max diff=0，failures=0、leases_live=0。
- 该数据是单机 Debug、KAG3 单轮对照，不宣称 Release/G1 或所有真实标题性能结论；下一步需重复配对并覆盖静态标题。

### 2026-10-11：Godot native 与 Apple Host direct 实际对照

- 使用同一 Debug 构建、同一 KAG3 `demos/aetherkiri-kag3/data`、同一 1920x1080
  surface；Godot 使用真实非 headless Metal 路径（`godot_native_gpu_presented`，`rd_gpu=1`）。
  Godot `step_render_probe` 的 1800 帧测量窗口为 `107.63 FPS`（约 `9.29 ms/frame`）。
- Apple Host profile 使用同素材、真实 1920x1080 drawable、30 秒串行运行；两轮分别正序和反序，
  结果如下。这里的 `tick-to-completion` 是提交到 GPU command completion 的耗时，呈现行数受窗口
  60Hz 节奏限制，不能与 Godot 的 uncapped probe FPS 直接相除。

| Apple Host 路径 | 呈现样本/秒 | tick-to-completion p50/p95/max (ms) | 超 16.6ms |
|---|---:|---:|---:|
| deferred（旧路径）正序/反序 | 57.83 / 57.83 | 5.570/7.287/28.425 / 5.794/7.547/30.373 | 5 / 5 |
| direct（当前路径）正序/反序 | 57.87 / 57.87 | 1.388/1.875/7.469 / 1.504/1.894/7.509 | 0 / 0 |

- direct 相对 deferred 的 GPU 完成 p50 降低约 75.1%/74.0%，两轮方向一致；但这不能推出
  “direct 比 Godot native 快 X%”。在当前可复现实验中，Godot native 的共同可见指标是约
  107.6 FPS，Apple Host 的窗口呈现受 60Hz 限制；两者尚未具备同一帧调度与统计口径，故不宣称
  Godot native 的端到端 FPS 提升。证据目录：`out/apple_host/evidence/godot-native-ab-20261011/`
  与 `godot-native-ab-20261011-reverse/`。

- 随后用仓库内 `.devtools/godot/Godot.app` 重新导出 macOS Debug app，并以重建产物复测：
  Godot native 为 `119.36 FPS`（`godot_native_gpu_presented`，`rd_gpu=1`）；同轮 Apple Host
  deferred/direct 呈现样本为 `57.27/57.87 s^-1`，completion p50 为 `5.353/1.396 ms`，
  p95 为 `7.491/2.484 ms`，最大值为 `33.809/9.459 ms`，超 16.6ms 为 `5/0`。证据目录：
  `out/apple_host/evidence/godot-native-rebuilt-ab-20261011/`。

### 2026-10-11：uncapped offscreen benchmark 口径

- Apple Host 新增 `--offscreen` benchmark：不请求 `CAMetalLayer.nextDrawable()`，每个固定
  `1/60` engine tick 都把当前帧提交到 1920x1080 Metal render target；`--wait-gpu` 用于另一种
  每帧等待 completion 的延迟口径。普通 profile 仍保留真实窗口/60Hz 呈现测试。
- 同一 Debug KAG3、30 秒、同一 offscreen target 的提交吞吐（不等待 GPU）为：deferred
  `143.2 tick/s`，direct `634.9 tick/s`。direct 使用当前 FrameLease，deferred 使用旧的
  native snapshot；两者都不把 GPU completion 等待计入 tick 吞吐。
- 同条件逐帧等待 GPU completion 时为：deferred `50.27 tick/s`（p50 `16.883 ms`），direct
  `52.47 tick/s`（p50 `16.437 ms`）。这说明 direct 的主要收益在提交路径；若把 GPU completion
  等待纳入端到端吞吐，收益约 4%，不能引用提交吞吐的 4.4 倍作为最终 FPS 提升。
- 重建后的 Godot native 非 headless probe 为 `116.04 tick/s`（3600 tick、约 31 秒）；它与
  Apple Host 的 offscreen 提交吞吐属于同一 uncapped wall-clock 类指标，但 Godot 仍包含
  Godot viewport/TextureRect 调度，Apple Host benchmark 不包含 SwiftUI/scanout。证据目录：
  `out/apple_host/evidence/offscreen-submit-20261011/`、`offscreen-completion-20261011/`。

### 2026-10-11：复杂 KAG3 场景实际帧率

- 使用 KAG3 的 `snow.ks` 雪粒插件、17 个雪粒、多层图层和 crossfade 过渡建立临时复杂场景
  副本；两边使用同一副本、同一 Debug 构建、1920x1080、固定 `1/60` tick、30 秒 offscreen
  benchmark。Godot native 非 headless probe 为 `138.62 tick/s`。
- 不等待 GPU 的 uncapped 游戏帧循环：Apple deferred `329.27 tick/s`，Apple direct
  `531.03 tick/s`。相对同一 Godot probe，direct 约 `3.83x`，deferred 约 `2.38x`；direct
  相对 deferred 约 `1.61x`。这仍是提交吞吐口径，不能当作显示器实际 FPS。
- 逐帧等待 offscreen GPU completion：Apple deferred `54.33 tick/s`（p50 `15.113 ms`），
  Apple direct `57.23 tick/s`（p50 `14.633 ms`），direct 约提升 `5.3%`。Godot 当前 probe
  尚未加入等价 GPU fence，因此不把这组 completion 数字与 Godot 的 `138.62` 直接比较。
- 证据目录：`out/apple_host/evidence/complex-offscreen-submit-20261011/` 与
  `complex-offscreen-completion-20261011/`；复杂场景副本为临时测试数据，不进入仓库。

### 2026-10-11：真实《夏雪》对照基准

- 新增 `tools/real_game_benchmark.py`，固定真实游戏目录、1920x1080、60 Hz engine tick，
  自动串行运行 Godot native probe、Apple deferred/direct 提交吞吐和 Apple deferred/direct
  逐帧 GPU completion，并输出 `result.json` 与 `REPORT.md`。游戏路径只进入本地证据目录，
  不写入仓库。
- 本机 Debug 实测 30 秒：Godot native wall-clock tick loop 为 `140.53 tick/s`；Apple
  不等待 GPU 的 deferred/direct 为 `203.40/301.77 tick/s`；逐帧等待 1920x1080 GPU
  completion 的 deferred/direct 为 `42.30/47.10 tick/s`。
- direct 相对 deferred 的收益在提交口径为 `1.48x`，在端到端 GPU completion 口径为
  `1.11x`。因此不能把 `301.77/140.53` 宣传成“实际 FPS 提升”；Godot probe 没有同等
  的逐帧 GPU fence，Apple completion 与 Godot wall-clock 只能并列说明，不能合并为单一
  speedup。可见窗口 FPS 仍应另做受显示器刷新节奏约束的呈现测试。
- 证据目录：`out/apple_host/evidence/natsuyuki-real-game-20261011/`；该目录为本地生成物，
  未纳入版本库。

### 2026-10-11：UI P2 集合与独立详情切片

- 按Godot封面库的信息结构恢复主导航四目的地、封面网格/列表、独立详情、窗口内导入/外部引用/刷新/封面编辑；搜索和返回滚动保留。主页精确统计仍在P4。
- 视频集合读取真实进度/总时长，旧无总时长条目保持兼容；移除确认清理播放与字幕记忆，原视频保留；清理/索引错误可见。
- Debug构建、真实ShellModel/设置/五语言行为检查通过；媒体三套测试通过，含播放器实测总时长持久化。CUA隔离30条目、长中日韩英标题，点验搜索/列表/详情返回/滚动、视频移除取消与确认，以及P1设置继续/丢弃/保存英文/窗口关闭和应用退出取消。
- 四主题、完整多尺寸/五语言/VoiceOver验收尚未完成；详见[实施计划](apple_host_ui_plan.md)与[当前能力矩阵](apple_host_ui_spec.md#6-实施状态2026-10-11)。

### 2026-10-11：UI P2 四主题与设置迁移

- 接入Godot dark/classic/warm_dark/warm_light的内容palette，主题草稿保存后生效；原生控件明暗协调，分组/卡片/次要文字使用主题tokens。主题不改变引擎option或游戏色彩。
- Settings schema v2兼容v1原字段，未知主题稳定回退；读取不重写旧文件，保存失败保留有效值。四主题持久化/丢弃/重启、损坏/未来schema保留与真实ShellModel行为检查通过。
- Godot源码配色交叉检查、正文/次要文字及原生白字按钮专用底色对比度通过；Increase Contrast提升次要文字与边框，无新增自定义动画。
- Debug构建通过；CUA实测四主题保存切换、深色重启恢复，截图留`out/apple_host/evidence/ui-themes/`。英文界面/渲染分类已记录，继续分类时原生pipe关闭且重连失败，五语言全布局、VoiceOver/完整键盘、多尺寸与系统Reduce Motion仍待验收，P2未宣称全部完成。

## 下一步队列

### 性能基准隔离补充

- `apple_host_profile.py` 清除全部继承的 `AETHER_HOST_TEST_*` 注入变量，避免浏览器、Purchase、影片和输入测试动作干扰串行 Metal 测量。保留工具显式设置的 profile、呈现尺寸和调度参数。
- 本次仅验证工具语法与环境隔离代码，不把它作为新的性能提升数据；下一次性能对照仍需重新运行完整基准。

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
22. [x] **库功能：封面图**：手动选择/清除、游戏目录自动发现、列表与详情页显示、路径随索引持久化；VNDB 在线抓取单列
23. [x] **通用宿主：全屏切换**：游戏页与 Game 菜单入口、五语言文案、退出恢复
24. [x] **M3 视频库 MVP**：列表/导入/移除（含进度清理）、字幕选择记忆已接入（`c5d9363a`）；搜索/卡片/移除确认与完整播放器交互仍在 UI P2/P4；IAP 数量限制在 macOS 暂不启用
25. [ ] **M3 后续**：IAP provider 与更新器逐项迁移（macOS 上 purchase 与现产品同为降级响应，真实 IAP 属 iOS/M4 范围）
26. [ ] **Minori 暂缓**：音频/文字框/选择/存档及真实游戏验收，待用户重新安排
27. [x] 同步 spec、接缝清单与进度
28. [ ] **交接给后续代理（2026-10-11 移交）**：用户确认后登记 `verified_games`（含中英文，注明平台/范围与出处、汉化声明考量）；可选做更深流程验证（存档/读档）；剩余 Metal 项为 `begin_read/poll_read` 异步回读与 deferred 调度尾部
29. [x] **内核层小项（2026-10-11）**：release UB 暂存缓冲 6 处 + `LocaleConfigManager::GetText` 单次查找；新增重采样夹具 `apple_host_stretch`（含跨渲染器同刻对比）。子模块 `c8c1b1e`，PR [AetherKrkr#3](https://github.com/AetherKiri/AetherKrkr/pull/3)
30. [x] **兼容三连（2026-10-11）**：`System.platformTag`、三态回执（日志 + `engine_get_plugin_debug_info.compat_receipts`）、插件解析顺序核实（无需改）。新增夹具 `apple_host_compat`；PR [AetherKrkr#4](https://github.com/AetherKiri/AetherKrkr/pull/4)，子模块 head `9f39cfa`
31. [x] **内核已修：兼容成员挂载不再依赖 link 顺序**：16 个纯成员挂载模块启动即注册（先例 `krkrgles.dll`）；未修的小项见下条
31b. [ ] **两处兼容小项待查**：`new DMMCloud()` 报 `Invalid argument count`；`new Zlib().version()` 报成员不存在（可能只是探针写法/注册方式差异）
32. [ ] **内核后续：内存可观测（借鉴 `MemoryDesign.md`）**：分配头带 tag + `AllocTagScope` 标签栈，让"谁吃掉了内存"可回答；当前只有粗粒度 `engine_get_memory_stats`

33. [ ] **产品 UI/设置完整对齐**：调查 P0 已完成；P1核心、P2集合/详情与四主题已接入，完整CUA/无障碍验收待补；P3a–P3d、P4a/P4b/P4d/P4e/P4f、可停靠诊断控制台（含标记/慢帧捕获/快照/截图/自检）、场景测试入口、P5a 画面增强、P5b（FSR1 EASU/RCAS + 双三次/Lanczos 链步骤 + kind/预设/自定义链）、P6（macOS 首次使用双文档协议门：隐私协议 + App Store 额外声明 + 内置 Demo + VNDB 在线封面）已接入并通过行为回归与真实CUA；P4 其余（RFVP 编码仍按能力缺口记录），P5b 其余 Godot 算法与预设，P7 见 [实施计划](apple_host_ui_plan.md)（视频库暂停维护）。

## 变更记录

| 日期 | 变更 |
|---|---|
| 2026-10-10 | 项目立项；文档骨架；接缝清单 v0.1 |
| 2026-10-10 | 接缝清单 v0.2（K 项清零）；M0-B 宿主核心库构建通过 |


### 2026-10-11：UI与设置语义复核

- 对照Godot真实设置builder、草稿snapshot和应用handler，补充[UI spec](apple_host_ui_spec.md#7-复核后的设置契约与差异追踪)逐字段映射；区分控制入口与面板、日志显隐与diagnostic profile、引擎管线与呈现方式，明确已有engine option和待迁移增强算法。
- 保留已提交P1/P2成果；补充[执行队列](apple_host_ui_plan.md#复核后的执行队列与阶段门槛)，P3拆为能力回退、画布输出、采样、调度四个可独立验证切片。关于内的社群、设置容器、下次启动生效等产品差异显式记录。
- 本轮文档交付不包含工作区既有P3渲染草稿。该草稿构建成功不等于行为/交互验收完成；CUA连接明确构建路径后仍报告native pipe关闭，未新增视觉验收。


### 2026-10-11：UI P3a能力检测与安全回退

- 统一HostCapabilities，启动前显示设备/呈现器/翻译provider状态；原生Metal与软件诊断命名；未迁移画布/输出/FPS/增强/profile明确说明。
- 原生激活失败关闭部分创建会话后重建软件引擎，保留Metal偏好；运行中显示失败退图像但保留引擎管线，游戏继续推进。设置/回退游戏页与诊断报告分别显示请求、实际引擎、呈现方式、原因；新会话重试。
- 实际引擎故障注入、KAG3软件/原生启动、直通lease清理、降级连续性、generation重试、真实错误码及设置/集合/五语言测试通过；Debug构建与KAG3 30秒Metal直通输入/截图/退出回归通过，证据`out/apple_host/evidence/ui-p3a-native/`。
- CUA连接仍报native pipe关闭，新增页面交互未验收。P3a行为已验证但UI验收待补；下一步P3b画布/输出，P3c采样、P3d调度随后推进。

### 2026-10-12：UI P3b画布与输出

- `RenderGeometry` 将逻辑游戏画布与宿主输出分离，支持 `Game Native` / `Display Fit` 和 `Original` / `1080p` / `2K` / `4K`，按原始比例计算目标尺寸并限制 4K 上限；输入指针与 IME 插入符复用同一几何映射。
- `HostSettings` schema 从 v2 升为 v3，旧 v1/v2 配置兼容；旧配置保持 original 输出语义，新安装默认 1080p。Metal 输出缩放在 GPU 命令中完成，按 frame revision 避免复用仍在 GPU 使用的中间纹理；软件路径提供等价缩放和分配失败回退。
- `python3 tools/apple_host_settings_tests.py`通过，覆盖迁移、几何、软件/Metal、输入、IME、真实引擎和 lease 清理；Debug 构建通过。
- 实际 KAG3 30 秒 Metal direct smoke 通过：逻辑帧 640×480，输出 1440×1080；`leases_acquired=446`、`leases_submitted=446`、`leases_completed=446`、`leases_live=0`、`lease_failures=0`，三处 Metal RGB max diff=0。证据：`out/apple_host/evidence/ui-p3b-1080p-rerun/kag3/`。
- CUA 使用 `/Users/colorcard/Aether/out/apple_host/derived/Build/Products/Debug/AetherHost.app` 验证设置页：渲染分类可见画布模式/输出分辨率，切换“适应显示”和“1080p”，保存后显示“设置已保存”，保存按钮禁用。
- P3b 完成；下一阶段为 P3c 采样算法，P3d 调度仍待设计和验证。P3a 页面状态的历史待补不影响本轮 P3b CUA 证据。

### 2026-10-12：UI P3c采样算法

- 对照 Godot `main.gd` 确认 `smooth` 是 `linear` 兼容名，默认 `bicubic`；实现并命名对齐 nearest、linear、Catmull-Rom bicubic 4×4 与 Lanczos 半径 3。
- `HostSettings` schema v4 新增 `upscaleAlgorithm`；v1/v2/v3 旧配置迁移为 linear，新安装默认 bicubic，保存时规范化 smooth；设置页提供五语言采样选择器和负载说明。
- Metal shader 与软件 fallback 使用同一采样语义；输出中间纹理按尺寸/frame revision 管理，最终呈现不重复应用输出核；诊断记录有效算法。
- `python3 tools/apple_host_settings_tests.py`通过，含 CPU/GPU 四核对照、迁移、输入/IME、真实引擎和 lease 清理；Debug 构建通过。
- KAG3 30 秒 Metal direct smoke 四轮全部通过：`nearest`、`linear`、`bicubic`、`lanczos` 均无 RGB 差异、Metal bridge failures=0、lease failures=0、live=0。证据目录：`out/apple_host/evidence/ui-p3c-nearest/`、`ui-p3c-linear/`、`ui-p3c-bicubic/`、`ui-p3c-lanczos/`。
- CUA 验证真实构建窗口渲染页显示四个采样选项，双三次可切换并显示设置已保存；测试后恢复线性偏好。
- P3c 完成；下一阶段 P3d 调度，FPS 与模拟时间策略尚未开放。

### 2026-10-12：P3d 调度交接记录

- 本轮已完成 P3d 的现状调查，尚未修改实现；工作区在提交 `c959d3a7` 后保持干净，P3c 已推送到 `origin/feature/apple-native-host-m0`。
- Apple 宿主当前仍由 `EngineController.startLoop()` 使用主 RunLoop 的固定 60 Hz `Timer`，每次调用 `session.tick(deltaMS: 16)`；`offscreen` benchmark 是独立的无限速路径，不应成为产品调度实现。
- ABI 已有 `fps_limit` 选项。Godot 宿主会把 `fps_limit_enabled ? target_fps : 0` 下发，并在 `_process(delta)` 中把真实帧间隔传入 runtime；Apple `HostSettings` 当前为 schema v4，尚无 `fpsLimitEnabled`/`targetFPS`，`engineOptions` 也尚未下发 `fps_limit`。
- P3d 不应通过提高 Timer 频率并继续传固定 16 ms 来制造 FPS；必须分开验证模拟时间、引擎 render 限频和 drawable 呈现节奏。关闭限制时应跟随显示节奏（优先 DisplayLink，保留无显示设备时的 Timer fallback）；启用限制时目标值为 60/80/90/120/144，默认关闭、目标 80。
- 下一代理的最小完整切片：schema v5 与 v1–v4 迁移；设置页五语言 FPS 开关/目标选择；启动前真实下发 `fps_limit`；真实 dt 与显示节奏调度；暂停/失焦不积累追赶 tick；诊断分开记录 tick/render/presentation 统计；行为测试、Debug 构建、KAG3 软件/Metal smoke 和 CUA。
- 未完成边界：P3a 预启动页面 CUA、P1/P2 无障碍补验、G1 登记/深流程、Minori、P5 增强、IAP 与更新器均不属于本切片，不能借 P3d 提前开放。

#### 后续代理交付 Prompt

> 继续 `/Users/colorcard/Aether` 当前分支 `feature/apple-native-host-m0`，按 `AGENTS.md` 每轮只提交一次并 push。先阅读本节、`doc/apple_host_ui_plan.md` 的 P3d 门槛、`doc/apple_host_ui_spec.md` 的 FPS 契约及现有 `EngineController`/`SettingsStore`/Godot `main.gd`。实现一个真实、可验证的 P3d 完整切片：HostSettings schema v5（`fpsLimitEnabled=false`、`targetFPS=80`，兼容 v1–v4）；五语言设置入口和保存/迁移；启动前把启用状态准确下发为 `fps_limit=0` 或目标值；宿主调度在关闭限制时跟随显示刷新，在启用限制时按目标节奏运行，并把真实 elapsed dt 传入引擎，避免剧情随刷新率加速；处理失焦、隐藏、最小化、暂停和退出，不产生 catch-up burst；区分并记录 tick/render/presentation 统计。不得改已有 ABI，不得开放未实现增强或伪造 FPS。完成后运行现有设置/行为测试，新增有意义的调度单元测试，Debug 构建，KAG3 软件与 Metal 真实 smoke，必要时补 CUA；检查 `git diff --check`，创建本轮唯一 commit 并 push，最终报告证据路径、未覆盖范围和下一阶段。

#### Goal 模式睡前核验目标

1. **配置契约**：`python3 tools/apple_host_settings_tests.py` 通过；schema v1/v2/v3/v4 迁移到 v5，默认值、目标值校验、`fps_limit` 选项值（0/60/80/90/120/144）可从测试证据读出。
2. **时间正确性**：调度单元测试证明 60/120 Hz 脉冲下目标 80 不超过目标节奏，关闭限制不丢真实 elapsed；同一测试剧情时长下累计模拟毫秒在不同显示脉冲率相同，不能用固定 16 ms 伪造。
3. **生命周期**：真实 KAG3 软件/Metal 各至少一次启动、输入推进、失焦/恢复或暂停、退出；无 tick 爆发、`lease_failures=0`、`leases_live=0`、Metal failures=0，诊断包含 tick/render/presentation 统计。
4. **呈现口径**：至少一轮高刷新/模拟高刷新脉冲或明确的 DisplayLink/Timer fallback 证据；统计明确“提交/命令完成/屏幕扫描”边界，不把提交吞吐称为屏幕 FPS。
5. **交互验收**：真实 Debug 窗口中 FPS 开关、五个目标值、默认关闭/目标 80、保存状态和下次启动生效可见；失焦/退出后窗口与设置状态恢复。
6. **交付纪律**：`git diff --check`、构建和上述测试通过；本轮只有一个 commit，推送成功；最终回复给出 commit、证据目录、残余未验收项，不把 P3d 之外的暂缓项标成完成。

### 2026-10-12：UI P3d 调度实现

- `HostSettings` schema v5 新增 `fpsLimitEnabled=false`、`targetFPS=80`，兼容 v1–v4；目标值只接受 60/80/90/120/144，`engineOptions` 下发 `fps_limit=0` 或目标值。
- 设置页渲染分类新增五语言 FPS 开关与目标选择；关闭时显示“跟随显示刷新（当前）”，启用时显示五个目标值，文案注明真实经过时间与下次启动生效。
- 宿主调度重构：`FrameScheduler`（纯逻辑，可单测）+ `HostFrameClock`（CVDisplayLink 优先，无活动显示/显式要求时退回 RunLoop Timer）。关闭限制时跟随显示刷新；启用限制时按目标间隔放行 tick，每次回调最多一次 tick，超出记 `dropped_catch_up`。
- 每次 tick 传入真实 elapsed 毫秒（含亚毫秒余量），单次上限 100 ms；失焦、隐藏、最小化、遮挡、系统休眠通过 AppKit/NSWorkspace 通知重置调度时钟并记录状态，退出停止帧时钟并解绑观察者，无追赶爆发。
- tick/render/presentation 分开统计：`engine_tick` 调用数、`engine_get_frame_rendered_flag` 实际出帧数、drawable 提交/图像发布数；诊断含 `frameStatNote` 明确三者都不等于屏幕扫描FPS。
- 测试：`python3 tools/apple_host_settings_tests.py` 通过，含 60/120 Hz 合成脉冲的调度单元测试（目标 80 不被超过、累计模拟毫秒一致、迟到回调丢弃追赶、100 ms 上限）、schema v1–v5 迁移、目标值校验、真实引擎 `fps_limit` 下发与真实 elapsed 调度；Debug 构建通过。
- KAG3 30 秒 smoke 三次运行均通过：软件 original 输出 + Timer 跟随显示（113.1 tick/s）、Metal + 限制 80 + Timer（76.0 tick/s，不超过目标）、Metal + DisplayLink 跟随显示（112.9 tick/s）；均 RGB max diff=0、`lease_failures=0`、`leases_live=0`、Metal failures=0，脚本化生命周期事件重置调度且 `max_delta_ms<=100`。证据：`out/apple_host/evidence/ui-p3d-software/`、`ui-p3d-metal-80/`、`ui-p3d-metal-display/`。
- CUA 在真实 Debug 窗口验证：默认关闭并显示跟随显示刷新、五个目标值可见、选择 120 FPS 保存后显示“设置已保存”且保存禁用、重启后仍为启用 120 FPS。证据：`out/apple_host/evidence/ui-p3d-cua/`。
- 残余未验收：真机/长期运行的显示器睡眠唤醒与真实系统休眠未单独验收；软件诊断路径在 1080p 输出下的 CPU 双三次缩放在 Debug 构建极慢（30 秒仅约4个 tick，属既有 fallback 性能问题，本轮未改），因此软件 smoke 使用 original 输出；P3a 预启动页面 CUA、P1/P2 无障碍补验、G1 登记/深流程、Minori、P5、IAP 与更新器仍不属本切片。

### 2026-10-12：UI P4a 会话时长与主页统计

- `LibraryGame` 新增 `playDurationSeconds`（旧索引缺字段=0，负值归一）；`GameLibrary.addPlayDuration` 原子累加，沿用 Godot 单次会话上限一天、非正贡献忽略。
- `EngineController` 仅在 `startup state: SUCCEEDED` 后用单调时钟开始会话，`consumePlaySeconds()` 一次返回自上次提交以来的运行秒数；返回游戏库、重启与应用退出（`applicationWillTerminate`）各提交一次，失败/启动中不计时，重复返回与重启不重复计数。
- `PlayStats` 迁移 Godot `_dashboard_stats`：总时长、已游玩、近七天活跃、平均时长（整分钟截断）、时长排行（>=60s 前5）、最近游玩（前5）、七天足迹/活跃天数、`DASH_MILESTONES` 里程碑与按小时问候语。
- 主页重建为 Godot 内容结构：三层进度环与中心累计时长、问候/统计副标题、三条图例、打开库入口、四张统计卡（作品总数/已游玩/本周活跃/平均时长）、近七天足迹、继续阅读卡、时长排行与最近游玩；详情页在有累计时长时显示“游玩时长”。平台差异：SF Symbols、系统日期样式、不做极光/模糊背板与进入动画。
- `ThemePalette` 新增 Godot `accent_2`/`accent_3`/`success` 并纳入配色交叉检查；主页统计文案五语言补齐（Godot 原版 dash.* 只有 zh-Hans/en）。
- 测试：`python3 tools/apple_host_settings_tests.py` 通过，含旧索引兼容、时长/问候格式化、固定日历统计算法、上限累加、真实引擎会话累计（启动中/被拒绝启动不计时、重复返回不加时、重启先提交）与五语言 `%s` 说明符防护；Debug 构建通过。
- CUA（隔离 fixture 库，3 条 10740s）验证主页数值与内容：2 小时 · 59 分钟、平均 59m、里程碑 60%、3/3、3/7、七天足迹、排行与最近列表；点“继续”真实启动游戏并在“返回游戏库”后把条目 5400s → 5452s。证据：`out/apple_host/evidence/ui-p4a/`。
- 残余未验收：五语言主页文案只点验 zh-Hans；空库主页状态、VoiceOver/键盘遍历未验收；运行时类型/启动入口/RFVP 编码、诊断 profile/覆盖层/临时工具、虚拟控制模式与播放器交互仍属 P4 后续切片。

### 2026-10-12：UI P4b 诊断 profile 与性能覆盖层

- `HostSettings` schema v6 新增 `diagnosticProfile`（off/baseline/input/render/storage/script/audio/video/plugin/system/full；Debug 默认 baseline、Release 默认 off，与 Godot 相同）与 `debugOverlayMode`（off/summary/detail）；v1–v5 迁移、校验与往返保存。
- profile 只映射 Apple 真实来源：input/plugin/full 启动前下发 `input_trace`/`plugin_trace`/`trace_log`；baseline/render 采宿主帧工作；input/full 记录输入事件；system/full 导出系统快照；storage/script/audio/video 本构建无采样源，不进入选择器且在设置页与日志说明原因（不伪造采样）。
- 性能覆盖层显示后端/API/纹理/逻辑与输出尺寸、`tick`/`render`/`presentation` 分开速率和口径说明、帧工作耗时、调度模式、fallback/错误、进程内存与系统空闲/引擎缓存；detail 追加 p50/p95/max、dropped/coalesced/resets、会话计数与缓存明细；GPU 估算明确标注本构建不可用。快照由 tick 循环每 30 tick 节流刷新，视图不持定时器；保存后立即生效，返回游戏库后消失。
- 顺带修正：SwiftUI 菜单式 Picker 的菜单项忽略 `.disabled`，原先"不可用但可点选"的 Metal 与 profile 档位改为只列出可用项（当前值仍可见），避免出现可选中却没有实现的配置。
- 测试：`python3 tools/apple_host_settings_tests.py` 通过，含 profile 目录/可用性/映射、schema v6 迁移与校验、覆盖层文本组合（内存口径、detail 增量、翻译行），真实引擎的 profile 下发、`renderer_info`/`memory_stats`、帧工作采样与导出上下文；Debug 构建通过。
- CUA（隔离 fixture 库）验证诊断设置页与真实 KAG3 覆盖层：tick 111.3/s、render 11.2/s、presentation 111.3/s、App 168.7 MB/Peak 181.9 MB/System free 9.7 GB/Cache 1.2 MB、p50 3.65/p95 9.50/max 12.60 ms、会话 930 tick/94 render/930 presentation，返回后覆盖层消失且会话计时提交（3600→3672s）。证据：`out/apple_host/evidence/ui-p4b/`。
- 残余未验收：storage/script/audio/video 采样源仍未实现（按 Godot 目录保留但隐藏）；调试控制台与临时追踪工具（含 30 秒自动关闭）未迁移；新诊断文案只点验 zh-Hans；GPU 内存估算需要引擎侧新增来源。

### 2026-10-12：范围调整（视频库暂停维护）

- 用户决定：项目聚焦视觉小说，视频库模块暂停维护。已有视频实现（导入/移除与进度、字幕选择记忆、播放器基本控件、P2/P3 的测试与 CUA 证据）保留，不再推进视频导入/播放器/字幕/视频库 UI 的改动，只做不破坏兼容性的修复。
- 本轮已回退正在进行的视频播放器改进（控件自动显隐、方向键 seek、拖拽 seek、Esc 返回、全屏恢复）与对应测试/工具改动，未提交任何视频相关修改；工作区保持在 `cd0ac25a`。
- P4 剩余切片调整为视觉小说相关项：运行时元数据与启动入口/编码、调试控制台与临时追踪工具（含 30 秒自动关闭）、虚拟控制模式与入口/透明度。P5 增强保持独立。

### 2026-10-12：UI P4d 临时高级工具

- 设置「高级开发工具」接入 Godot `_set_advanced_tool` 的四个真实引擎选项：插件调用追踪 `plugin_trace`、追踪日志 `trace_log`、控制台日志文件 `console_log_file`、导出 TJS 脚本 `export_scripts`；五语言标签与说明沿用 Godot 文案，场景测试入口仍保留未迁移说明。
- 会话级语义：这四个开关不进入 `HostSettings`、不产生草稿脏状态、重启自动关闭；`plugin_trace`/`trace_log` 开启后 30 秒（Godot `ADVANCED_TRACE_TIMEOUT_MS`）由 tick 循环自动下发 "0"，`console_log_file`/`export_scripts` 无时限。
- 应用时机：已有会话时立即下发，被拒绝则回滚 UI 状态；否则在 `initializeEngine` 应用，过期项丢弃并记录 `expired before launch`。诊断导出附带选项状态与追踪剩余秒数。
- 测试：`python3 tools/apple_host_settings_tests.py` 通过，含工具目录/30 秒到期/无时限项/快照/重置单测与真实引擎的预启动应用、运行中关闭、`appliedSettingOptions` 不含临时工具；Debug 构建通过。
- CUA（隔离 fixture 库）验证高级页四个开关与说明、切换不产生未保存状态；真实 KAG3 会话日志：`advanced tool plugin_trace=on (auto-off in 30 s)`、`trace_log=on`、`plugin_trace=1 applied`、`trace_log=1 applied`、引擎 `engine_set_option: plugin_trace/trace_log=true`，30 秒后 `advanced tool ... expired after 30 s` 并下发 `false`。证据：`out/apple_host/evidence/ui-p4d/`。
- 残余未验收：`console_log_file`/`export_scripts` 未在真实会话中逐项启用验收（引擎选项应用由行为测试覆盖）；场景测试入口（重启跳转）未迁移；新文案只点验 zh-Hans。

### 2026-10-12：UI P4e 游戏内虚拟控制

- `HostSettings` schema v7 新增 `virtualControlMode`（mouse/touch，默认 mouse）、`virtualControlMenuEnabled`（默认 true）与 `virtualControlKeyboardOpacity`（0.2–1.0、0.05 步进，Godot snap 语义）；v1–v6 迁移、加载归一、保存校验。
- 游戏画面按 Godot `_sync_visibility()` 呈现：右上角入口按钮与按键面板开合分离、面板默认关闭；关闭入口等于隐藏整条虚拟控制。按键与保持 Ctrl 使用配置透明度，鼠标模式指针手柄保持完全不透明（Godot“指针保持清晰”）。
- 面板内 mouse/touch 切换立即持久化：mouse 显示可拖动指针手柄与左键按钮（拖动差值按显示缩放换算为逻辑画布像素并收敛到画布内），touch 隐藏两者、沿用真实指针；桌面始终保留真实指针输入（不复刻移动端画面屏蔽）。按键集合沿用现有视觉小说推进键，不复制移动端 D-pad/鼠标键/滚动长按。
- 测试：`python3 tools/apple_host_settings_tests.py` 通过，含透明度 snap/clamp、模式取值、Godot 入口/面板可见性矩阵、虚拟指针收敛与 schema v7 迁移/校验；Debug 构建通过。
- CUA（隔离 fixture 库 + 真实 KAG3）：会话起始只有入口按钮；点击后出现面板、指针手柄与模式行；透明度 0.5 下按键变暗而手柄清晰（首次布局重叠已修复重验）；`左键点击` 在虚拟指针坐标发送真实 down/up（host.log `input pointer type=1/3 at (319,239)`）并推进剧情；`回车` 按键推进剧情。证据：`out/apple_host/evidence/ui-p4e/`。
- 补验（解锁后重跑）：CUA 拖动手柄产生 `virtual cursor -> (385,207)/(451,174)/(517,142)`；面板内 `切换模式` 切到 `模式 · 直接触摸` 后手柄与左键按钮消失、切回恢复，且 `virtualControlMode` 立即写入偏好；另新增真实会话行为测试覆盖手柄居中、累计、边界收敛、真实 down/up 与模式切换重置。
- 残余未验收：真实指针与虚拟手柄同时使用的边界行为待观察；手柄拖动依赖显示缩放换算，尚无比对基准。

### 2026-10-12：UI P4f 运行时元数据

- 新增 `GameRuntimeDetector`：按 Godot `GameMetadata.inspect()` 顺序识别 KiriKiri（XP3/startup.tjs/ks）、ONScripter、Siglus、Minori 与校验过的 RFVP `.hcb`（头校验端口自 `_hcb_launch_file()`），并区分“未识别”。
- 导入门限复用同一检测：Siglus 标记与校验过的 `.hcb` 目录现在可以加入游戏库（此前只能识别 KAG/ONS/XP3/Minori），未识别目录仍拒绝；托管/引用与刷新语义不变。
- 详情页新增只读「运行时类型」「启动入口」：状态来自真实 `engine_probe_runtime_provider`（>0 匹配 / 0 不识别 / <0 本构建未链接）；KiriKiri 走内置宿主路径，provider 未匹配时显示内置路径说明而不是“无法启动”。启动入口不做覆盖（`engine_open_game` 忽略 `startup_script`），RFVP 编码在未链接 provider 时显示原因、不提供选择。
- 测试：`python3 tools/apple_host_settings_tests.py` 通过，含标记检测、HCB 校验、导入门限与真实 provider probe（ONScripter 匹配其夹具并拒绝 KAG，未知 id 返回负值）；Debug 构建通过。
- CUA（隔离 fixture 库）：KAG3 详情显示 `KiriKiri` + 内置宿主说明 + 入口 `startup.tjs`；ONScripter 夹具详情显示 `ONScripter` + `已匹配本机构建中的 runtime provider。` + 入口 `0.txt`。证据：`out/apple_host/evidence/ui-p4f/`。
- 残余未验收：Siglus/hcb 目录通过真实文件面板导入未走 CUA（导入门限由单测覆盖）；RFVP 编码与 `.hcb` 实机运行需要包含 RFVP provider 的构建；调试控制台与场景测试入口仍未迁移。

### 2026-10-12：P5a 画面增强（对比度自适应锐化）

- 调查结论：Godot 增强实现位于私有 RenderingDevice provider（`FrameEffectProvider` 直接依赖 RenderingDevice/RID 与 Godot `Texture2D`），Apple Metal 呈现路径无法复用，必须逐算法移植并做参考对照；15 条预设链/16 算法仍属 P5b 起的工作包。
- 实现对比度自适应锐化：五抽头（中心 + 上下左右）局部对比度加权拉普拉斯，增量限制在局部对比幅度内避免光晕；CPU 参考与 Metal shader 同公式，行为测试逐像素对照（最大差 ≤2），平坦区无操作、alpha 保留。
- `HostSettings` schema v8 新增 `frameEnhancement`（off/adaptive_sharpen）与 `frameEnhancementAmount`（0–1、0.05 步进）；未移植的 Godot 算法 id 在加载时归一、保存时拒绝。渲染页新增 Godot 同名「画面增强」选择器与「锐化强度」滑杆，并明确列出 Anime4K/FSR1/RAVU/CuNNy/NNEDI3/FXAA 尚未移植。
- Metal 在输出缩放之后执行同尺寸修复 pass，中间纹理按 frame revision 管理；分配或 pass 失败保留原始画面并记录原因；能力随原生 Metal 呈现器可用性上报（无 Metal 时显示 Godot 不可用说明）。
- smoke 工具新增 `--frame-enhancement`/`--enhancement-amount` 覆盖；增强开启时把引擎/呈现 RGB 对比从“必须一致”改为“必须有界地不同（≤160）”，并在 `result.json` 记录 `frame_enhancement`。
- 测试：`python3 tools/apple_host_settings_tests.py` 15 组全通过（含核函数、Metal/CPU 对照、关闭恢复原帧、schema v8 迁移与校验）；Debug 构建通过。
- 真实 30 秒 Metal direct smoke：关闭时 RGB max diff 0/0/0；开启（0.5）时 121/123/123（呈现被锐化、引擎帧未变），两次均通过启动/输入/截图/退出与 lease 检查。CUA 验证渲染页选择器只有 关闭/对比度自适应锐化、选择后出现 50% 强度滑杆、保存写入 v8 偏好，真实会话日志 `frame enhancement adaptive_sharpen amount=0.50`。证据：`out/apple_host/evidence/ui-p5a-off/`、`ui-p5a-on/`、`ui-p5a-cua/`。
- 残余未验收：Godot 算法集（Anime4K/FSR1/RAVU/CuNNy/NNEDI3/FXAA）与 15 条预设链、自定义链编辑器均未迁移；增强只在 Metal 路径生效（软件诊断路径保持原始画面）；增强与输出缩放/4K 组合的负载报告待补。

### 2026-10-12：P5b FSR1 RCAS + EASU（Godot 算法逐个移植）

- 结论：FSR1 的 RCAS 与 EASU 都有公开 MIT 参考（`ffx-fsr/ffx_fsr1.h`）且可独立验证，作为 P5b 先移植；其余 Godot 算法（Anime4K/RAVU/CuNNy/NNEDI3/FXAA）需要更大的实现与许可评估，暂不开放。
- 实现 `FrameEnhancementKernel.fsr1Rcas` 与 Metal `rcas_fragment`：忠实照搬参考的环最小值/最大值、`hitMin = min(mn4,e)/(4·mx4)`、`hitMax = (1−max(mx4,e))/(4·mn4−4)`、逐通道 lobe 与 `[−0.1875, 0]` 限制、`(lobe·ring+e)/(4·lobe+1)` 解析；全黑/全白邻域的 0 分母在 CPU 与 GPU 两侧显式钳为 0，避免 NaN；`FSR_RCAS_DENOISE` 与中精度倒数未启用。
- `FrameEnhancement` 新增 `fsr1_rcas`（顺序 off → adaptive_sharpen → fsr1_rcas）；渲染页选择器由 `allCases` 驱动自动多出该算法，说明文案改为“当前开放已验证的自适应锐化与 FSR1 RCAS”；许可全文写入 `THIRD_PARTY_LICENSES.md`。
- 修复真实缓存缺陷：增强 scratch 纹理原先只按 `frameRevision` 缓存，切换算法/强度而源帧不变时会复用上一算法结果；缓存键加入算法与强度（`enhancedConfig`），`clear()` 一并重置。测试用“同一帧上先跑自适应再跑 RCAS”回归该缺陷。
- 测试：`python3 tools/apple_host_settings_tests.py` 全通过（RCAS identity/对比/alpha/黑白色有限性、Metal 与 CPU 参考一致 ≤2、缓存键回归、schema v8 往返 `fsr1_rcas` 且仍拒绝 `fsr1_easu`）；Debug 构建通过。
- 真实 30 秒 KAG3 Metal direct smoke（`--frame-enhancement fsr1_rcas --enhancement-amount 0.5`）与 30 秒软件回归 smoke 均通过；RCAS smoke 的引擎/呈现 RGB max diff=44/14/14（有界、非零），日志含 `frame enhancement fsr1_rcas amount=0.50`。证据：`out/apple_host/evidence/ui-p5b-rcas/`、`ui-p5b-software/`。
- CUA 验证渲染页「画面增强」只有 关闭/对比度自适应锐化/FSR1 RCAS 三项、选择后出现 50% 强度滑杆、保存写入 v8 偏好；随后经真实产品路径（游戏库 → 开始游玩）启动 KAG3，Diagnostics 日志出现 `frame enhancement fsr1_rcas amount=0.50`。证据：`out/apple_host/evidence/ui-p5b-cua/`。
- FSR1 EASU：`FrameEnhancementKernel.fsr1Easu` 与 Metal `easu_fragment` 移植 `FsrEasuCon`/`FsrEasuSetF`/`FsrEasuTapF`/`FsrEasuF`；硬件 `gather4` 用四次钳位点采样模拟、近似 `rcp`/`rsqrt` 换精确值，CPU 与 GPU 逐像素一致（≤2）。EASU 自己完成输出放大（`scalesOutput`），由输出 pass 承担；`outputConfig` 缓存键加入采样/增强算法。渲染页选择器多出「FSR1 EASU」，文案改为“当前开放已验证的自适应锐化与 FSR1 EASU/RCAS”。30 秒 KAG3 Metal direct smoke（`--frame-enhancement fsr1_easu`）通过，放大输出 1440x1080 视觉正确。证据：`out/apple_host/evidence/ui-p5b-easu/`。
- 残余未验收：Anime4K/RAVU/CuNNy/NNEDI3/FXAA 的许可与负载评估、15 条预设链、自定义链编辑器均未迁移；EASU 在 1:1（输出分辨率等于输入）时锐化核会在锐边产生可见差异（算法在非放大场景下的行为，默认 1080p 放大路径不受影响）；增强只在 Metal 路径生效（软件诊断路径保持原始画面）；增强与输出缩放/4K 组合的负载报告待补。

### 2026-10-12：P6 首片 首次使用协议门（macOS）

- Godot 首次使用前弹隐私/免责协议（`LEGAL_AGREEMENT_VERSION = "2026-07-27.4"`），同意后进入主界面、拒绝则退出；Apple 宿主此前只能在「设置 > 关于」查看文档，没有首次门。本片补齐 macOS 侧首次门。
- `LegalAgreement.version` 与 Godot 一致；`LegalAcceptanceStore` 把 `{version, acceptedAt}` 写入库根 `legal-acceptance.json`，与可撤销的设置草稿分开；缺失/损坏/版本不符一律视为未同意并重新弹门。
- 首次启动弹不可关闭的 `LegalAgreementView`：标题 + 首用说明 + 打包好的五语言协议正文（`privacy_disclaimer_*.txt`）+ 拒绝 / 同意并继续。同意写版本与时间戳；拒绝在 macOS 退出应用（对齐 Godot 桌面行为）。
- 非交互入口用 debug-only `AETHER_HOST_BYPASS_LEGAL_GATE=1` 绕过（对应 Godot 的 `AETHERKIRI_BYPASS_LEGAL_GATE`）；smoke/selftest/profile/cold-start/texture-lifecycle/runtime-movie 工具已设置该变量。
- 测试：`python3 tools/apple_host_settings_tests.py` 新增 `LegalAcceptanceTests`（版本门、持久化、损坏文件、过期版本、debug 绕过）全通过；Debug 构建通过。
- CUA：全新库弹门并显示五语言协议正文、同意后写 `legal-acceptance.json`、重开不再弹门；30 秒软件回归 smoke（工具带 bypass）通过。证据：`out/apple_host/evidence/ui-p6-legal-cua/`、`ui-p6-legal-smoke/`。
- 残余未验收：渠道额外声明（App Store statement）与「已拒绝」页面属 iOS/M4；内置 Demo、VNDB 在线封面仍待 P6。

### 2026-10-12：P6 续 内置 Demo

- Godot 首次运行会把打包的多语言 Demo 安装进库，删除后记住、不再恢复；Apple 宿主此前只能手动导入。本片补齐（对齐 `scripts/builtin_demo.gd`）。
- `BuiltinDemo`：`id="aetherkiri-kag3-demo"`、`version=4`；把打包的 `data.xp3` 复制到 `<库根>/builtin_games/aetherkiri-demo/data.xp3`，状态写 `<库根>/aetherkiri_builtin_demo.cfg`（`{removed, installedVersion, installedSize}`）。启动时幂等 reconcile（保留既有条目游玩时长/封面/标题）；删除写 `removed=true` 并删安装目录，重启不再恢复。
- 库条目新增只读 `builtinId`/`builtinVersion`（旧索引解码为 nil）；详情页对内置 Demo 显示「内置 Demo」徽标与「删除内置 Demo」，确认框写明删除后不恢复；五语言文案。
- `data.xp3`（17MB）随 App 打包（`project.yml`），与 Godot 共用同一份 Demo 资源。
- 测试：`python3 tools/apple_host_settings_tests.py` 新增 `BuiltinDemoTests`（安装、幂等 reconcile、删除记忆、缺失资源降级）全通过；Debug 构建通过。
- CUA：首启安装 Demo 并在库中显示「Aether Demo」、详情页徽标/删除按钮、确认删除后库为空且重启不恢复。证据：`out/apple_host/evidence/ui-p6-demo-cua/`。
- 残余未验收：Demo 的多版本升级路径（当前只有 version 4）；VNDB 在线封面、渠道额外声明仍待 P6。

### 2026-10-12：P6 续 VNDB 在线封面

- Godot 用 `vndb_cover_resolver.gd` 后台把标题发给 VNDB 取首个结果封面；Apple 宿主此前没有在线封面。本片按 spec 的“单独可选联网动作”实现，隐私优先。
- 详情页新增「搜索在线封面」按钮（显式触发，不做后台自动扫描）；`VNDBCoverSearch` POST 到 `https://api.vndb.org/kana/vn`，请求体只含标题与 `fields`，不含本机路径/存档。结果以候选列表（缩略图 + 标题 + VNDB id）展示。
- 选择候选后下载封面缓存到库根 `Covers/vndb-<id>.jpg` 并 `setCover` 指向；失败保留当前封面并显示原因。`CoverSearchProviding`/`CoverImageLoading` 协议便于测试注入。
- 测试：`python3 tools/apple_host_settings_tests.py` 新增 `CoverSearchTests`（请求形状/只发标题/空标题拒绝、响应解析丢弃无图行、注入式 search/apply 缓存与索引、失败保留）全通过；Debug 构建通过。
- CUA：真实 VNDB 搜索「Aether Demo」→ 选候选 → 缓存 `Covers/vndb-v21873.jpg`（18KB）→ library.json coverPath 指向它 → 详情页出现清除封面。证据：`out/apple_host/evidence/ui-p6-vndb-cua/`。
- 残余未验收：只提供每查询的首个候选（与 Godot 一致）；Godot 的后台自动查询刻意未镜像；渠道额外声明仍待 P6。

### 2026-10-12：P5b 续 增强 kind/预设/自定义链

- Godot 的增强设置是 `frame_enhancement_kind`（off/preset/custom）+ 预设选择 + 自定义算法链编辑器；Apple 宿主此前只有一个扁平算法下拉。本片对齐该模型（schema v9）。
- `HostSettings` v9 用 `frameEnhancementKind`/`frameEnhancementPreset`/`frameEnhancementChain` 替换 v8 的单一 `frameEnhancement`；v8→一步自定义链、v7→off 迁移；`enhancementSteps` 解析最终链。
- 预设先开放可组合的「均衡清晰（FSR1）」= EASU→RCAS（Godot `fsr1`）；需要未移植算法的预设不列出。自定义链编辑器：有序步骤行、每步算法选择、移除、＋ 添加算法（上限 32）；只列已验证算法，EASU 只允许作为第一步。
- 渲染：`MetalFramePresenter.enhancementChain` 把链首缩放步（EASU）作为输出 pass，其余在同尺寸 ping-pong scratch 上按序执行；缓存键含链/强度/采样算法；单算法链与旧行为一致。
- 测试：`python3 tools/apple_host_settings_tests.py` 通过（v8→v9 迁移、预设解析、链往返、非法链拒绝、两步链与 CPU 组合一致）；Debug 构建通过；30 秒 KAG3 Metal direct smoke 通过。
- CUA：kind/预设/自定义 UI、保存 v9、真实启动日志 `frame enhancement fsr1_easu,fsr1_rcas amount=0.50`。证据：`out/apple_host/evidence/ui-p5b-chain-cua/`。
- 附带修复：内置 Demo 条目 `directory` 改为 `id.uuidString`（原先导致含 Demo 的库重载报「索引无法读取」），`BuiltinDemoTests` 增加 save/load 回归。
- 残余未验收：Anime4K/RAVU/CuNNy/NNEDI3 的许可与负载评估及移植（对应预设才会放开）；缩放步只允许链首。

### 2026-10-12：P4 续 可停靠诊断控制台

- Godot 有可停靠调试控制台（概览/事件/日志/输入/插件 + 问题标记与快照动作）；Apple 宿主此前只有运行日志文本与导出。本片补上结构化面板，复用已有数据而非截图。
- 游戏内「游戏」菜单新增「诊断控制台」开关，打开后在右侧停靠 380pt 面板；关闭时若「显示运行日志」开启则恢复原日志面板。
- 五标签：概览（status/renderer/presentation/frame/output/fpsLimit/tick/回退）、性能（与覆盖层同源的技术行：Backend/api/texture/frame/out、tick/render/presentation 速率并注明不等于屏幕扫描 FPS、frame ms+pacing、fallback/errors、引擎内存、frame-work p50/p95/max、pacing dropped/coalesced/resets、会话 ticks/renders/presentations/play）、输入（控制模式/指针/IME/全屏/影片）、插件（加载模式 + 当前游戏运行时/入口/信号 + 真实 `engine_probe_runtime_provider` 结果 + 翻译可用性）、日志（暂停 + 过滤）。
- 面板打开时引擎即使覆盖层关闭也刷新快照（`diagnosticsConsoleActive`）；底部提供「复制摘要」与「导出诊断日志」。
- 测试：五语言 key 覆盖与既有套件全通过；Debug 构建通过。CUA 验证菜单开关、面板停靠与概览/性能/插件标签真实数据（如 `runtime kirikiri entry data.xp3 provider kirikiri = 100`）。证据：`out/apple_host/evidence/ui-p4-console-cua/`。
- 追加：问题标记（Godot `MARKER_TYPES`，上限 8）+ 保存快照（JSON，含完整 metrics）+ 截图（PNG）+ 自检（session/engine/renderer/storage，记录到 session）已接入；`DiagnosticTests` 覆盖 marker cap（8 接受、第 9 拒绝、重载仍在）。CUA 验证四项动作真实产出。证据：`out/apple_host/evidence/ui-p4-console-actions/`。
- 慢帧捕获已在下一条记录补齐。

### 2026-10-12：P4 续 场景测试入口

- Godot 的「高级开发工具」有场景测试（`settings.scene_test`）；Apple 宿主此前保留「尚未迁移」占位。本片补齐。
- 高级区改为真实控件：场景选择器（首页/设置/游戏详情/视频库/视频播放器/游戏界面）+ 说明 + 进入场景；处于场景测试模式时按钮变为退出场景测试。
- `SceneTestStore` 用 Godot 的键 `aether_kiri/scene_test` 持久化；进入即导航并显示顶部「场景测试模式」横幅；重启后 `applySceneTestIfRequested()` 重新进入；退出清除键并返回游戏库。
- 与 Godot 的差异：不镜像独立的默认/加载/启动状态选择器（加载态为瞬态，无法诚实预览）；视频播放器场景打开库里第一个视频。
- 测试：`python3 tools/apple_host_settings_tests.py` 新增 `SceneTestTests`（Godot 键、往返、清除、未知值降级）全通过；Debug 构建通过。
- CUA：进入游戏详情场景并显示横幅、`defaults read org.github.aetherkiri.host.debug "aether_kiri/scene_test" -> detail`、重启仍进入、退出清除键并回到库。证据：`out/apple_host/evidence/ui-p4-scene-test/`。
- 残余未验收：RFVP 编码（待链接 provider）。

### 2026-10-12：P4 续 慢帧捕获

- Godot 控制台的「慢帧捕获」会武装一次性捕获，下一帧 host work 超过 `slow_frame_threshold_ms`（20 ms）时记录一次并解除武装。本片按同一语义实现。
- 引擎新增 `SlowFrameCapture` 状态机（arm / note）与 `armSlowFrameCapture()`（无活动会话时返回 false）；tick 的 `defer` 在算出本帧 host work 后调用检查，超过 20 ms 时把 `slowFrameCaptured` 写入诊断 session 并写日志，然后解除武装。控制台动作区新增「慢帧捕获」按钮。
- 测试：`python3 tools/apple_host_settings_tests.py` 的 `DiagnosticTests` 覆盖状态机（未武装忽略、快帧保持武装、慢帧报告并解除、一次性）全通过；Debug 构建通过。
- CUA：真实会话中武装后写入 `slowFrameCapture = "armed (threshold 20 ms)"`，随后真实捕获 `slowFrameCaptured = "20.17 ms host work at tick 7800"`。证据：`out/apple_host/evidence/ui-p4-slow-frame/`。
- 与 Godot 的差异：本移植只记录 tick 与 host work，不复刻 Godot 的近期事件环；RFVP 编码仍待 P4。

### 2026-10-12：P5b 续 双三次/Lanczos 链步骤与预设

- Godot 的增强算法表里 `bicubic`/`lanczos` 也是链算法，且 `frame_enhancement_mode.bicubic/lanczos` 是对应预设；Apple 宿主已有这两个已验证的采样核，本轮接入链。
- `FrameEnhancement` 新增 `bicubic`/`lanczos`（`scalesOutput` + `samplingAlgorithm` 映射；EASU 仍走自己的 shader，双三次/Lanczos 复用采样 shader）。链的缩放步骤覆盖 `upscaleAlgorithm`，符合 Godot 链语义。
- 预设列表扩到 3 项：均衡清晰（FSR1）=EASU+RCAS、自然柔和（双三次）=bicubic+RCAS、锐利细节（Lanczos）=lanczos+RCAS；自定义链首步可选 EASU/双三次/Lanczos。说明文案同步更新。
- 渲染：`MetalFramePresenter` 用链的缩放步骤做输出 pass，其余步骤按序同尺寸执行；`scalingConfig` 含“有效采样 + 缩放步骤”。
- 测试：`python3 tools/apple_host_settings_tests.py` 全通过（`allCases`/预设/采样映射、lanczos+RCAS 链往返、非法链拒绝、bicubic+RCAS 与单独 bicubic/单独 lanczos 都不同）；Debug 构建通过；30 秒 KAG3 Metal smoke 通过。
- CUA：预设列表三项、保存 `preset=bicubic`、真实启动日志 `frame enhancement bicubic,fsr1_rcas amount=0.50`。证据：`out/apple_host/evidence/ui-p5b-sampling-cua/`。
- 残余未验收：Anime4K/RAVU/CuNNy/NNEDI3/FXAA 及其预设；预设内 RCAS 强度用用户滑杆值（Godot 私有的 `fsr1_rcas_low` 不可复现）。

### 2026-10-12：P6 续 App Store 额外声明门

- Godot 在 Apple 平台（iOS 与 macOS）首次使用前要求**两份**文档：先隐私/免责协议（`LEGAL_AGREEMENT_VERSION = "2026-07-27.4"`），再 App Store 分发额外声明（`IOS_STATEMENT_VERSION = "2026-08-04"`，正文 `legal/ios_app_store_statement_*.txt`）。P6 首片只接了第一份，本轮补齐第二份并把首次门改为按文档顺序推进。
- `LegalAgreement.statementVersion` 对齐 Godot；新增 `LegalDocument`（privacy/statement），每份带自己的版本、标题、首用说明与 `SettingsDocument`。
- `LegalAcceptanceStore` 记录由单文档 `{version, acceptedAt}` 改为 `{privacy, statement}` 两份 `Entry`；旧单文档文件迁移到 privacy 条目；`isSatisfied(_:)` 按文档比对版本，`requiredDocument()` 返回顺序里第一个未满足者（缺失/损坏/版本不符一律视为未同意）。
- `ShellModel.legalGateRequired` 换成 `requiredLegalDocument`；`acceptLegalDocument()` 写入当前文档后推进到下一份，两份都满足才关掉首次门；`LegalAgreementView` 按当前文档取标题、首用说明与五语言正文。「设置 > 关于」在隐私协议旁新增「Apple App Store 额外声明」入口。
- 测试：`python3 tools/apple_host_settings_tests.py` 的 `LegalAcceptanceTests` 重写为两份文档的顺序门（privacy→statement、每份版本门、旧单文档迁移、损坏文件、debug 绕过）全通过；Debug 构建通过。
- CUA：全新库先弹 privacy（1/2，版本 2026-07-27.4），同意后弹 statement（2/2，版本 2026-08-04），再同意才进库；写出 `{"privacy":{...},"statement":{...}}`，重开不再弹门，关于页出现两项。证据：`out/apple_host/evidence/ui-p6-statement/`。
- 差异：「已拒绝」独立页面属 iOS/M4；macOS 保持拒绝即退出（对齐 Godot 桌面行为）。

### 2026-10-12：审阅问题修复与 CUA 回归

- `HostFrameClock` 检查 DisplayLink handler 安装与启动返回值；启动失败记录原因并回退 Timer。注入真实 DisplayLink 启动失败测试验证 Timer 仍产生回调、停止后无回调。
- 在线封面下载绑定搜索会话和游戏 ID，应用期间拒绝重复请求；关闭窗口取消任务并使旧结果失效。下载内容需可解码为图片后才写缓存和索引，损坏内容保持原封面字节不变。
- 行为回归新增损坏图片、重复应用、取消后旧下载完成与新搜索隔离；`python3 tools/apple_host_settings_tests.py` 和 Debug 构建通过，`git diff --check` 通过。
- CUA 在真实修复构建、隔离库中完成 VNDB 搜索→取消→再次搜索→下载应用，截图确认详情页封面正常显示；Demo 启动显示 KAG 介绍页，Return 输入后可确认返回游戏库，封面与详情保持。启动失败与延迟响应边界由自动故障注入覆盖，未声称 CUA 实际发生系统 DisplayLink 故障。
- 本地证据：`out/apple_host/evidence/review-fixes-cua/`（测试、构建、runtime 日志和隔离库）；CUA AX/截图记录在本轮工具记录中。未修改用户实际游戏库。

### 2026-10-12：游戏内诊断页面 CUA 点验

- 基于 `3fcebe85` Debug 构建与隔离 Demo 库实测游戏菜单→诊断控制台。概览显示实际 Metal 管线、640×480 逻辑帧与1440×1080输出；性能页显示 tick/render/presentation、耗时/内存/缓存及统计边界；输入和插件页可切换。
- 保存快照后界面显示文件名，JSON 实际可解析；自检返回 `session=ok, engine=ok, renderer=ok, storage=ok`；问题标记写入 session.json。日志暂停与 self-check 过滤可操作并显示对应单行；从调试页返回确认后恢复游戏库。
- 证据：`out/apple_host/evidence/review-fixes-cua/library/Diagnostics/snapshot-2026-10-12T13-24-56Z.json`、`session.json`；本轮 CUA AX 和截图。尚未点验截图保存、导出面板、慢帧捕获及真机 iOS，不扩大本次验收范围。
- 观察到中文控制台正文仍有大量英文属性名和解释；这是后续本地化修复项。CUA 时性能读数有变化，本次交互操作不作为无扰动性能基准。
- 判断：macOS 已可作为 M4 移植基线；iOS 构建、UIKit 输入/布局、移动端帧钟、音频会话、沙盒和 StoreKit 尚须单独实现与真机验收，不能视为直接可发布 iOS。

### 2026-10-12：虚拟按键 CUA 检查

- 隔离 Demo 游戏中验证顶栏开关→画布入口→按键面板，回车按钮可点击；保持 Ctrl 后输入诊断显示 held=yes，收起面板后 held=no；鼠标/直接触摸模式可切换，测试后恢复鼠标模式并返回游戏库。
- 复现问题：顶栏仅切换入口可用性，需第二次点画布图标才能展开，反馈容易产生歧义；浅色主题下黑色面板上的模式标签对比不足；收起实际面板后诊断仍显示 virtualPanel=visible（读取 showVirtualControls 而非 panelOpen）。本轮仅测试记录，尚未修复。
- 未充分验证：所有 VK 的游戏响应、虚拟指针拖动精度、失焦释放与真实标题长流程；不以一次回车点击声称全部输入正确。截图和 AX 证据见本轮 CUA 记录。

### 2026-10-12：虚拟控制板交互修复

- 顶栏与菜单直接展开/收起，画布入口和诊断共享 ShellModel 会话状态；修复面板收起后 virtualPanel 仍显示 visible。新会话重置，隐藏/禁用/返回释放虚拟按键。
- 模式标签使用白色以修复浅色主题下黑色面板对比度。画布入口偏好与顶栏显式打开动作分离，保持原有设置持久化。
- 设置行为/虚拟控制呈现测试与全套 `apple_host_settings_tests.py`、Debug 构建、diff 检查通过。CUA 实测单击展开、白色标签、Ctrl 后收起、诊断 hidden/held=no 和返回库；本轮不扩展声称全部 VK/虚拟指针精度已验收。

### 2026-10-12：游戏菜单/诊断卡顿修复

- 实跑 Demo + 诊断控制台，主线程 sample 显示 SwiftUI Graph/布局更新为热点；tickCount 每 tick Published 及非 lease 路径未渲染时仍复制纹理都会让整壳高频重建。
- 精确 tickCount 保持内部计数，UI displayedTickCount 与性能快照按单调时钟最多每秒四次发布；引擎 dt/tick 节奏不变。非 lease native 仅在渲染新帧或首帧时复制纹理，未变化帧保留身份；不支持可选 rendered 查询的 provider 保持原来更新语义。游戏 Menu 固定内容宽度。
- Debug 构建、全套设置/真实引擎行为测试、diff 检查通过。CUA 验证诊断打开、诊断开启时菜单展开与关闭；调用观察由约4秒降至约0.6秒，仅工具交互参考，不作为严格延迟基准。
- 同机3秒主线程采样：修复前1479/2244样本落在 SwiftUI 更新链，修复后1903/2401样本等待事件。证据 `out/apple_host/evidence/menu-refresh-fix/`；该短期 Demo 数据不是游戏FPS或真实标题长期性能结论。

### 2026-10-12：iOS 18 迁移 spec 与实践基线

- 建立 `apple_host_ios_spec.md` 和 `apple_host_ios_plan.md`，最低iOS/iPadOS18.0，iPhone/iPad原生target；10项需求矩阵、I0–I6实施阶段与可核验交付。
- 明确44pt触控、安全区、自适应导航、单主指事件/取消/映射、虚拟控制板、IME、CADisplayLink/lifecycle、音频、Files复制与书签、真实StoreKit、诊断低频刷新与真机G4。
- 同步AGENTS、总spec与历史移交链接及18.0约束；本文档不构成iOS实现/构建/真机已通过证明。仅文档变更，检查Markdown本地链接与diff，不重复运行应用测试。

### 2026-10-12：I0 iOS核心构建起步（仅KiriKiri）

- 用户指定ONS/Siglus暂不提供，已撤回本轮provider构建条件扩展并同步AGENTS/spec/实践。建立两SDK隔离的构建脚本及18.0 triplet；iOS核心STATIC，macOS保持SHARED，公共ABI不变。
- 两SDK系统iconv探针编译链接及Mach-O平台/minOS检查通过，脚本SDK/配置/暂缓provider校验与语法、diff检查通过。
- 实际simulator依赖配置修复了GNU libiconv工具安装链接与OpenSSL配置参数截断；完整core构建尚在依赖安装，I0未完成，不声称已生成iOS App。日志/状态在 `out/apple_host/ios/simulator/debug/`；设备清单证据 `out/apple_host/evidence/ios-I0-core/`。
- Xcode26.0.1，只有26.0 simulator runtime；已配对iPad/iPhone目前unavailable。18.0运行兼容和G4仍需真实环境验收。


### 2026-10-13：双 SDK 构建与移动生命周期

- device与simulator Debug核心/探针完整构建通过，Mach-O平台分别IOS/IOSSIMULATOR，minOS18.0、SDK26.0；device未进行真机安装。
- 新增可复用MobileSessionDriver、暂停原因集合和音频激活封装，修复scene/application激活先后导致恢复卡住；恢复首tick清零。前台playback策略、耳机路由等待恢复、媒体服务丢失要求重开已明确。
- 120Hz时钟/重叠暂停测试、15项真实引擎通知注入、macOS完整设置行为回归通过。证据 `out/apple_host/evidence/ios-I3-lifecycle26/`；本轮未做CUA或真机音频测试。
- M4仍未完成：正式iOS产品target/Metal、协议门、Files/库、移动输入/IME与StoreKit继续推进；iOS18运行与真机G4另验收。


### 2026-10-13：正式 iOS 产品 target 起步

- 新增AetherHostIOS/AetherHostIOSTests与CMake File API静态链接闭包导出；device/simulator Debug产品构建通过，最低18.0。
- 实现五语言双协议门/独立拒绝页、主页Demo与文档入口、UIKit游戏控制器、确认返回与停止；复用移动生命周期及画布，当前仅software原始画面。
- Debug/Release隔离模型测试、iOS26四项XCTest、15项生命周期注入及macOS回归通过。普通首启协议页与Debug隔离Demo第一帧截图/日志确认；本轮无CUA点击验收或真机验收。
- 证据 `out/apple_host/evidence/ios-I1-product-shell/`。M4仍在实施，下一步优先Metal呈现及完整移动产品流程。


### 2026-10-13：iOS Metal lease 呈现

- 产品默认Metal/MTKView，同队列FrameLease提交、原始输出/比例适配；修复iOS静态frame sink的dlsym注册缺失，ABI未改。
- iPadOS26真实Demo图像通过视觉核查；6项iOS XCTest覆盖10帧正常呈现零回读/复制、故障注入软件图像与退出lease/generation清理。device Debug与macOS行为回归通过。
- 证据 `out/apple_host/evidence/ios-I1-metal/`；当前60上限、同刻像素/旋转/内存/高刷新/实际GPU故障仍需I4，真机G4未完成，未声称本轮CUA。


### 2026-10-13：移动游戏库与复制导入

- 支持独立Documents/Games托管路径、Application Support索引；KiriKiri-only目录/ZIP导入、权限/协调生命周期、限量复制与取消/原子发布/回滚。
- 新增自适应库/详情、重命名/保留文件移除、自动封面相对持久化和缩略图；设置/主题与手动封面尚未接入。
- 11项iOS XCTest、device Debug、macOS行为与归档/库套件通过；捕获并修复临时目录/var与/private/var路径别名误拒绝。证据 `ios-I2-library-final5.xcresult` 与 `ios-I2-library/`。
- 真实Files/iCloud/低空间/触屏取消与真机G4未验收。本轮为隔离fixture与截图核查，没有CUA点击证据；目标继续。
