# Apple 宿主 iOS 开发移交说明（M4 / G4）

- 状态：macOS 侧 M0/M2 已完成、M1 证据齐（待用户确认标题登记）、M3 产品对齐按 UI P1–P6 推进，均已通过行为回归 + 真实 CUA；本文件用于把工作移交到 iOS 端开发。
- 编写时间：2026-10-12。基准提交：`e4da4ba8`（`feature/apple-native-host-m0`）。
- 关联文档：[spec](apple_host.md) · [接缝清单](apple_host_seam_inventory.md) · [进度](apple_host_progress.md) · [UI spec](apple_host_ui_spec.md) · [UI 计划](apple_host_ui_plan.md) · [Metal 清单](apple_host_metal_plan.md)。
- 交接对象：接手 iOS/iPadOS 适配的 AI 或开发者。请先读 [spec](apple_host.md) 第 1、3、5 节与 [接缝清单](apple_host_seam_inventory.md) F/J/L/K 节，再读本文件。

---

## 1. 一句话现状

`apps/apple_host/`（SwiftUI + Metal）已经是一个能在 macOS 上跑通"导入 → 启动 → 游玩 → 返回"并完成产品级 UI 对齐的原生宿主，直接驱动冻结的 `engine_api`（C ABI），不依赖 Godot/SDL。iOS 要做的不是重写宿主，而是：**新增 iOS 平台适配层 + 真实 StoreKit + 移动端布局/输入/音频会话**，尽量复用现有 SwiftUI 视图与 HostKit 会话核心。

当前里程碑：M0 ✅、M1 🟢（G1 证据齐、待用户确认标题登记）、M2 ✅（目录导入 MVP）、M3 🟡（产品对齐按 UI spec 的 P1–P6 推进，视频库按用户决定暂停维护）。**M4 iOS/iPadOS：⚪ 未开始，闸门 G4 = iPad 真机 demo + 1 个真实标题。**

---

## 2. 复用边界（先看这张表）

| 层 | 能否直接复用 | 说明 |
|---|---|---|
| `aether_apple_host_core`（C++ 引擎+provider 聚合，`bridge/apple_host/`） | 需交叉编译 | CMake 目标 `aether_apple_host_core`，macOS 产物 `out/macos/debug/bridge/apple_host/libaether_apple_host_core.dylib`。iOS 需按 iOS SDK/arm64 重新构建（见第 5 节）。ABI 不变。 |
| `engine_api` / provider ABI | **零改动** | 硬约束：不得新增/修改 ABI 接口（见 spec D3）。Godot 宿主与 iOS 宿主并存。 |
| HostKit 会话核心（`EngineSession.mm`、`MetalBridge.mm`） | 基本复用 | tick/选项/启动轮询/GPU 绘制回调是平台无关的 ObjC++/C++；只需确认 Metal 与 CAMetalLayer 在 iOS 可用。 |
| SwiftUI 视图（`ShellView`、`ShellSettingsView`、库/详情/设置等） | 大部分复用 | 依赖 AppKit 的部分要抽到平台层（见第 4.7 节）。SwiftUI 本身跨平台。 |
| 平台适配（文件选择、打开浏览器、购买、退出） | 必须分平台 | 现在是 AppKit 实现（`NSOpenPanel`/`NSWorkspace`/`NSApplication`），iOS 换成 `UIDocumentPicker`/`UIApplication.open`/`UIScene`。 |
| StoreKit | 需移植并链接 | 现有实现 `bridge/godot_extension/src/apple_storekit.swift`（669 行）属 Godot 扩展，**未被原生宿主链接**；macOS 宿主现在只返回降级响应（见第 4.2 节）。 |
| 法律文本 / 字体 / 内置 demo / 五语言文案 | 直接复用 | `apps/godot_app/legal/*.txt`、`assets/fonts`、`builtin_demos/aetherkiri-kag3/data.xp3`、`main.gd` 的 `UI_TEXT`。 |

---

## 3. 直接可复用的现成资产

