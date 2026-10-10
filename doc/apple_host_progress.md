# Apple 原生宿主进度（Living Document）

- 最后更新：2026-10-10
- 关联：[spec](apple_host.md) · [接缝清单](apple_host_seam_inventory.md)

---

## 里程碑状态

| 阶段 | 状态 | 备注 |
|---|---|---|
| M0 接缝盘点 + 骨架 | 🟡 进行中 | 交付物 A ✅ v0.2；交付物 B ✅；**交付物 C 核心达成**：SwiftUI App + EngineSession + 软件帧上屏 + KAG3 demo 实跑成功（tick 728，画面完整）。剩余：输入透传、CPU 基线、krkr2.log 重定向 |
| M1 Metal 绘制桥 | ⚪ 未开始 | 闸门 G1；已确认 P2 绘制回调路径（无 ANGLE 依赖） |
| M2 SwiftUI MVP | ⚪ 未开始 | 闸门 G2 |
| M3 功能迁移 | ⚪ 未开始 | |
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
  - 交付物 A v0.1：宿主职责矩阵（会话/GPU 桥/输入/平台请求/媒体/音频/回收/呈现），确认 22 个 GPU 回调为宿主侧实现、ABI 宿主无关
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

---

## 下一步队列（M0）

1. [x] 接缝清单 v0.1（交付物 A）+ 三份文档建立
2. [x] `xcodegen` 2.46.0 安装
3. [x] K 节 TASK 1-7 逐项盘点（见清单 v0.2）
4. [x] `bridge/apple_host/` CMake 目标 `aether_apple_host_core`（**交付物 B**）
5. [x] `apps/apple_host/` SwiftUI 工程骨架 + EngineSession + 软件帧上屏（**交付物 C 核心**）
6. [ ] 输入透传（键鼠 → `engine_send_input`，完成 G0 交互项）+ CPU 基线
7. [ ] `krkr2.log` 落盘重定向（引擎选项）与日志目录规范
8. [ ] 更新三份文档（每次工作结束同步）

## 变更记录

| 日期 | 变更 |
|---|---|
| 2026-10-10 | 项目立项；文档骨架；接缝清单 v0.1 |
| 2026-10-10 | 接缝清单 v0.2（K 项清零）；M0-B 宿主核心库构建通过 |
