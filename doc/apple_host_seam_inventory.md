# Apple 宿主接缝清单（M0 交付物 A）

- 状态：v0.2（2026-10-10）— K 节 7 项盘点已完成；基于 `bridge/godot_extension/src/`（14,873 行）、`apps/godot_app/scripts/main.gd`（19,583 行）、`abi/include/`、`bridge/krkr2_runtime/`
- 用途：定义新的 SwiftUI + Metal 宿主必须实现的全部宿主职责；随实现推进持续更新
- 关联：[spec](apple_host.md) · [进度](apple_host_progress.md)

图例：✅ 已确认（有明确参考实现） · 🔶 需进一步盘点 · ⛔ Godot 特有，不迁移

---

## A. 会话生命周期

| 职责 | 接口 | 参考实现（Godot 宿主） | 新宿主方案 |
|---|---|---|---|
| 安装 legacy services | `aether_krkr2_install_legacy_services()`（extern "C"，krkr2 glue 导出；**必须在 create 前调用**） | player.cpp:12670-12673（library init 时） | `host_core.cpp` 内完成（宿主核心库初始化时自动调用）✅ |
| 创建会话 | `engine_create(engine_create_desc_t)`：`writable_path_utf8` / `cache_path_utf8` / `api_version` | `initialize_engine()` | `EngineSession.create()` ✅ |
| 打开游戏 | `engine_open_game` / `engine_open_game_async` + `engine_get_startup_state` 轮询 + `engine_drain_startup_logs` | player `open_game()` | 异步 + 进度 UI ✅ |
| 运行时探测 | `engine_probe_runtime_provider(runtime_id, path)`（>0 = 匹配） | player `probe_runtime()` | 启动前选择 runtime ✅ |
| 主循环 | 固定步长 `engine_tick(1/60)` + `engine_get_frame_rendered_flag` | main.gd:13419/13566/13736 | CADisplayLink/CVDisplayLink ✅ |
| 暂停/恢复 | `engine_pause` / `engine_resume` | main.gd 生命周期处理 | scenePhase ✅ |
| 销毁 | `engine_destroy`（先 `release_frame_texture`） | `destroy_engine()` | ✅ |
| 错误处理 | `engine_get_last_error` / `last_result` | 全量 | Swift throws 包装 ✅ |

### Engine 选项（全量，engine_set_option）

**Shell 传入**（main.gd `_apply_engine_options`）：
`fps_limit`、`plugin_load_mode`（`krkrsdl3`/`aether_all`）、`plugin_trace`、`mock_enabled`、`console_log_file`、`trace_log`、`input_trace`、`runtime_arguments`、`text_translation.model_path`、`text_translation.target_language`、`text_translation.enabled`、`artemis.max_visual_delta_ms`、`export_scripts`

**宿主内部**：
`renderer`（`godot_native`/`gpu_bridge`/`debug_cpu`/`software` — `ENGINE_OPTION_RENDERER`）、`frame_output`（`surface`/`raw_source` — `ENGINE_OPTION_FRAME_OUTPUT`）、`ime_preedit`、`ime_preedit_cursor`

**本地翻译（2026-10-11 已透传）**：`text_translation.model_path`、`text_translation.target_language`（跟随界面语言，取值 `zh_hans`/`zh_hant`/`en`/`ja`/`ko`）、`text_translation.enabled`（有模型路径即 1）。
宿主按 `engine_is_text_translation_available()` 决定是否显示设置分区并下发选项；该宏由私有 provider 提供，未链接时引擎返回 `ENGINE_RESULT_NOT_SUPPORTED`，宿主记录实际错误后继续启动。

## B. GPU 绘制桥（23 个回调）

**关键结构发现（v0.2 修正）**：三条候选呈现路径，各有代价，逐一说明：

