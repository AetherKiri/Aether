# Apple Metal 桥：M1 实施清单

更新：2026-10-10。以 `abi/include/engine_gpu_bridge.h` 和
`bridge/godot_extension/src/aether_runtime_player.cpp` 为实现契约。

## 已交付：P0 上传与呈现

`MetalFramePresenter.swift`：软件 RGBA 帧 → 不可变 `rgba8Unorm` 纹理 →
Metal shader → `MTKView`。按 drawable 像素大小等比缩放，黑边与输入使用同一
aspect-fit 规则；无 sRGB 转换；预乘 RGB 在黑底上呈现时不再乘 alpha。
保留 Image 对照路径，Metal 不可用或编码失败时回退。

离屏验证复用窗口的 shader、pipeline 和 encode：四角异色测试检测上下翻转、
RGBA/BGRA 交换；半透明像素检测重复乘 alpha；横/竖 resize 检测黑边。
截图同时保存 engine PNG 与 Metal PNG，报告原尺寸 RGB 最大差值。

P0 是软件路径的 Metal 呈现基础，仍有软件回读、CGImage 和纹理上传。
P2 已另行接入，**不代表 G1 达成**；1080p 整帧性能尚未验收。

## 已接入：P2 原生 Metal 绘制

`HostKit/MetalBridge.mm` 注册主表、batch 与 external 共 23 个回调。
九组 Metal compute kernels 从现有 Godot GLSL 参考代码生成，保留整数混合
与三角形采样规则；生成头文件签入仓库，构建不依赖 Godot 或 Python。
`tools/generate_apple_metal_shaders.py --check` 检查参考源码与生成物同步。

`AETHER_HOST_RENDERER=metal` 在打开游戏前安装回调并设置现有 ABI 的
`renderer=godot_native`。首帧用 `raw_source` 获取游戏尺寸，再同步 surface
并切回 `frame_output=surface`，避免默认 1280×720 拉伸与输入偏移。
帧 token 解析为不可变 GPU blit 快照供 MTKView 呈现；正常 KAG tick 不做 CPU
回读。仅诊断截图或 Image 对照回读；ONS 不发布原生纹理时沿用软件帧路径。

批处理在外层结束时提交；回读、CPU 更新和快照先同步。源/目标重叠使用快照，
IOSurface owner 保留到未提交命令完成。begin-read 目前同步生成快照，poll 可立即
完成；尚未实现异步回读调度。桥是进程级资源表，不能在单引擎关闭时擅自清空
引擎仍缓存的 token。特殊矩形模式 6 及未知模式显式返回 false，交由引擎兜底；
31 个 ABI 模式的所有游戏调用组合尚未逐项验收。

独立桥测试覆盖精确 alpha 算术、引擎打包 RGBA clear、预乘转换、多源 mask、越界、
重叠拷贝、释放后回读、嵌套批处理内操作顺序、mosaic、普通/遮罩三角形及
IOSurface 通道/释放时机。KAG3 标题静态画面与独立 P0 软件截图 RGB 差值为 0。
对话画面存在动画点击提示的相位差，不能把跨时间截图当作逐像素全场景验收。

## 回调数量校正

ABI 实际为 **23 个函数指针**：主表 17 + batch 2 + external 4。
此前文档“22 个 / 主表 18”是计数错误；不涉及 ABI 修改。

| 组 | 回调 | 实现及验收要求 |
|---|---|---|
| 纹理（4） | create_rgba / release_texture / update_rgba / clear_rgba | stride、局部矩形、尺寸/边界验证；存活 token；未初始化区域清零；延迟释放到 GPU 完成 |
| 拷贝（2） | copy_rect / copy_triangles | 同纹理重叠必须先取快照；copy_rect 不支持缩放；三角形覆盖与采样对照参考实现 |
| 三角形（2） | draw_triangles / draw_masked_triangles | TVP 和 Cubism flags 分开；预乘/最近邻/straight-linear 标志；mask 插值、反转、alpha 合成 |
| 特效（1） | mosaic_rects | 读取原纹理快照，矩形内按相对 block 网格取中心 texel，边缘 clamp；矩形顺序与参考 shader 一致 |
| 混合（3） | blend_rect / blend_rect2 / blend_rect3 | 31 个模式；单源可缩放，多源尺寸需一致；整数规则见下节 |
| 回读（4） | read_rgba / begin_read_rgba / poll_read_rgba / discard_read_rgba | 输出 stride/容量验证；请求 token 持有快照；poll 区分 pending/failed；完成前禁止 CPU 读纹理 |
| 提交（1） | flush | 确保之前操作可见，报告编码/执行失败；不能把未执行的操作标记成功 |
| batch（2） | begin_batch / end_batch | 保序、嵌套 token 和成对关闭；同一队列同步所有依赖 |
| external（4） | import_apple_pixel_buffer / prepare_for_native_write / import_android_hardware_buffer / publish_native_write | CVMetalTextureCache + 原生写入同步；保留 CVPixelBuffer/CVMetalTexture 到释放；Apple 上 Android 导入明确返回 0 |

