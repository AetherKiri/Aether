# AetherKiri Apple 原生宿主 Spec（SwiftUI + Metal）

- 状态：架构基线 + 产品对齐补充（2026-10-11）
- 适用仓库路径：`apps/apple_host/`（SwiftUI App）、`bridge/apple_host/`（C++/Metal 宿主核心）
- 相关文档：[接缝清单](apple_host_seam_inventory.md) · [进度](apple_host_progress.md) · [产品 UI spec](apple_host_ui_spec.md) · [UI 实施计划](apple_host_ui_plan.md)

---

## 1. 目标与非目标

### 目标
1. 为 Apple 平台（macOS 先行，验证后 iOS/iPadOS）提供**原生宿主**：SwiftUI 壳 + Metal 呈现，直接驱动 `engine_api`（C ABI）。
2. 去掉 Godot 运行时依赖；不经 SDL（Apple 上直接使用 AppKit/UIKit + Metal + AVAudio）。
3. 保持 `engine_api` 与 provider ABI **零改动**——其他平台继续使用现有 Godot 宿主（`apps/godot_app`）。

当前进展：M0 输入收尾与 P0 Metal 呈现已接入；P2 Metal 绘制桥已接入（显式启用），G1 按用户要求暂缓；M2 目录导入 MVP 与 G2 界面流程已接入并验证。详见 [Metal 实施清单](apple_host_metal_plan.md)。

### 非目标（本阶段不做）
- 不改引擎核心与 runtime provider 的实现形态（`packages/AetherKrkr`、`bridge/*_runtime`）：不做架构改写、不加/改 ABI 接口。正确性与硬化类最小修补仍允许，例如把 release 构建下 `reserve()`-only 的暂存缓冲改为定长缓冲（2026-10-11，见进度文档）。
- 不迁移其他平台（Android/Web/Windows/Linux 继续走 Godot）。
- MVP 不代表产品功能完整。当前进入 M3 产品对齐阶段，按 [UI 与设置 spec](apple_host_ui_spec.md) 和 [实施计划](apple_host_ui_plan.md)恢复原 Godot 产品职责；平台不适用项与更新器等延后项单列。
- 不移植 Godot 的 Lumen 控件代码；保留其产品结构、功能语义、主题与文案，用 SwiftUI/AppKit 实现。

---

## 2. 决策记录（ADR 摘要）

| # | 决策 | 理由 |
|---|---|---|
| D1 | 目录采用 `apps/apple_host/` + `bridge/apple_host/` | 与现有 `apps/godot_app` + `bridge/godot_extension` 结构对称 |
| D2 | 本阶段仅支持 Apple 平台 | 收敛风险；其他平台宿主保持现状 |
| D3 | 冻结 `engine_api`/provider ABI，不加新接口（除非有 ABI 版本化） | 双宿主并存的基础；Godot 宿主不受影响 |
| D4 | 不走 SDL3 | Apple 平台原生 API 更直接；SDL 价值在跨平台 |
| D5 | 主呈现路径 = 实现 `engine_gpu_bridge.h` 绘制回调（Metal）；兜底 = 软件帧回读上传 | 与现产品 "Godot Native" 同构（引擎 draw manager + 宿主 GPU 原语），兼容性最容易对齐；软件路径用于早期验证与故障排查 |
| D6 | Godot 宿主保留（不删除） | 对照渲染、回退、其他平台继续使用 |
| D7 | 游戏目录：默认托管目录 + 用户导入（import 引用/拷贝） | macOS 无沙盒开发期用 `~/Library/Application Support/Aether/Games`；后续适配沙盒容器与安全作用域书签。**M2 首版采用目录复制，库索引位于同级 library.json；引用/书签后续扩展** |
| D8 | MVP 范围：库/导入/启动/返回/基础设置/菜单栏/快捷键/5 语言；视频/IAP/诊断/更新器等推后 M3 | 先跑通"能玩"的最小闭环 |
| D9 | 2026-10-10 用户调整：暂缓 G1，继续 M2；后续完成后回归渲染兼容与性能验收 | 保留未通过状态与证据，优先推进产品流程 |
| D10 | 文档约定：`doc/apple_host.md`（本 spec）+ `doc/apple_host_progress.md` + `doc/apple_host_seam_inventory.md`，随代码同步维护 | 长期维护要求 |