| 路径 | 机制 | 代价 | 结论 |
|---|---|---|---|
| **P2 绘制回调（推荐）** | 宿主实现 23 个回调（下列表）；引擎 draw manager 委托 GPU 原语 | Metal 实现 17+2+4 个回调（参考 Godot RD 实现，语义清晰） | ⭐ 主路径：无额外依赖、最贴近 "Godot Native"（产品默认渲染器） |
| **P1 IOSurface（不推荐）** | `engine_set_render_target_iosurface`：引擎经 EGL 直渲 IOSurface，宿主零拷贝呈现 | 需要 `BUILD_GPU_BRIDGE=ON` + **EGL/GLESv2（ANGLE）** 依赖——当前 vcpkg 清单没有 ANGLE（"Godot Native must not depend on ANGLE"） | ❄️ 备选/暂缓；若 P2 受阻再评估 |
| **P0 软件回读（M0 基线）** | `engine_read_frame_rgba` 上传纹理 | CPU 拷贝 | M0 先用 |

**P2 回调清单**（语义参考：`aether_runtime_player.cpp` BridgeXxx 实现）：

主表 17（此前计数错误，实际总数 23）：`create_rgba`(:7476) / `release_texture` / `update_rgba` / `clear_rgba` / `copy_rect`(:7962) / `copy_triangles` / `draw_triangles`(:8128) / `draw_masked_triangles` / `mosaic_rects` / `blend_rect`(:8311) / `blend_rect2`(:8351) / `blend_rect3`(:8399) / `read_rgba` / `begin_read_rgba` / `poll_read_rgba` / `discard_read_rgba` / `flush`
批处理 2：`begin_batch` / `end_batch`（延迟 drain 作用域）
外部纹理 4：`import_apple_pixel_buffer` / `prepare_for_native_write` / `publish_native_write` / `import_android_hardware_buffer`

**Provider 运行时呈现**：ONS/Siglus/Minori 等以各自后端产出纹理，经**外部纹理回调**（`import_apple_pixel_buffer`，即 `apple_external_texture.mm` 的 CVPixelBuffer→MTLTexture 模式）进入宿主。
⛔ 不迁移：`GodotGpuBarrierShadowPlanner.h`、`apple_vulkan_external_texture.mm`（Vulkan 专用）。

## C. 输入（已全量枚举）

事件类型（`engine_input_event_t.type`）：`POINTER_DOWN=1` / `POINTER_MOVE=2` / `POINTER_UP=3` / `POINTER_SCROLL=4` / `KEY_DOWN=5` / `KEY_UP=6` / `TEXT_INPUT=7` / `BACK=8`
特殊修饰位：`ENGINE_INPUT_MODIFIER_POINTER_CANCEL = 1<<30`（手势重分类后取消按压）

宿主入口：
- `send_pointer_event(type, pointer_id, x, y, dx, dy, button, modifiers)`
- `send_key_event(pressed, key_code, modifiers, unicode)` — **按下的可打印字符会追加一个 TEXT_INPUT 事件**（KAG 编辑控件契约）
- `send_text_input(text)` — 逐码点发送 TEXT_INPUT（跳过 0/CR/LF）
- `send_ime_preedit(text, start, length)` — 经选项 `ime_preedit` / `ime_preedit_cursor`
- 文本状态：`engine_get_text_input_state`（available/ime_active/ime_mode/attention_point/selection/text_available）+ `engine_copy_text_input_text`

Apple 宿主现已提供实体/屏幕按键及原生弹窗提交 TEXT_INPUT（最多 2048 个 Unicode 标量）；合并来源所有权并在失焦/隐藏/弹窗/关闭时释放。游戏内文字输入已接入（2026-10-11）：轮询 `engine_get_text_input_state`（available/ime_active/ime_mode/attention/selection/text），在 `attention_point_valid && ime_active` 时把画布视图切换为 AppKit 文本输入客户端，合成内容经 `ime_preedit`/`ime_preedit_cursor` 选项下发、提交经 `TEXT_INPUT`、候选窗口按 `attention_x/y` 等比映射定位；合成期间命令键回退为引擎按键事件，⌘V 作为提交文本。注意：`ime_preedit` 目前由 Siglus provider 消费，KiriKiri 传统层忽略该选项，只接收提交文本；真实输入法合成内容仍需人工听/看确认。