来源见 [接缝清单](apple_host_seam_inventory.md) J 节，均已随 macOS 宿主验证：

- `bridge/godot_extension/src/apple_external_texture.{h,mm}`：`CVPixelBuffer → id<MTLTexture>`（iOS 已在用）。
- `bridge/godot_extension/src/RuntimeTickPacer.h`：帧节奏器（macOS 已移植为 `HostFrameClock`/`FrameScheduler`）。
- `bridge/godot_extension/src/apple_native_file_picker.swift`：iOS 文件选择参考。
- `bridge/godot_extension/src/apple_storekit.swift`：StoreKit 参考实现（产品/权益/恢复/coffee 台账）。
- `apps/apple_host/HostKit/EngineSession.mm`、`MetalBridge.mm`：会话与 Metal 绘制桥。
- `apps/apple_host/AetherHost/FrameScheduler.swift`、`HostFrameClock.swift`、`MetalFramePresenter.swift`：P3d 调度与呈现（真实 elapsed dt、失焦/暂停重置，见下）。

---

## 4. iOS 专属待办（M4 主体）

按依赖排序，每项独立验收；不要在一轮里把所有缺项画成无效果控件。

### 4.1 工程与构建

- 现工程 `apps/apple_host/project.yml`（XcodeGen）只声明 `platform: macOS`、`deploymentTarget.macOS: "13.0"`、`ARCHS: arm64`、`PRODUCT_BUNDLE_IDENTIFIER: org.github.aetherkiri.host.debug`。iOS 需新增 iOS target（或 platform 条件），设置 `deploymentTarget.iOS`（Godot 侧 iOS 预设用 `min_ios_version = 16.0`，见 `apps/godot_app/export_presets.cfg`，可作为基线）、iOS bundle id、`UISupportedInterfaceOrientations`、App 图标、`Info.plist` 平台项。
- `aether_apple_host_core` 与 `engine_api` 需为 iOS（`iphoneos`/`iphonesimulator`，arm64）交叉编译；确认 vcpkg 依赖（FFmpeg 等）有 iOS triplet，或走已启用的 provider 子集。
- 链接方式沿用 macOS：`libaether_apple_host_core` + `libengine_api`（embed + code sign）。iOS 上静态链接更简单，可评估（对应 spec 开放问题 4）。
- 新 Swift 文件加入后需 `(cd apps/apple_host && xcodegen generate)` 再构建。

### 4.2 真实 StoreKit（IAP）

macOS 现在**故意**不启用真实购买：`PlatformPurchase.swift` 对 `purchase` 平台请求返回确定性降级（`result=-1`、"In App Billing is unavailable"），并且宿主不启用库数量限制（否则用户永远无法解锁）。iOS 必须接真实 provider：

- 产品：`com.aether.list.limit`（非消耗型，解锁库条目数量限制）、`com.aether.coffee`（消耗型，30 天试用权益）。
- HostKit 面（[接缝清单](apple_host_seam_inventory.md) K 节）：`iap_start` / `purchase` / `restore` / `refresh_entitlement` / `get_state_json`。
- 参考实现 `apple_storekit.swift`：`AetherStoreKitManager` 含事务监听、权益检查（非消耗型 + coffee 台账）、购买/恢复/刷新、`AetherStoreSnapshot`/`AetherCoffeeLedger`（coffee 台账存 Keychain）。
- 接入后需在 iOS 上**启用** `com.aether.list.limit` 的库数量限制（macOS 保持不启用，这是分发渠道差异，不是共享逻辑）。
- `verify_unlock_secret` / 版本隐藏解锁属内部测试入口，不得作为正式权益绕过（见 UI spec）。
- 交易生命周期、沙盒账号、恢复购买、崩溃中断后的补投递都要真机验收。

### 4.3 移动端布局