## clear 参数端序（自检项目发现并修复）

`clear_rgba` 的 ABI 参数名为 argb，但引擎 `TVPGodotClearRgbaBitmap` 已将脚本
AARRGGBB 转为 AABBGGRR，`ClearGpu` 和 Godot 参考宿主均直接传递该值。
Metal 桥必须直接写低字节 R/G/B/A；再交换 R/B 会把动态青色十字和边框变黄。
回归测试同时检查非对称 RGB 和引擎打包青色，真实 TJS 动态更新截图也参与对照。

## 混合与采样契约

- `TVPGodotGpuBlendMode` 有 1–31 共 31 个模式，不可只实现普通 source-over。
- alpha / alpha_d / alpha_a / additive alpha 的目标 alpha 行为不同；整数除 255、
  位移除 256、截断/饱和必须逐个迁移，不可用统一浮点 alpha-blending 替代。
- `blend_rect2/3` 是多源转换与 universal 等路径；mask multiply/threshold 与
  glyph color-map 必须有单独对照样例。
- `BOX_BLUR_ALPHA`：opacity 是 x 半径，color 低字节是 y 半径，reflect101 边界。
- `draw_triangles`：低位 TVP/Cubism 的解释取决于标记位；mask-write 是独立语义。
  premultiplied、nearest、straight-linear 及 minification 的路径需要分别覆盖。
- `draw_masked_triangles`：mask 单独采样 alpha，反转后参与 source alpha；参考实现
  会对缩小 footprint 多点采样，不能仅取最近邻或只检测是否覆盖。

## 注册与帧输出

1. 先实现/测试纹理、混合、三角形、回读与同步全部回调。
2. 通过 `TVPGodotGpuBridgeRegister`、batch/external 注册表安装完整实现，
   再在 open 前设置引擎 `renderer=godot_native`（此字符串为现有 ABI 契约）。
3. `engine_get_godot_native_frame_texture` 返回宿主分配的 uint64 token，
   由 Metal 桥解析为 `MTLTexture`，避免回读后再上传。
4. 初始 `raw_source` 引导 Game Native 尺寸，随后同步 surface 并切回
   `frame_output=surface`；输出与输入坐标同时更新。
5. destroy 引擎并等待 GPU 队列完成；桥资源遵循 token 生命周期，不修改 ABI/provider。

## 性能测量入口

`metal-bridge-tests --benchmark` 测量 1920×1080 清屏、8 层完整 alpha 混合及
不可变 GPU 快照，包含分配、编码、提交、GPU 完成等待；不含 engine tick 和
MTKView。每种批处理配置先预热 10 帧，再采样 60 帧，报告 p50/p95/max。
Apple M1 Max / macOS 15.7.1 一次 Debug 组件测量：关闭批处理 5.012/10.118/12.700ms，开启批处理
3.579/6.132/12.903ms。运行间会受系统负载影响，不是完整帧 G1 结果。
原始证据：`out/apple_host/evidence/p2-bridge-benchmark.log`。

`AETHER_HOST_PROFILE=1`（冒烟工具 `--profile`）在 shutdown 汇总宿主 step 的
单调时钟耗时，包含 tick、请求处理和纹理获取/GPU 等待。跳过前 60 tick，最多
采样 10000 次；MTKView 异步提交和实际显示不在此范围，日志明确标记排除项。
诊断截图在 step 之外，不计入这一测量。完整帧仍需关联 tick 与 drawable GPU
完成，并在真实 1080p 游戏中验证。

## TJS 自检场景对照

用户提供的 aetherkiri-test 已通过软件/Metal、640×480/派生 1920×1080 四运行。
原始脚本先做带音频定时器的启动冒烟；确定性绘制副本禁用该重复定时器。
首帧、鼠标十字、层级/图案/图层组切换的八状态，在两分辨率共 16 组 RGB
截图对比全部为 0。来源哈希和所有结果见
`out/apple_host/evidence/selftest-parity-final/result.json`。
自检发现的 clear 重复交换 R/B 已修复；不能把合成 1080p 或组件耗时当成真实
游戏和完整帧 G1 验收。1080p 宿主测量最大 26.549ms，尾部慢帧仍需定位。