---

## 3. 架构

```
Aether.app (SwiftUI)                               ← apps/apple_host/
├─ Shell (Swift/SwiftUI)
│   Library / Game / Settings / Videos / About …   （功能以 main.gd 为 UX 参考）
├─ HostKit (ObjC++)
│   EngineSession      会话生命周期、选项、tick、启动状态轮询
│   MetalPresenter     GPU 绘制回调实现（纹理/管线/合成）、呈现到 CAMetalLayer
│   GameInputView      NSView/UIView 输入采集 → engine_input_event_t
│   AudioHost          AVAudioEngine 播放 + BGM 淡入淡出（Minori 等）
│   PlatformAdapter    NSOpenPanel / StoreKit / NSWorkspace / IME 桥
└─ aether_apple_host_core（静态链接）
    engine_api + krkr2 glue + providers + krkr2plugin（CMake 构建，vcpkg 静态依赖）
```

呈现数据流（主）：引擎 draw manager → 回调表 → MetalPresenter（Metal 纹理/绘制）→ CAMetalLayer → SwiftUI
呈现数据流（兜底）：`engine_get_frame_desc` → `engine_read_frame_rgba` → 上传纹理 → 同上

Apple 特化资产（已存在，直接复用/移植）：
- `bridge/godot_extension/src/apple_external_texture.mm`：`CVPixelBuffer → id<MTLTexture>` 模式（iOS 已在用）
- `bridge/godot_extension/src/RuntimeTickPacer.h`：帧节奏
- `bridge/godot_extension/src/apple_storekit.swift`、`apple_native_file_picker.swift`
- `apps/godot_app/scripts/main.gd` `UI_TEXT`（5 语言文案）、`legal/*.txt`、内置 demo

---

## 4. 关键接口

详细职责矩阵见 [apple_host_seam_inventory.md](apple_host_seam_inventory.md)。要点：

- **会话**：`engine_create`（writable/cache 路径）→ `engine_open_game(_async)` → `engine_get_startup_state` 轮询 → 按显示刷新或目标 FPS 调度的 `engine_tick(真实elapsed)` → 呈现 → `engine_pause/resume/destroy`。
- **GPU 绘制桥**：23 个回调（主 17 + 批处理 2 + 外部纹理 4），宿主以 Metal 实现；不注册回调时引擎走即时/软件兜底。
- **输入**：`engine_send_input(engine_input_event_t)`；提交文字经 `TEXT_INPUT`；输入状态由 `engine_get_text_input_state/copy_text_input_text` 获取。原生宿主已提供手动文字弹窗、屏幕按键，以及游戏内编辑控件的合成输入同步：`attention_point_valid && ime_active` 时画布视图成为 AppKit 文本输入客户端，合成经 `ime_preedit`/`ime_preedit_cursor`、提交经 `TEXT_INPUT`、候选窗口跟随 `attention_x/y`（`ime_preedit` 目前只被 Siglus provider 消费）。
- **平台请求**（字符串通道）：`open_browser`、`call_native`、`purchase`、`dialog`、`text_input`、`presentation_sprite`、`minori_save_slots`、`minori_message(_reveal)`、`minori_audio`、`minori_movie`，其余转交壳层。原生 `dialog`/`text_input` 混合 FIFO 弹窗、初始文字和各自协议响应、失败重试已实现；`call_native` 与原壳一致做空应答，未处理的 operation 计入会话诊断 `unhandledPlatformRequests`，避免 runtime 静默等待。`minori_select`、`softpal_*` 窗口族与 `softpal_http_get` 已归档为缺口（接缝清单 D 节）。私有 provider 实际请求验收仍待补。
- **本地翻译**：宿主按 `engine_is_text_translation_available()` 显隐设置分区并透传 `text_translation.model_path`/`target_language`/`enabled`（目标语言跟随界面语言）；模型校验限制 `.gguf` 且必须存在可读。未链接私有 provider 时引擎返回不支持，宿主记录实际错误并继续启动。真实模型加载与推理质量待该 provider 接入后验收。
- **媒体**：`engine_media_*`（FFmpeg 在引擎内）供视频库与 Minori 影片。M3 已接入独立视频最小播放、文本字幕和进度恢复；Minori 影片请求已实现同引擎播放、矩形覆盖及一次性完成/跳过响应，真实 VM 验收待补；视频库管理与其余 Minori 请求后续迁移。