坐标：游戏基准画布坐标（`engine_set_surface_size` 语义见 GDScript `_sync_player_surface_size`）。✅

## D. 平台请求（字符串 operation 通道）

宿主每帧轮询 `engine_poll_platform_request`（≤256/帧），处理后 `engine_submit_platform_response(operation, argument)`。

| operation | 载荷 | 现实现 | 新宿主方案 |
|---|---|---|---|
| `open_browser` | URL | shell_open | NSWorkspace ✅ |
| `call_native` | runtime 定义 | 空应答 `result=` | 空应答 `result=` ✅（与 Godot 壳一致）；runtime 定义负载按需扩展 |
| `purchase` | runtime 定义 | macOS 桌面壳：`result=-1` + "In App Billing is unavailable" 降级；StoreKit（apple_storekit.swift）为 iOS 侧能力 | 已实现同款降级响应 ✅；真实 StoreKit 属 iOS/M4 范围 |
| `dialog` | URL 表单：title/message/text_field/maximum_characters/yes_no/buttons；响应 result/text | Godot 原生壳弹窗，响应文字 URI 编码 | SwiftUI FIFO 请求弹窗 + ABI 响应已实现；真实私有 provider 验收待补 🔶 |
| `text_input` | title\tmessage\tinitial text；响应 result=cancel 或 result=ok\t正文 | C++ 扩展 `show_runtime_text_input` 原生输入框 | 通用原生输入框、初始值、混合 FIFO、取消/确认与错误重试已实现；真实 provider 验收待补 🔶 |
| `presentation_sprite` | runtime 定义 payload | `RuntimePresentationSprite`（Godot Sprite2D） | ⚠️ 发射方不在公开树（疑为 AetherInternal/SoftPal 私有包）；公开构建下不会触发。M3+ 按需处理 |
| `minori_save_slots` | 存档槽数据 | 宿主 UI | SwiftUI 存档槽（M3）🔶 |
| `minori_message` / `_reveal` | 说话人/文本/逐字 | 宿主文字框 | SwiftUI 文字框（M3）🔶 |
| `minori_audio` | 8 字段 `\t`（槽/总线/文件/音量/淡入淡出） | AudioStreamPlayer + BGM fade | AVAudioEngine（M3）待实现 🔶 |
| `minori_movie` | 绝对文件路径\t宽\t高\tx\ty\t可跳过(0/1) | `engine_media_*` + 宿主呈现 | 同游戏引擎借用媒体、画布矩形覆盖、complete/skipped/error 回传已实现；真实 Minori VM 验收待补 🔶 |
| `minori_select` | 选择项数据 | 宿主选择 UI | ⛔ 未实现（随 Minori 适配暂缓）；当前无请求时不影响其它 runtime。见 M 节 TASK 11 |
| `softpal_*`（window_size/aspect_mode/cursor_visible/open_target/window_geometry/cursor_warp/window_title/name_editor/file_dialog/stand_dialog/http_get） | runtime 定义 | Godot 壳逐项应答（`softpal_http_get` 失败应答 `ok=0`） | ⛔ 未实现：SoftPal 为私有 runtime，本机构建未启用；窗口类操作在 macOS 有直接等价物，启用前需先补此族 |
| 其他 | — | 信号→壳层 | 默认分发 ✅ |

**应答策略（2026-10-11）**：除 `open_browser` 这类不需应答的操作外，每个 operation 都必须显式回传响应。
未处理的 operation 会累加 `unhandledPlatformRequests` 并写入宿主日志与会话诊断（`session.json`），
避免 runtime 静默等待；新增实现前先确认对应 runtime 是否在本构建启用。

## E. 媒体（视频库与影片）