## G1 验收仍待完成

2026-10-11 状态（本机 Debug、Apple M1 Max、macOS 15.7.1）：

| 闸门项 | 状态 | 证据 |
|---|---|---|
| P2 与 P0 一致 | 🟢 内核级 + 整帧级均通过 | 桥测试覆盖混合（精确 alpha 算术、多源、box blur/mosaic）、遮罩三角形、普通三角形、越界/重叠、回读快照、批处理与 IOSurface 外部纹理；整帧对照见下两行的同刻 RGB 差值为 0 |
| 真实标题 ① | 🟢 Smoke verified（KiriKiri 800×600） | 《夏雪》`out/apple_host/evidence/g1-natsuyuki-metal/`：`startup state: SUCCEEDED`、native GPU frame、桥 `failures=0`、三处同刻 engine/Metal RGB 差值 0、输入推进、干净退出 |
| 真实标题 ② | 🟢 Smoke verified（ONScripter 800×600） | 《40日40夜之雨》`out/apple_host/evidence/g1-rain40-metal/`：runtime provider `open_game => OK`、标题画面与 START/LOAD/EXIT 菜单渲染、三处同刻 RGB 差值 0、输入推进、干净退出。该 runtime 发布 CPU 帧，验证的是呈现路径而非 P2 原生桥 |
| 1080p 完整帧 ≤16.6ms | 🟢 合成 1080p 内容达标；真实标题 p99 达标、转场有离群 | 见下节「1080p 完整帧采样方法」 |

尚待用户确认的收尾项：两款标题都不在 `doc/verified_games.md` 现有列表中，按项目约定该表更新需用户确认后写入（含中英文两份），本机不擅自登记。

### 交接与遗留（2026-10-11）

带绘制负载的回读基准：新增 `--batched-readback-benchmark`，1080p clear+8 次 alpha blend 保持未提交，计时从回读调用开始（不含先前 CPU 编码）。10 次预热、60 次采样，同步等待 p50/p95/max=6.773/9.047/11.180ms，异步提交=0.089/0.110/0.116ms，异步总完成=6.146/8.902/11.008ms。70 轮异步输出与同步参考逐字节一致，pending 轮询累计 1060232，最终 commands=175、failures=0、reads/textures=0。该结果支持减少调用线程等待，不等同于完整游戏帧率、Godot 对照或跨帧调度收益；忙轮询仅用于组件测量，下一步需检查引擎实际回读消费者是否跨帧使用该接口。

批次回读等待移除：begin 将快照 blit 追加到当前线程的 pending 命令缓冲并直接提交，不再通过 FlushPending 等待 GPU；batch scope 保留，后续绘制进入新缓冲。同队列保证先前写入→快照→后续写入顺序。跨线程遇到 pending 批次时拒绝请求。新增批次内 clear→begin→再次 clear→end 测试，确认快照与最终纹理分别保持对应像素。桥套件与 Debug 宿主构建通过，failures=0、reads/textures=0。无 pending 负载的 1080p 基准提交 p50=0.108ms、总完成 p50=2.558ms，仅记录基线，不作为批次等待优化的量化收益。上一段“begin 仍同步 flush”已由此实现替代。

1080p 回读组件基准（`metal-bridge-tests --readback-benchmark`，Debug，10 次预热 + 60 次采样）：同步 p50/p95/max=1.234/1.452/1.792ms，异步提交=0.116/0.149/0.237ms，异步总完成=2.495/2.826/3.476ms。异步路径额外生成不可变快照，因此总工作量更大；这里证明提交阶段等待缩短，不证明整体帧率或吞吐优于 Godot。测试每轮核对全部 RGBA 像素、5 秒轮询超时保护、discard 清理，pending 轮询累计 128210（含预热），最终 failures=0、reads/textures=0。基准通过 yield 忙轮询测完成延迟，产品调用方应跨帧 poll；仍需确定性控制 GPU 完成状态的测试。后续优化重点是先前批次 flush 与快照分配成本。

回读后续验证：pending 阶段也立即拒绝空指针、短缓冲和短 stride；测试增加重复 poll、重复 discard、提前 discard 与已丢弃请求拒绝。Metal 桥套件通过（failures=0，reads/textures=0），宿主 Debug 构建通过，KAG3 Metal 30 秒输入/截图/正常关闭冒烟通过，证据 `out/apple_host/evidence/async-readback-kag3/`。该集成回归不是五分钟 G0 或回读性能基准；未完成状态的确定性覆盖与延迟测量仍需补充。

