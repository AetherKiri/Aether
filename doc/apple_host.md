# AetherKiri Apple 原生宿主 Spec（SwiftUI + Metal）

- 状态：Draft v0.1（2026-10-10）
- 适用仓库路径：`apps/apple_host/`（SwiftUI App）、`bridge/apple_host/`（C++/Metal 宿主核心）
- 相关文档：[接缝清单](apple_host_seam_inventory.md) · [进度](apple_host_progress.md)

---

## 1. 目标与非目标

### 目标
1. 为 Apple 平台（macOS 先行，验证后 iOS/iPadOS）提供**原生宿主**：SwiftUI 壳 + Metal 呈现，直接驱动 `engine_api`（C ABI）。
2. 去掉 Godot 运行时依赖；不经 SDL（Apple 上直接使用 AppKit/UIKit + Metal + AVAudio）。
3. 保持 `engine_api` 与 provider ABI **零改动**——其他平台继续使用现有 Godot 宿主（`apps/godot_app`）。

### 非目标（本阶段不做）
- 不改引擎核心与 runtime provider 实现（`packages/AetherKrkr`、`bridge/*_runtime`）。
- 不迁移其他平台（Android/Web/Windows/Linux 继续走 Godot）。
- 不追求壳的功能完整对齐——MVP 之后按 M3 迭代补齐。
- 不移植 Godot 的 Lumen UI 代码（只参考其 UX 与文案资源）。

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
| D7 | 游戏目录：默认托管目录 + 用户导入（import 引用/拷贝） | macOS 无沙盒开发期用 `~/Library/Application Support/Aether/Games`；后续适配沙盒容器与安全作用域书签。**细节在 M2 定稿** |
| D8 | MVP 范围：库/导入/启动/返回/基础设置/菜单栏/快捷键/5 语言；视频/IAP/诊断/更新器等推后 M3 | 先跑通"能玩"的最小闭环 |
| D9 | 渲染闸门原则：G1（渲染兼容）不过就停，不继续壳迁移 | 兼容性是产品命根子，避免沉没成本 |
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

- **会话**：`engine_create`（writable/cache 路径）→ `engine_open_game(_async)` → `engine_get_startup_state` 轮询 → 固定步长 `engine_tick`（参考 1/60）→ 呈现 → `engine_pause/resume/destroy`。
- **GPU 绘制桥**：22 个回调（主 18 + 批处理 2 + 外部纹理 4），宿主以 Metal 实现；不注册回调时引擎走即时/软件兜底。
- **输入**：`engine_send_input(engine_input_event_t)`；文本输入经 `text_input` 平台请求 + `engine_get_text_input_state/copy_text_input_text`。
- **平台请求**（字符串通道）：`open_browser`、`call_native`、`purchase`、`text_input`、`presentation_sprite`、`minori_save_slots`、`minori_message(_reveal)`、`minori_audio`、`minori_movie`，其余转交壳层。
- **媒体**：`engine_media_*`（FFmpeg 在引擎内）供视频库与 Minori 影片。

---

## 5. 里程碑与验收闸门

| 阶段 | 内容 | 验收（闸门） |
|---|---|---|
| **M0**（~1 周） | 接缝盘点（完成 v0.1）；`aether_apple_host_core` 构建；SwiftUI 骨架 + 软件帧呈现 + 输入 | G0：KAG3 demo + ONS fixture 可渲染可交互 5 分钟；软件路径 CPU 基线记录 |
| **M1**（~2 周） | Metal 绘制回调实现；双路径可切换 | **G1：与软件路径比对一致；≥2 个 verified_games 标题正确；1080p ≤16.6ms。不过即停** |
| **M2**（~4-6 周） | SwiftUI 壳 MVP（D8 范围） | G2：冷启动 → 导入 → 游玩 全程无代码干预 |
| **M3**（迭代） | 视频/IAP/诊断/更新器/翻译/虚拟按键/i18n | 每项独立验收 |
| **M4** | iOS/iPadOS 适配 | G4：iPad 真机 demo + 1 个真实标题 |

---

## 6. 非功能需求

- 帧呈现：1080p 60fps；VSync 对齐；慢帧不产生 tick 风暴（沿用单帧单 tick 策略）。
- 启动：冷启动到库界面可交互 ≤ 2s（M2 目标，实测后修订）。
- 崩溃防护：引擎错误不崩壳；`engine_get_last_error` 全量记录；日志落盘可导出。
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

环境变量：`AETHER_HOST_GAME_PATH`（游戏路径）、`AETHER_HOST_AUTORUN=1`（自动初始化+打开）、`AETHER_HOST_TEST_INPUT=<秒>`（启动后 N 秒自动发送一组指针+回车输入，确定性冒烟）、`AETHER_HOST_CAPTURE_AFTER=<秒[,秒]>`（到点导出引擎帧 PNG，CI 证据用）、`AETHER_HOST_CAPTURE_DIR=<目录>`（默认系统临时目录）、`AETHER_HOST_EXIT_AFTER=<秒>`（自动退出）。

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