---

## 5. 里程碑与验收闸门

| 阶段 | 内容 | 验收（闸门） |
|---|---|---|
| **M0**（~1 周） | 接缝盘点（完成 v0.1）；`aether_apple_host_core` 构建；SwiftUI 骨架 + 软件帧呈现 + 输入 | G0：KAG3 demo + ONS fixture 可渲染可交互 5 分钟；软件路径 CPU 基线记录 |
| **M1**（~2 周） | Metal 绘制回调实现；双路径可切换 | **G1：与软件路径比对一致；≥2 个 verified_games 标题正确；1080p ≤16.6ms。不过即停** |
| **M2**（~4-6 周） | SwiftUI 壳 MVP（D8 范围） | G2：冷启动 → 导入 → 游玩 全程无代码干预 |
| **M3**（迭代） | 视频/IAP/诊断/更新器/翻译/虚拟按键/i18n | 每项独立验收 |

当前执行顺序（2026-10-11）：通用游戏库重命名、只移除记录及外部目录引用已实现（macOS 非沙盒基线），ZIP 导入已实现，通用文字输入请求（手动弹窗 + 游戏内编辑控件合成输入/插入符同步）、Debug 冷启动基准、五语言文案审计、Purchase 降级基线、本地翻译设置与选项透传、`call_native` 应答与未处理请求可观测已实现。真实 StoreKit provider（iOS/M4 范围）与更新器留待后续；按用户要求，Minori 后续适配与真实游戏验收暂缓，保留已有影片实现；G1 继续暂缓。

游戏库封面图（手动选择/清除、目录自动发现、列表与详情显示、索引持久化）与全屏切换（游戏页/Game 菜单入口、五语言、退出恢复）已完成；Apple 宿主现已补齐文件刷新、游戏库/视频库/主页路由、视频条目移除与进度清理、Dashboard 统计和 QQ 交流群入口。视频库与游戏库的条目数量限制由 IAP 商品 `com.aether.list.limit` 解锁，而 macOS 当前无法完成真实购买，因此宿主不启用该限制；VNDB 抓取与 IAP 数量限制待联网/商店能力就绪后单独评估。
| **M4** | iOS/iPadOS 适配 | G4：iPad 真机 demo + 1 个真实标题 |

---

## 6. 非功能需求

- 帧呈现：1080p 60fps；VSync 对齐；慢帧不产生 tick 风暴（沿用单帧单 tick 策略）。
- 启动：冷启动到库界面可交互 ≤ 2s（M2 目标，实测后修订）。
- 异常恢复：启动失败记录 `engine_get_last_error` 详情并回库；宿主/启动日志落盘，可从设置或 ⌘⇧D 导出。M3 首项已完成，进程级崩溃捕获仍待扩展。
- 国际化：5 语言与现产品一致（文案资源可直搬）。
- 可维护性：宿主逻辑全部在 `apps/apple_host` + `bridge/apple_host`，不得反向侵入引擎源码；新代码遵循文档化接口。

---

## 7. 构建与运行（M0 进展）

宿主核心库（已完成 M0-B）：

```bash
export VCPKG_ROOT=/Users/colorcard/Aether/.devtools/vcpkg
# 复用既有构建树（增量、快）；独立开发树可另建 out/apple/macos/debug
cmake -S . -B out/macos/debug -DAETHERKIRI_ENABLE_APPLE_HOST=ON
cmake --build out/macos/debug --target aether_apple_host_core -j 10
# 产物：out/macos/debug/bridge/apple_host/libaether_apple_host_core.dylib（依赖 @rpath/libengine_api.dylib）
```