异步回读增量：`begin_read_rgba` 提交快照 blit 后直接返回，`poll_read_rgba` 在 GPU 未完成时返回成功且 ready=false；完成后只读取该快照，不再同步 flush 无关批次。请求持有快照及命令直到 discard，错误只计数一次。MetalBridgeTests 已覆盖快照隔离、轮询与丢弃，commands=31、failures=0、reads=0。begin 仍同步 flush 先前批次；尚未测量回读延迟与完整宿主回归，不能据此宣称整体帧率提升。

- 本期交接点：G1 三项证据齐备（上表），唯一未完成的动作是把两款已验证标题登记进
  `doc/verified_games.md` / `verified_games.zh-CN.md`。按
  `.agents/skills/fix-aetherkiri-game-compatibility` 的规定，该表只在**用户确认游戏可用后**更新，
  并且只用官方原标题、只写实际测过的平台与范围、不写本机路径。本期用户已要求把后续工作交给
  另一个代理继续，登记决策随之移交。
- 登记前需要一并考虑的两点出处事实：本机《夏雪》副本启动时带第三方站点推广水印
  （"御宅同萌 / bbs.cl-acg.com"），并附带汉化补丁声明（禁止商业使用、24 小时内删除、
  禁止广泛转载、**严禁移植到 PC 以外平台**）。该声明针对汉化补丁本身，登记时会与
  「在 Apple 原生宿主上验证」这一表述产生张力；建议登记前改用手头有清晰授权来源的副本，
  或只在本机内部记录而不写入公开发布列表。《40日40夜之雨》为 ONScripter 标题，未发现同类声明。
- 更深一层的流程验证（存档/读档、结局、图鉴）尚未在本期复查：往期会话曾在《夏雪》上人工完成
  一次保存→读档并恢复对白（见进度文档 2026-10-10 条目），本期未重复。
- UI 自动化注意事项（供后续代理复用）：cua 的坐标点击是**真实系统点击**，宿主窗口不在最前时
  点击会落到其它窗口，宿主不会记录到任何指针事件（表现为「点了没反应」）。可行做法：
  先用 AX 的 `Raise` 次级动作把窗口提到最前，或用 `AETHER_HOST_ACTIVATE=1` 启动；
  需要确定性输入时优先后端注入的 `AETHER_HOST_TEST_INPUT` / `AETHER_HOST_TEST_KEYS`，
  而不是依赖屏幕坐标。
- 尚未做的 Metal 完整性项：`begin_read/poll_read` 异步回读（当前一次性同步取回，ABI 的 pending
  语义未用）、deferred 调度尾部（最大 68ms，仅影响对照模式）。

2026-10-10 用户调整：G1 暂缓，先推进 M2 游戏库、导入、设置；后续完成后回归此验收。本节记录的是回归后的实测结果。

### 1080p 完整帧采样方法

- 环境：`AETHER_HOST_RENDERER=metal`、`AETHER_HOST_DRAWABLE_1080P=1`（真实 1920×1080 MTKView 目标）、
  `AETHER_HOST_SCHEDULING=direct`（产品默认的直接提交）、`AETHER_HOST_PROFILE=1`、
  `AETHER_HOST_ACTIVATE=1`（保证窗口可见，否则呈现门控会跳过 drawable 申请）。
- 关闭截图与脚本输入；测量区间为「tick 开始 → drawable 提交 → GPU 命令完成」，
  不含显示器扫描输出；跳过前 60 tick；合并而未提交的 tick 不产生样本。
- 素材：合成 1920×1080 原生内容（`selftest` 的 1080p 副本）两轮各 60 秒；
  真实标题《夏雪》在 1080p 输出下 55 秒。

| 运行 | 样本 | p50 | p95 | p99 | max | >16.6ms |
|---|---|---|---|---|---|---|
| 合成 1080p #1 | 3519 | 1.42ms | 2.95ms | 4.88ms | 16.27ms | 0 |
| 合成 1080p #2 | 3510 | 1.36ms | 3.67ms | 10.80ms | 15.76ms | 0 |
| 夏雪 1080p 输出 | 1216 | 2.17ms | 5.91ms | 8.00ms | 102.21ms | 5 |

证据 `out/apple_host/evidence/g1-1080p-clean-1/`、`g1-1080p-clean-2/`、`g1-natsuyuki-1080p/`。
合成 1080p 两轮均无超预算样本；真实标题的 p99 在预算内，5 个离群样本出现在
开场影片与场景切换附近（主线程 `tick_to_draw` 阶段，取帧与 GPU 耗时仍 ≤0.1ms），
属于转场尖峰而非稳态帧率问题。含并行负载的运行会出现更多离群（同一素材 60 秒曾有
13/3495），因此正式基准需在安静环境串行执行，这一点已写进工具与 README。