- 安全区：iOS 上主壳、游戏画布、设置页需尊重 `safeAreaInsets`；Metal 呈现层与输入坐标映射要一致。
- 横屏锁定：Godot 侧 `force_landscape`（`main.gd` `settings.landscape`，"游戏运行时强制横屏"），宿主在游戏会话期间按需锁定方向。
- 界面比例：Godot 侧 `ios_ui_scale_mode` ∈ `["compact", "comfortable", "standard"]`（`main.gd` `IOS_UI_SCALE_MODES`），默认 `comfortable`；iOS 设置页需要对应选择器。macOS 不暴露这些项（UI spec 第 3.1 表已注明"M4 移动端处理，不塞进 macOS 设置"）。
- 触摸输入：`GameInputView` 现在是 `NSView`；iOS 需 `UIView` 版本，把触摸转成 `engine_input_event_t`（事件枚举见接缝清单 C 节），复用 `InputMapping.swift` 的坐标/按键映射。虚拟控件（`VirtualControls.swift`）已存在，需做触屏尺寸适配。
- 键盘/IME：macOS 已实现游戏内编辑控件合成输入（`GameTextInput.swift`）；iOS 需接系统键盘与候选，复用同一 `TEXT_INPUT` 通道。

### 4.4 音频会话

- krkr2/ONS/Siglus 音频由引擎自带 OpenAL Soft 输出，宿主零工作（接缝清单 F 节）。
- iOS 独有：宿主需激活音频会话——调用 `engine_legacy_activate_audio_session_for_host(void) -> bool`（声明 `abi/src/legacy_engine_api.h:107`，经 legacy services 表分发，实现在 `bridge/krkr2_runtime/src/krkr2_host_hooks.cpp`）。在会话启动前后按需调用并记录结果。
- Minori 音频走宿主播放（`minori_audio` 平台请求），iOS 上同样需要 `AVAudioEngine` 路径与音频会话配合。

### 4.5 目录与沙盒

- 目录映射见接缝清单 L 节：iOS 库目录为 `Documents/Games`；writable/cache 用 App 容器对应目录。
- 现 macOS 宿主**未启用 App Sandbox**，外部目录引用无 security-scoped bookmark。iOS 从第一天就在沙盒里，外部引用必须用 security-scoped bookmark（或改为导入复制），这是与 macOS 的关键差异，需要单独设计。
- 引擎 writable/cache 路径由 `engine_create` 传入，改成容器路径即可。

### 4.6 首次使用协议门

- macOS 已实现 Godot 对齐的**双文档**首次门：隐私/免责协议（`LEGAL_AGREEMENT_VERSION = "2026-07-27.4"`）→ App Store 额外声明（`IOS_STATEMENT_VERSION = "2026-08-04"`）。见 `apps/apple_host/AetherHost/LegalAcceptance.swift` 与 [UI spec 7.26](apple_host_ui_spec.md)。
- iOS 需补：**「已拒绝」独立页面**（macOS 是拒绝即退出）。`LegalAcceptanceStore` 已按文档/版本管理，可直接复用，只需替换拒绝分支的行为。
- 资源 `legal/ios_app_store_statement_*.txt` 与 `privacy_disclaimer_*.txt` 已打包，五语言齐全。

### 4.7 平台请求适配

- 平台请求字符串通道：`open_browser` / `call_native` / `purchase` / `dialog` / `text_input` / `presentation_sprite` / `minori_*`。macOS 已实现 `dialog`/`text_input` 混合 FIFO 弹窗与各自协议响应；未处理 operation 计入 `unhandledPlatformRequests`。
- iOS 需确认每个 operation 都有显式应答（避免 runtime 静默等待），并复用现有 `PlatformDialog.swift` / `PlatformBrowser.swift` / `PlatformTextInput*`，把 AppKit 依赖换成 UIKit。

---

## 5. 构建与运行（现状 + iOS 需要补的）

### 5.1 macOS（现状，可直接验证基线）

```bash
export VCPKG_ROOT=/Users/colorcard/Aether/.devtools/vcpkg
cmake -S . -B out/macos/debug -DAETHERKIRI_ENABLE_APPLE_HOST=ON
cmake --build out/macos/debug --target aether_apple_host_core -j 10

(cd apps/apple_host && xcodegen generate)
xcodebuild -project apps/apple_host/AetherHost.xcodeproj -scheme AetherHost \
  -configuration Debug -derivedDataPath out/apple_host/derived build
```