已导出符号：`aether_apple_host_core_initialize`、`aether_apple_host_core_engine_api_version`、`aether_krkr2_install_legacy_services`、各 runtime `RegisterRuntimeProvider`。库加载时（constructor）自动完成 legacy services 安装 + provider 注册。

SwiftUI 工程（M0-C 已可运行）：

```bash
cd apps/apple_host && xcodegen generate
cd /Users/colorcard/Aether
xcodebuild -project apps/apple_host/AetherHost.xcodeproj -scheme AetherHost \
  -configuration Debug -derivedDataPath out/apple_host/derived build
# 运行（GUI）：open out/apple_host/derived/Build/Products/Debug/AetherHost.app
# 脚本化冒烟：
AETHER_HOST_AUTORUN=1 AETHER_HOST_EXIT_AFTER=25 \
AETHER_HOST_GAME_PATH=/Users/colorcard/Aether/demos/aetherkiri-kag3/data \
  out/apple_host/derived/Build/Products/Debug/AetherHost.app/Contents/MacOS/AetherHost
```

环境变量：`AETHER_HOST_SCHEDULING=deferred`（切回 SwiftUI 延后呈现作对照，默认直接提交），`AETHER_HOST_DRAWABLE_1080P=1`（开发用固定 1080p Metal drawable，配合 PROFILE 输出呈现 CSV），`AETHER_HOST_TEST_KEYS=<秒:VK[,秒:VK]>`（确定性键序列），`AETHER_HOST_PROFILE=1`（宿主工作与 tick-to-GPU-completion；直接模式含 MTKView 提交），`AETHER_HOST_RENDERER=metal`（启用 P2，默认软件），`AETHER_HOST_GAME_PATH`（游戏路径）、`AETHER_HOST_AUTORUN=1`（自动初始化+打开）、`AETHER_HOST_TEST_INPUT=<秒>`（启动后 N 秒自动发送一组指针+回车输入，确定性冒烟）、`AETHER_HOST_CAPTURE_AFTER=<秒[,秒]>`（到点导出引擎帧 PNG，CI 证据用）、`AETHER_HOST_CAPTURE_DIR=<目录>`（默认系统临时目录）、`AETHER_HOST_PRESENTATION=image`（禁用 Metal 上传，使用 Image 对照）、`AETHER_HOST_DEFAULT_FONT`（ONS 字体路径）、`AETHER_HOST_EXIT_AFTER=<秒>`（自动退出）。

---

## 8. 风险

| # | 风险 | 缓解 |
|---|---|---|
| R1 | 绘制桥 Metal 实现的兼容性与性能不及 Godot Native | G1 闸门 + 真实标题验证 + 双路径 diff |
| R2 | 隐藏宿主职责（音频路径、纹理回收、tick 语义、选项） | M0 接缝清单持续完善（见清单 K 节 TASK） |
| R3 | Metal 合成细节（色彩空间/翻转/同步） | 参照 `apple_external_texture.mm`；软件路径逐帧比对 |
| R4 | 沙盒/公证/商店流程重建 | M2 提前探路；现有 Python 上传脚本改造 |
| R5 | 双宿主长期维护成本 | D3 冻结 ABI；Apple 宿主不复制引擎内部逻辑 |

---

## 9. 开放问题

1. ~~KiriKiri/ONS/Siglus 音频路径~~ → 已确认：引擎自带 OpenAL Soft 输出，macOS 宿主零工作（见清单 F 节）。
2. ~~`presentation_sprite` 归属~~ → 已确认：发射方不在公开树（疑为私有包），公开构建不触发，M3+ 按需处理。
3. P2 绘制回调的 Metal 实现细节（blend mode 全枚举、mosaic/masked-triangle 语义）— M1 开始前盘点。
4. 静态链接 vs 单 dylib 的最终形态（M0 决定并记录）。
5. 沙盒策略：开发期非沙盒 vs 上架沙盒，游戏目录与书签迁移路径（M2 定稿）。
6. 帧特效（Anime4K 等）在 Metal 下的优先级与形态（M3+）。