### 完整呈现关联测量进展

现已提供真实 1080p MTKView 目标及 tick-to-GPU-completion CSV，包含宿主调度与
GPU 命令完成，排除屏幕扫描输出及未提交的合并 tick。独立无截图自检 30 秒：
1739 样本，p50/p95/max=4.310/6.696/30.181ms，1 个超过 16.6ms，GPU failures=0。
截图回读会导致主线程长停顿，正式基准需独立无截图运行。该结果提供慢帧证据，
不自动通过 G1；Timer/SwiftUI 调度、合并帧比例和真实标题覆盖仍需收敛。

### 直接提交调度

主 RunLoop Timer 直接执行 tick 和 MTKView 提交，移除 Task 排队及 SwiftUI
逐帧上传/绘制依赖；窗口尺寸更新仍可重绘。串行 1080p 自检中 p95 从
7.948ms 降至 3.423ms，但 drawable 获取仍存在约 1 秒异常值，G1 继续待验收。
`tools/apple_host_profile.py` 提供无截图的 sequential deferred/direct 对照。

### drawable 获取停顿：根因与修复（2026-10-11）

复现：同一工具 30 秒 1080p 串行基准，每轮恰好 1–2 个样本超过 900ms，且 933–981ms
**全部落在 `drawable_acquire_ms`**（deferred tick 172/1740，direct tick 590/1741）；
其余约 1700 个样本的取帧耗时只有 0.03–0.05ms。

根因：`CAMetalLayer.nextDrawable` 总是阻塞等待可用 drawable，默认只在 1 秒超时后返回空；
`allowsNextDrawableTimeout = NO` 不是非阻塞开关，反而会**永久阻塞**（SDK 头注释确认）。
当宿主窗口被完全遮挡或无法出帧时，窗口仍被请求 drawable，于是主线程被卡满一秒。
这也是此前 profile 数据里「约 1 秒尾部等待」的来源，与 GPU 编码、桥内核无关。

修复（不改 ABI）：

- `MetalFramePresenter` 新增 `PresentationGate`：无窗口、窗口隐藏、最小化、被遮挡或
  drawable 尺寸为 0 时**不申请 drawable**，本 tick 的呈现丢弃并在下一次 tick 重试；
  状态变化写一条宿主日志（`presentation paused/resumed`），跳过的 draw 不计入 profile 样本。
- `EngineController.shutdown()` 先 `metalPresenter.suspend()`，会话销毁与窗口关闭期间不再出帧。
- 无头基准改为显式激活窗口：`AETHER_HOST_ACTIVATE=1` 时应用启动即
  `NSApp.activate` 并前置窗口；`tools/apple_host_profile.py` 与
  `apple_host_smoke.py --profile` 已默认带上，无样本时工具直接报「窗口被遮挡」而不是空 CSV。

证据（同工具、同素材、30 秒 1080p）：

| 运行 | 修复前 max | 修复后 max | 修复后 >16.6ms | 修复后取帧耗时 |
|---|---|---|---|---|
| deferred | 968.18ms | 68.46ms | 15 | ≤0.05ms |
| direct | 959.61ms | 18.92ms | 1 | ≤0.05ms |

修复后没有任何 >100ms 样本，`drawable_acquire_ms` 全程 ≤0.05ms；deferred 剩余尾部
（最大 68ms）来自 SwiftUI 延后调度本身，不在取帧阶段。直接提交（产品默认）最大
18.92ms、仅 1 个样本超过 16.6ms。窗口可见时 P2/P0 截图像素对照仍为 0 差异
（`selftest-gate-*`，16/16）。截图像素对照见「TJS 自检场景对照」。

模式覆盖补充：单源 `blend_rect` 内核当前实现 1/2/3/5/8/10/11/15/16/17/18/19/20/23/24/25/26/27/28/31，
其中 7 走独立的 AlphaBlendA 管线；多源模式由 `blend_rect2`（4/9/21/22，src2 为 mask/SD 源）与
`blend_rect3`（12/13/14）承担，单源路径显式拒绝它们以免静默产生错误结果（引擎只会把
这些模式发给对应的多源回调，见 `GodotRenderManager.cpp` 的 `ConstAlphaBlend_SD*`/`UnivTransBlend*` 分支）。
模式 6（`ALPHA_A`）在引擎与 Godot 参考宿主中都没有发射方，单源路径返回 false 属防御性空实现；
后续若出现真实发射方，需要按「目标 alpha 独立语义」新增内核并补对照样例。