`engine_media_open/destroy/play/pause/seek/set_rate/set_volume/get_state/get_subtitle_tracks_json/extract_subtitle/read_frame_rgba` + `engine_media_set_volume`。宿主职责：帧呈现、字幕渲染、进度记忆。M3 独立视频已接入 `MediaSession`/`MediaController`（RGBA 基线 + UTF-8 文本字幕 + 本地进度）；Minori 影片已接入 `RuntimeMovieController`，借用游戏引擎且先销毁媒体再回传；视频库及其它 Minori 请求待接入。

## F. 音频（已确认）

- **krkr2/ONS/Siglus 等：引擎自带输出（OpenAL Soft）**——`Application.cpp:1045` 证实；macOS 无需宿主工作 ✅
- **iOS：宿主仅需激活 `AVAudioSession`**（`engine_legacy_activate_audio_session_for_host`，iOS 专用）✅
- **Minori：宿主播放**（platform request `minori_audio`，见 D 节）— M3 ✅

## G. 纹理回收与同步

- `engine_legacy_drain_texture_recycle`：已并入 legacy services 表（`krkr2_legacy_services.cpp:81`），由引擎侧调用，**宿主无需显式处理**（v0.2 修正）✅
- Metal 路径 GPU 同步由宿主自理（shared event/completion），不迁移 Godot 屏障规划器 ✅

## H. 帧呈现与特效

| 项 | 现状 | 新宿主 |
|---|---|---|
| 帧获取（P2/P1） | GPU 桥回调内持有宿主纹理 | MetalPresenter 直接合成 ✅ |
| 帧有效性 | `engine_get_frame_rendered_flag`（P1 模式用） | tick 后查询 ✅ |
| 兜底帧（P0） | `engine_get_frame_desc` + `engine_read_frame_rgba` | 纹理上传 ✅ |
| 表现状态 | `engine_get_godot_presentation_state` | 语义并入 MetalPresenter ✅ |
| Artemis 片段着色器 | `engine_set_runtime_fragment_shader_executor(fn,user)`（宿主提供 GPU shader 执行器） | M3+（依赖私有包）🔶 |
| 帧特效（Anime4K 等） | `frame_effect_host`（Godot RD compute） | ⛔ M3+ 评估 Metal compute 重写 🔶 |

## I. Godot 特有、明确不迁移

`RuntimePresentationSprite`（见 D 表）、`frame_effect_host.*`、`GodotGpuBarrierShadowPlanner.h`、`presentation/*`、`apple_vulkan_external_texture.*`、全部 GDScript 壳（34,846 行 → SwiftUI 重写）、Godot 导出/探针体系（→ XCTest + 截图比对）。

## J. 直接复用的现成资产

| 资产 | 位置 | 用途 |
|---|---|---|
| CVPixelBuffer → Metal 纹理 | `bridge/godot_extension/src/apple_external_texture.{h,mm}` | Provider 纹理导入 |
| 帧节奏器 | `bridge/godot_extension/src/RuntimeTickPacer.h` | tick 调度 |
| StoreKit | `bridge/godot_extension/src/apple_storekit.swift` | IAP |
| 原生文件选择 | `bridge/godot_extension/src/apple_native_file_picker.swift` | 导入/模型选择 |
| 5 语言文案 | `main.gd` `UI_TEXT` | Localizable 资源导出 |
| 法律文本/字体/demo | `apps/godot_app/{legal,assets,builtin_demos}` | 资源直搬 |
| 输入映射参考 | 旧 fork `apps/sdl_host/src/host_input.cpp` | 事件转换 |
| 验收用例 | `doc/verified_games.md`、`tests/fixtures/` | G1/G2 闸门 |

## K. HostKit API 面（K-6 结论）

`AetherRuntimePlayer` 的 GDScript 方法即"宿主对壳的接口面"（≈70 个），分类后即 Swift `HostKit` API：