### 5.2 测试

```bash
python3 tools/apple_host_settings_tests.py   # 设置/调度/法律门/诊断等全套行为回归
```

覆盖的测试在 `apps/apple_host/Tests/`（36 个文件）：`SettingsStoreTests`、`FrameSchedulerTests`、`LegalAcceptanceTests`、`DiagnosticTests`、`GameLibraryTests`、`MediaSessionTests`、`PlatformPurchaseTests` 等。**iOS 新增平台代码请沿用同一模式**：纯逻辑放独立 struct/函数 + 进 `tools/apple_host_settings_tests.py` 的 Swift 编译套件，UI 走 CUA。

### 5.3 iOS（待建）

- 需新增 iOS 交叉编译脚本/CMake 预设（`-DCMAKE_SYSTEM_NAME=iOS`、`-DCMAKE_OSX_ARCHITECTURES=arm64`、`CMAKE_OSX_SYSROOT=iphoneos`）。
- 需新增 XcodeGen iOS target 与 scheme，`xcodebuild -destination 'platform=iOS,name=<device>'` 构建，真机部署。

### 5.4 CUA 验证（沿用 macOS 方式）

通过 `mcp__cua_repl__js`（`cua.getApp("AetherHost")`、`app.click(index)`、`app.getAXState({disableDiffing:true})`）点验真实 UI。无头/非交互入口用 debug-only `AETHER_HOST_BYPASS_LEGAL_GATE=1` 绕过首次门（smoke/selftest/profile/cold-start 等工具已设）。库根可用 `AETHER_HOST_LIBRARY_ROOT` 指向隔离 fixture。证据落 `out/apple_host/evidence/<切片>/`（`out/` 已在 .gitignore，不入库，但要在文档里给出路径）。

---

## 6. 已完成的、iOS 直接受益的能力（别重复造）

以下都在 macOS 侧实现并验证，iOS 复用即可：

- **P3d 调度**（`FrameScheduler.swift`/`HostFrameClock.swift`）：关闭限制时跟随显示刷新，启用时按目标节奏运行；传入真实 elapsed dt（非固定 16ms）；失焦/隐藏/最小化/暂停/退出重置，不产生 catch-up burst；tick/render/presentation 分开统计，明确不等于屏幕扫描 FPS。
- **设置 schema v5**（`SettingsStore.swift`/`HostSettings`）：`fpsLimitEnabled`（默认 false）、`targetFPS`（默认 80）、渲染/增强/翻译等；v1–v4 兼容迁移；五语言。
- **UI P1–P6**：四目的地导航、封面库/详情、四主题、诊断控制台、画面增强（FSR1 EASU/RCAS、双三次/Lanczos 链）、内置 Demo、VNDB 在线封面、双文档法律门。
- **Metal 呈现**（`MetalFramePresenter.swift`/`MetalBridge.mm`）：GPU 绘制回调实现 + 软件回退，31 个混合模式。

---

## 7. 硬约束与协作约定

- **不改已有 ABI**：`engine_api` 与 provider ABI 冻结（spec D3）。宿主逻辑只在 `apps/apple_host/` + `bridge/apple_host/`。
- **不开放未实现增强**：P5b 的 Anime4K/RAVU/CuNNy/NNEDI3/FXAA 及其预设未移植前不列出（需要许可评估 + Metal 移植 + CPU 对照）。
- **视频库暂停维护**：按用户 2026-10-12 决定，视频库模块暂停；iOS 不推进视频库，专注视觉小说。
- **每轮一个提交**（AGENTS.md）：代码/测试/文档改动在检查通过后创建一次提交并 push，只提交本轮相关文件；提交说明概括改动；最终回复给出提交哈希与验证结果。
- **文档同步**：改动要同步 [spec](apple_host.md) / [接缝清单](apple_host_seam_inventory.md) / [进度](apple_host_progress.md) / [UI spec](apple_host_ui_spec.md) / [UI 计划](apple_host_ui_plan.md)，不写与代码不符的进展。
- **不伪造**：未移植/未验收的功能不画成可用控件，不伪造购买成功、时长、FPS。

---

## 8. 关键文件地图

| 用途 | 路径 |
|---|---|
| 宿主 App 入口 / 菜单 | `apps/apple_host/AetherHost/AetherHostApp.swift`、`ShellView.swift` |
| 会话与引擎 | `apps/apple_host/HostKit/EngineSession.mm`、`AetherHost/EngineController.swift` |
| Metal 呈现 / 绘制桥 | `apps/apple_host/AetherHost/MetalFramePresenter.swift`、`HostKit/MetalBridge.mm` |
| 调度 / 帧钟 | `apps/apple_host/AetherHost/FrameScheduler.swift`、`HostFrameClock.swift` |
| 设置 / schema | `apps/apple_host/AetherHost/SettingsStore.swift`、`ShellSettingsView.swift` |
| 法律门 | `apps/apple_host/AetherHost/LegalAcceptance.swift`、`SettingsDocumentView.swift` |
| 平台适配（需分平台） | `apps/apple_host/AetherHost/PlatformBrowser.swift`、`PlatformDialog.swift`、`PlatformPurchase.swift`、`PlatformDialogView.swift` |
| 输入 | `apps/apple_host/AetherHost/GameInputView.swift`、`InputMapping.swift`、`VirtualControls.swift`、`GameTextInput.swift` |
| StoreKit 参考 | `bridge/godot_extension/src/apple_storekit.swift` |
| iOS 音频会话 | `abi/src/legacy_engine_api.h:107`、`bridge/krkr2_runtime/src/krkr2_host_hooks.cpp` |
| 工程定义 | `apps/apple_host/project.yml`（XcodeGen） |
| Godot 功能基线 | `apps/godot_app/scripts/main.gd` |

---

## 9. 已知缺口（含对 iOS 的影响）

| 项 | 状态 | iOS 影响 |
|---|---|---|
| 真实 StoreKit | macOS 仅降级响应 | **iOS 必做**（第 4.2） |
| 移动端布局/横屏/安全区 | macOS 不适用 | **iOS 必做**（第 4.3） |
| 音频会话激活 | 未接 | **iOS 必做**（第 4.4） |
| 沙盒 + 书签 | macOS 非沙盒 | **iOS 必做**（第 4.5） |
| 「已拒绝」页 | macOS 拒绝即退出 | **iOS 必做**（第 4.6） |
| P5b 其余算法 | Anime4K/RAVU/CuNNy/NNEDI3/FXAA 未移植 | iOS 同限，不开放 |
| P7 更新器 | 未做（用户要求最后） | iOS 不适用自更新，走 App Store |
| 视频库 | 暂停维护 | iOS 不推进 |
| RFVP 编码 | 待链接 provider | 与平台无关，链接后通用 |

---

## 10. 建议的起步顺序

1. 交叉编译 `aether_apple_host_core`/`engine_api` 到 iOS，跑通一个能 tick 的最小 App（对应 M0/M2 的 iOS 版）。
2. 复用 ShellModel/SwiftUI 视图，抽平台适配层，先做到"能导入 + 能玩"（复用 Metal 呈现与调度）。
3. 补音频会话激活 + 安全区/横屏/触摸输入。
4. 接真实 StoreKit + 启用数量限制 + 恢复购买 + coffee 权益。
5. 补「已拒绝」页与沙盒书签。
6. G4：iPad 真机跑通 demo + 1 个真实标题，登记到 `doc/verified_games.md` / `verified_games.zh-CN.md`（**只在用户确认游戏可用后**，只写官方原标题与实测平台/范围）。

每一步沿用 macOS 的验收口径：行为回归 + Debug 构建 + 真机 CUA/冒烟 + 证据目录。