- **生命周期**：initialize_engine / destroy_engine / open_game / pause / resume / get_startup_state / drain_startup_logs / is_game_open / is_initialized
- **输入**：send_pointer_event / send_key_event / send_text_input / send_ime_preedit / get_text_input_state
- **帧**：tick / update_frame_texture / frame_rendered_this_tick / read_frame_rgba / release_frame_texture / get_frame_texture_backend / get_frame_source_size / set_frame_native_output_enabled / set_surface_size
- **设置**：set_engine_option / set_render_backend / set_diagnostic_config
- **媒体**：media_open/close/play/pause/seek/set_rate/get_state/get_subtitle_tracks_json/extract_subtitle/update_texture
- **诊断**：mark_diagnostic_event / drain_diagnostic_events / get_memory_stats / get_renderer_info / get_plugin_debug_info / get_last_error / get_last_result
- **IAP**：iap_start/purchase/restore/refresh_entitlement/get_state_json
- **原生选择器**：native_launch_file_picker_open/take_result_json / native_cover_file_picker_open / native_translation_model_file_picker_open
- **开发/自测**：probe_runtime / debug_*_self_test / verify_unlock_secret
- **Godot 特有跳过**：set_frame_enhancement_*（6 个）、android_*（2 个）

## L. 目录映射（K-7 结论）

| 语义 | Godot 宿主（`user://`） | Apple 宿主 |
|---|---|---|
| writable（引擎） | app_userdata 目录 | `~/Library/Application Support/Aether`（沙盒后为容器对应） |
| cache（引擎） | 同上/cache | `~/Library/Caches/Aether` |
| 日志 | user:// `*.log` | `~/Library/Application Support/Aether/Diagnostics/`（M3 宿主日志/会话）；引擎侧车在游戏副本 |
| 游戏库 | Documents/Games（iOS）、路径导入（桌面） | `~/Library/Application Support/Aether/Games` + 导入（D7） |
| 壳设置 | `user://aetherkiri_settings.cfg` 等 | `Application Support/Aether/*.json`（格式自定） |
| 存档 | 游戏目录 `savedata/`（引擎行为） | 不变（引擎行为）✅ |

## M. 待办 TASK（滚动更新）

- ~~1. 输入事件全枚举~~ ✅（C 节）
- ~~2. engine 选项全表~~ ✅（A 节）
- ~~3. 非 Minori 音频路径~~ ✅（F 节，OpenAL Soft）
- ~~4. presentation_sprite 归属~~ ✅（结论：发射方不在公开树；不阻塞）
- ~~5. 低频 API~~ ✅（probe/shaders executor/flag 等已归档）
- ~~6. HostKit API 面~~ ✅（K 节）
- ~~7. 目录映射~~ ✅（L 节）
- 8. P2 绘制回调的 Metal 实现细节（blend mode 全枚举、mosaic 语义、masked triangles 语义）— M1 开始前
- 9. `frame_output` 选项在 P2 下的取值与时机 — M1
- 10. 截图/探针对等物（G0/G1 验收需要）— M0 内
- 11. `softpal_*` 窗口族、`minori_select`、`softpal_http_get` 的宿主实现（D 节已归档为缺口）— 启用对应 runtime 时
- 12. 本地翻译真实模型加载与状态（LOADING/READY/FAILED）验收 — 链接私有 provider 后

### M1 实施补充（2026-10-10）

P0 Metal 上传与呈现、P2 Metal 绘制桥均已接入；P2 通过 `AETHER_HOST_RENDERER=metal` 显式启用，默认软件。回调数量、31 个混合模式、采样与同步契约见 [Metal 实施清单](apple_host_metal_plan.md)。

### M2 产品壳接入（2026-10-10）

`ShellModel` 持有单一 `EngineController` 会话，`GameLibrary` 负责托管目录复制和
原子索引持久化；`ShellView` 提供库/导入/游玩/返回/设置，`ShellStrings` 提供与
现产品相同的五种界面语言。普通启动不再要求手工输入路径；开发页与 AUTORUN
保留。默认字体及许可作为应用资源打包。引擎 ABI 与 provider 未改动。
按用户决定先交付 M2，G1 仍为暂缓验收；G2 的 KAG3/ONS 目录流程已通过界面验证。
