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

krkrz 上游实现对照已完成，详见 [渲染生命周期审查](apple_host_krkrz_rendering_review.md)。固定 wamsoft/krkrz 源码版本核对 Show/Canvas/DoneContext/Texture Invalidate/TJS Shutdown：可借鉴的是 DrawDevice 组织目标、直接采样呈现和 context 释放前的明确失效顺序。旧 bitmap 路径仍上传，不能概括为全部 GPU 直绘；Metal CPU replaceRegion 与异步呈现仍需 FrameLease/池协议。上游调用 Shutdown 清 global，而本地注释此调用，是引用图调查点，不能忽略多窗口 Finalize 重入直接恢复。compact + 关闭后 recycle 对照单/双窗口隐式残留仍2/4、显式均0，实验未保留；本轮仅记录源码依据与迁移边界，未宣称关闭修复或性能收益。

### 直通帧租约（2026-10-11）

Apple 宿主新增内部 `AetherMetalFrameLease`。它绑定 session generation、frame serial、
Metal command queue 和引擎纹理所有权；呈现命令只能由同一会话队列提交。会话关闭时
主动使仍被 SwiftUI 持有的 lease 失效，避免旧视图把旧纹理带入下一次游戏。

普通引擎纹理在没有 lease 持有者时直接呈现，不再为每次取帧创建 snapshot；若引擎
写入仍被 lease 持有的纹理，桥执行写时分离，保证 GPU 延迟读取看到稳定帧。外部
IOSurface 仍使用快照，因为其生产者不受本地写时分离协议控制。截图、跨队列回读和
旧 ABI provider 仍保留快照边界。

实现位于 `HostKit/MetalBridge.*`、`EngineSession.*` 与 `MetalFramePresenter.swift`。
组件测试覆盖同纹理共享、写时分离、错误队列/退役会话拒绝和 lease 完成计数；
KAG3 30 秒直通回归通过，RGB 三次差值为 0，输入事件通过，关闭后
`leases_live=0`、`lease_submitted=1750`、`lease_completed=1750`、`lease_failures=0`。
提交完成回调注册后，`MetalFramePresenter` 立即归还 presenter 侧 lease；回调仍持有
GPU 所需引用直到 command completed。这样生产者不会因为 SwiftUI/控制器保留上一帧
而被迫写时分离。更新后的 KAG3 30 秒直通证据 `out/apple_host/evidence/direct-render-kag3-final2/`
中 `frame_detach_copies=0`（上一轮同场景为 444），`leases_acquired=1741`、
`lease_submitted=1672`、`lease_completed=1672`、`leases_live=0`、
`lease_failures=0`，三次 RGB max diff=0，输入事件和关闭均通过。这里把所有权归还
提前是本轮的实质性能改进；动态帧仍保留异常/外部生产者的写时分离兜底，不代表所有
上传或所有 ABI 查询都已删除，也不宣称 G1 已完成。

同轮将 `nativeFrameLease` 从 SwiftUI `@Published` 状态移为渲染控制器内部句柄，
并只在纹理身份变化时发布 `nativeFrameTexture`。KAG3 直通 profile（30 秒，Debug，
640x480）得到 host-work p50/p95/max=`0.301/1.217/12.992 ms`，
tick-to-GPU-completion p50/p95/max=`1.016/2.050/13.361 ms`，
`over_16_6=0`；最终 lease 提交/完成=`1747/1747`，写时分离仍为 0。

### 推送式 native frame publication（2026-10-11）

之前直通每帧仍通过 `engine_get_godot_native_frame_texture` 查询 token。合并查询尝试
证明 DrawDevice 的 post-draw 发布可能晚于 `engine_tick` 返回，直接在 tick 内读取会
丢失帧，因此没有保留那个不可靠的实现。随后接入 krkrz 已有的 `TVPSetPostDrawHook`：
runtime 在每个新标题打开前安装 `engine_native_frame_sink_t`，post-draw 发布完成后
把 token、尺寸和 serial 推送到 MetalBridge 的 RenderSession 缓存；宿主直通只读取
缓存并调用内部 `AcquirePublishedFrame`，不进入逐帧 engine handle/registry 查询 ABI。

这保留了旧 `engine_get_godot_native_frame_texture` 供软件、截图和兼容路径使用，同时
把生命周期边界放在同一个 post-draw publication 与 FrameLease 协议内。KAG3 30 秒
Debug 直通 profile 证据 `out/apple_host/evidence/direct-render-kag3-push-sink/`：
`native_get_calls=0`、`frame_detach_copies=0`、`leases_acquired=1750`、
`lease_submitted=1750`、`lease_completed=1750`、`lease_failures=0`、
`leases_live=0`，RGB max diff 三次为 0，输入和关闭通过；host-work
p50/p95/max=`0.291/1.235/14.065 ms`，tick-to-GPU-completion
p50/p95/max=`0.955/1.987/14.406 ms`，`over_16_6=0`。

双窗口对象图对照已补：保留原单窗口夹具，新增 apple_host_texture_lifecycle_multi（两个Window、各自primary、一个child、共享清理回调），工具 --multi-window 选择，结果标记fixture。当前Debug宿主串行12秒×2验证：普通关闭textures/retired=4，显式清除根引用后经局部变量失效图层/窗口则均0；两轮failures/inflight=0、startup成功、退出码0、无TVPShowScriptException，最终版路径复测相同。证据 out/apple_host/evidence/texture-lifecycle-multi-final/。Window原生Invalidate会先从注册表移除、取消事件/绘制更新、删除DrawBuffer，再失效ObjectVector注册对象；将该动作直接放进引擎关闭时仍有重入/递归finalize风险（运行时代码已有警告）。该浅层共享回调对照不能覆盖游戏自定义finalizer、跨窗口close回调或KAG完整图；下一步应分离关闭阶段并保留对象快照所有权，专门覆盖回调重入后再修改通用关闭流程。本轮未改引擎关闭算法或宣称泄漏修复。Python语法与diff检查通过。

引用对象图最小对照：新增原创 apple_host_texture_lifecycle（一个Window、父/子Layer，无KAG或游戏资产）与串行12秒×2的工具 apple_host_texture_lifecycle.py。普通关闭残留textures=retired=2，逻辑RGBA2457600字节；键输入先把脚本根引用置null、再通过局部变量失效child/primary/window，关闭后textures=retired=0。两轮均failures/inflight=0、startup成功、正常销毁、退出码0，无脚本异常；result.json记录计数。局部变量确保失效回调所属Window后不再通过该已失效上下文访问根变量。证据 out/apple_host/evidence/texture-lifecycle-regression/。这证明该最小图的显式失效能让纹理正常释放，而隐式关闭留下资源；结合分配栈，将关注点收窄到Layer/Window/TJS图关闭，尚未确定KAG的最终引用持有者，也未修改引擎通用关闭流程（多窗口递归析构风险仍需专门覆盖）。工具只要求显式清理无残留，普通模式计数作为对照，未来修复后允许其归零；此测试不是G0/G1或性能测量。Python语法和diff检查通过。

退役纹理来源追踪：AETHER_HOST_TRACE_TEXTURES=1 在创建普通/外部纹理时捕获最多20层分配地址，按 image+offset 保存；EndSession 仅对该会话仍注册的纹理输出 generation/token/尺寸/分配栈，默认关闭且不用于性能对照。Debug构建、桥组件（开关两种模式）和KAG3异步30秒输入/三次RGB比较/干净退出通过。12条退役分配已用当前 libaether_apple_host_core.dylib 的 atos 符号化，证据 out/apple_host/evidence/retired-texture-origins/kag3/{run.log,allocation-stacks.txt}。分配栈主要落在 Layer SetSize/SetImageSize→NativeBaseBitmap SetSize→GodotRenderManager CreateTexture2D，以及 Layer operateRect→OperateRect；它们是引擎图层纹理，不是呈现 Snapshot 的分配。分配栈只能证明来源，不能直接证明最终引用持有者。脚本关闭实现也明确提示引用计数对象可能未全部释放，强制 global Clear 存在递归析构风险；下一步需追踪图层/bitmap销毁与未释放引用，未实施强制清表或修改脚本析构。

内部渲染会话第一步已实现：MetalBridge BeginSession/EndSession（宿主内部接口，不修改公共 engine ABI）分配递增 generation，普通/外部纹理记录创建会话；EngineSession 开启原生绘制时建立边界，销毁引擎后 drain 并退役会话。同步/异步呈现拒绝已退役或不同代际 token，延迟 release 仍能移除旧资源，未强行清表。诊断 render_generation / retired_textures 区分当前与残留资源。组件覆盖重复 begin、错误 end、新旧代际隔离、新纹理可呈现、退役不可呈现和延迟释放，全部通过，最终 textures/reads/inflight/retired=0、failures=0。当前 core 重新构建、Debug宿主构建及KAG3异步30秒输入/截图回归通过；1739快照全完成、RGB三次差值0、render_generation=0，但12个retired纹理合计9711616逻辑RGBA字节仍残留。证据 out/apple_host/evidence/render-generation-current-core/kag3/run.log。该改动建立归属与退役验证，不是完整RenderSession资源所有者/FrameLease，不移除渲染ABI或复制，不宣称泄漏修复；下一步追踪残留引用，并让呈现提交显式持有会话帧。

用户澄清直通目标：减少部分 ABI 的意义首先是让渲染层统一管理生命周期，不是仅压低接口调用耗时。当前桥是进程全局 State，纹理 token 表、批次、快照与宿主呈现状态分别管理；公共接口只传 token/尺寸/serial，不能表达帧被谁持有、何时允许重写或销毁。下一阶段以内部 RenderSession 为资源所有者，公共 ABI 保留开关游戏/输入/平台请求/诊断；Apple 内部呈现接口持有带 session generation 与 frame serial 的 FrameLease，显式表达 produced→submitted→GPU completed→reusable。关闭按停止生产/呈现→完成提交与回调→归还 lease→释放会话资源处理，按代际拒绝旧会话帧；共享 device/管线可缓存，纹理与请求须按会话归属。不能直接清空全局 token 表掩盖残留引用，也不能把 borrowed 裸纹理当作不可变快照。先建立所有权与状态验证，再接纹理池/去复制/合并提交；deferred/遮挡保留与截图策略须随 lease 协议明确。即使 ABI 调用耗时很低，这个架构目标仍成立。尚未实现该重构，不宣称生命周期问题已修复。

阶段计时基线：EngineSession 仅 PROFILE=1 测量取帧接口（包含 ABI 路由与运行时查询）及快照 CPU 阶段，profile 输出结构化平均/最大值；快照开关改为会话初始化时读取，避免逐帧查询环境。Debug构建与KAG3真实1080p drawable配对各30秒通过，无截图/readback、failures=0。sync 1786次调用 get平均0.000668ms、快照平均0.654726ms；async 1781次 get平均0.000640ms、快照CPU平均0.113408ms（不含GPU完成）。tick到GPU完成 p50/p95/max：sync 1.256/1.819/5.052ms，async 0.808/1.376/7.551ms，均零16.6ms超预算，但各有2个有效tick未进入呈现样本。证据 out/apple_host/evidence/native-stage-profile/result.json。阶段计数包含启动/预热，与排除前60 tick的呈现分位数口径不同；此素材的接口CPU成本不是主要量级，未证明直通重构收益或Godot对照。Python语法与diff检查通过。

引擎直通渲染方向（用户提出）：当前引擎纹理已经走 Metal GPU 路径；每 tick 的取帧经过 ABI Route（registry/handle 两层递归锁与 provider 分发），随后 Snapshot 仍分配纹理并全帧 blit。尚无 ABI 单独耗时证据，不能把全部延迟归因于 ABI。优先实验目标是取消呈现快照分配/复制：引擎输出纹理→同队列呈现→完成后复用，控制/插件公共 ABI 保留；内部热路径可使用会话绑定的原生接口。先分别测 tick、ABI 取帧、snapshot 编码/提交、drawable 与 GPU完成，再以同素材同尺寸配对证明收益。直接借用纹理必须规定生产者与消费者提交顺序、强引用/lease、帧serial、重用与队列身份；deferred 呈现与遮挡恢复不能引用已被下一帧改写的内容，截图仍需不可变快照。暂不直接返回裸纹理替换现有接口。参考 wamsoft/krkrz README 描述的引擎内 Canvas/Texture/Shader/Offscreen 与 LIB 构建：https://github.com/wamsoft/krkrz 。该参考支持架构方向，未证明本项目或其引擎的性能对比。

资源增长同步对照：CUA 普通宿主同步模式同进程两次启动/返回《夏雪》，关闭 textures=19→36、failures=0、async_submitted=0，退出码0；因此增长也存在于同步路径。试加关闭时 RecycleProcess 后仍19→33，未证明该队列是根因，已撤回该运行时改动。诊断新增 texture_rgba_bytes（仅注册纹理宽×高×4的逻辑像素大小，不是驱动实际显存、不含快照）与 external_textures，以便定位残留资源。深度引用生命周期仍待排查，未完成泄漏修复。

CUA 异步窗口验收：以 renderer=metal、ASYNC_SNAPSHOT=1 启动普通宿主，同进程两次启动《夏雪》并确认返回游戏库；第一轮使用原生缩放窗口、最小化与 Raise 恢复。截图显示恢复后游戏启动动画继续，日志记录 window hidden/occluded 与 resumed after 4 skipped draws。两次关闭累计 async_submitted/completed=647/647、1093/1093，inflight=0、failures=0、native_readbacks=0；进程退出码0。日志保存 out/apple_host/evidence/async-cua-window/run.log。注意关闭后桥 textures=17→32，资源数增长尚未定位，不能据此默认启用异步模式；下一步需用同步模式同进程重启对照，判断是否是已有引擎资源生命周期问题。仅验证启动与窗口/会话行为，未登记 verified_games，也未覆盖深度游玩或连续尺寸拖动压力。

工具最终版本另跑30秒，主动继承 AETHER_HOST_TEST_PURCHASE=1 验证测试变量隔离；通过且 result.json 记录 submitted=completed=1772、inflight=0、errors=[]。证据 out/apple_host/evidence/async-drain-result-json/kag3/result.json。Python语法与diff检查通过。

异步关闭长回归：最新 Debug 构建 KAG3 Metal 300 秒通过输入推进、三次截图与正常销毁；RGB max diff 三次均为0，async_submitted=async_completed=17892，async_inflight=0，failures=0，native_readbacks=3（仅截图）。证据 out/apple_host/evidence/async-drain-g0/kag3/run.log。smoke 新增 --snapshots sync/async（默认显式sync），异步模式要求非零提交、完成数一致、在途为零且无 drain 错误；清理继承的 AETHER_HOST_TEST_*，固定 direct 调度，输出 result.json 供自动审计。该运行证明此素材五分钟异步生命周期稳定，不是全游戏兼容性或Godot性能对照；遮挡/尺寸/重复关闭压力仍待补，保持 opt-in。

关闭会话现在先停止新呈现，再 drain 共享 Metal 队列与异步快照完成回调，随后销毁引擎。诊断新增 async_submitted / async_completed / async_inflight；桥接测试确认 drain 后 inflight=0、像素一致、failures=0。Debug 构建及异步呈现 KAG3 30 秒冒烟通过（out/apple_host/evidence/async-drain-kag3），此等待仅用于关闭会话。CUA 另验证实际宿主启动《夏雪》显示启动画面、退出确认并恢复游戏库；该 UI 检查使用普通启动，不能据此宣称异步模式或完整游戏流程通过。未更新 verified_games。

反序宿主复测：profile 新增 --reverse-order，先async后sync，KAG3各30秒无截图1080p。async 1737样本p50/p95/max=0.938/1.232/5.255ms；sync 1735样本=1.444/1.763/5.611ms，均零超预算、无合并遗漏、正常销毁、桥failures=0。反序仍有约35% p50、30% p95下降，证据 `out/apple_host/evidence/snapshot-async-sync-profile/`。与首轮合看，收益方向一致但比例随环境变化；尚未Godot对照。生命周期代码检查：presenter.suspend仅阻止新呈现，不显式drain已提交命令，因此正常退出不能证明没有in-flight任务，后续需加完成计数与会话边界drain验证，再考虑默认启用。Python语法/diff检查通过。

共享队列冷启动修正：CommandQueue getter 仅延迟创建 device/queue，不编译绘制桥 shader；Initialize 复用现有队列，避免软件宿主提前编译管线及后续队列替换。组件新增初始化前后队列身份一致断言，桥套件与Debug构建通过。原创controls夹具全新进程各3轮：软件p50/p95/max=0.337/0.386/0.391秒，Metal=0.313/0.324/0.325秒，全部正常关闭且低于2秒目标。证据 `out/apple_host/evidence/lazy-queue-cold-software/` 与 `lazy-queue-cold-metal/`。这验证当前冷启动目标，不是相对上一版本的严格配对提升；非阻塞呈现仍opt-in，窗口压力和重复性能对照待补。

非阻塞快照宿主对照第一轮：profile 工具新增 --compare-snapshots，固定 direct，显式 sync=0/async=1，串行各30秒、真实1080p drawable、无截图/输入。KAG3 sync 1736样本 p50/p95/max=1.642/1.912/6.146ms；async 1736样本=0.930/1.264/6.165ms，二者超16.6ms=0、未呈现有效tick=0、native_readbacks=0、桥failures=0、正常销毁。p50下降约43%、p95约34%，指标是tick到GPU完成而非扫描输出。证据 `out/apple_host/evidence/snapshot-sync-async-profile/`（CSV、日志、result.json）。这是单轮单素材的宿主对照，未比较Godot，尚需重复运行、窗口遮挡/尺寸/退出压力和冷启动验证，保持opt-in。工具语法与diff检查通过；原deferred/direct基准现在显式禁用实验开关，避免继承环境污染。

非阻塞呈现实验：`AETHER_HOST_ASYNC_SNAPSHOT=1` 选择专用 CopyPresentationTexture，提交不可变快照后直接返回；只允许同桥队列的 GPU 消费者，CPU 必须等后续同队列命令完成。同步 CopyTexture 与默认行为保留。完成回调在桥锁内累计 GPU 成功/失败。新增同队列后续 fence 完成后逐像素检查，桥套件通过；Debug 构建及开关开启的 KAG3 Metal 30秒输入/截图/正常退出回归通过，证据 `out/apple_host/evidence/async-presentation-kag3/`。尚需无截图配对性能、遮挡/尺寸切换/关闭压力与冷启动回归，未设为默认；同步 snapshot 计时计数不覆盖实验接口，不能用其零值推导性能。

共享队列基础：桥提供 AetherMetalBridgeCommandQueue，Swift 呈现器支持注入队列并校验设备 registryID；宿主初始化桥后将同一队列传入呈现器，独立呈现测试仍可默认自行创建队列。桥函数声明增加 C linkage 以供 Swift 直接调用。快照仍同步完成，本轮不宣称性能收益；下一步可在同队列顺序保证下增加专用非阻塞呈现快照接口，保留 CPU 截图的同步接口。Debug 构建和 KAG3 Metal 30 秒输入/截图/关闭回归通过，证据 `out/apple_host/evidence/shared-queue-kag3/`。桥提前初始化会增加软件宿主启动的 shader 初始化工作，需在后续冷启动对照中核验并考虑延迟队列接入。

呈现合并命中率核验：诊断新增 snapshot_combined（成功快照前存在 pending 的次数）。KAG3 无截图/无输入 Metal 30 秒直接运行，startup SUCCEEDED、engine destroyed、native_readbacks=0、failures=0；snapshot_calls=1796、snapshot_combined=0、total=1362.581ms、max=2.007ms。日志 `/tmp/aether-snapshot-hit.log`（临时证据，重启可能丢失）。源码 `WindowIntf.cpp` 的 TVPGodotGpuBatchScope 在窗口绘制内结束，呈现复制发生在其后，因此组件合并提交收益没有命中该呈现流程。下一步需评估绘制与呈现队列的事件同步或共享队列，而非继续把组件基准当成宿主优化收益。宿主 Debug 构建通过。

合并快照配对组件基准：`--snapshot-benchmark` 在同一进程交替 separate（end_batch 再 Snapshot）与 combined（Snapshot 再 end_batch），每条路径10次预热+60次采样，负载同为1080p clear+8次混合；计时包含编码、提交、GPU完成，像素检查在计时外。两轮 separate p50/p95/max=2.761/3.811/4.078ms、2.794/3.476/4.199ms；combined=2.629/2.972/3.167ms、2.630/2.823/3.564ms。p50下降约5%–6%，两轮共280张快照逐字节一致，failures=0、reads/textures=0。这验证合并提交在该组件负载的收益，不代表整体宿主或Godot对照；真实游戏批次是否在快照前已结束仍影响收益。工具命令已写入README，默认未设置性能断言以避免机器负载导致错误结论。

同步快照合并提交：Snapshot 直接在 pending 绘制缓冲后编码 blit，再一次 Finish，移除原先 FlushPending→Finish 的两次等待；CPU 可读返回及跨队列呈现安全语义保持。新增批次内快照→继续改写→end 测试，像素隔离通过。桥套件、Debug 构建、KAG3 Metal 30 秒输入/截图/关闭回归通过。该轮 snapshot_calls=1754、total=1245.787ms（平均0.710ms）、max=1.974ms、commands=1967、failures=0，证据 `out/apple_host/evidence/combined-snapshot-kag3/`。前轮平均0.808ms仅供诊断参考，两轮带截图且没有严格配对，不能把差值当作性能提升比例；正式对照仍需无截图串行采样。组件 --benchmark 在 snapshot 前已经 end_batch，不覆盖此次合并收益。

呈现快照计时：`AetherMetalBridgeCopyTexture` 记录进程累计 snapshot_calls/total_ms/max_ms（含分配、先前批次 flush、blit 与 GPU 等待；不含获得桥锁的等待）。KAG3 Metal 30 秒输入/截图/正常关闭回归通过，1751 次快照累计 1415.604ms，平均约 0.808ms，最大 2.729ms，failures=0。证据 `out/apple_host/evidence/snapshot-timing-kag3/`，Debug 构建通过。此为带截图测试的诊断基线，不是安静的无截图性能验收。呈现器使用独立 Metal 队列，不能直接删除 Snapshot 的 wait 而不增加跨队列同步；后续需比较共享事件同步或统一队列方案，并验证帧不可变及销毁安全。

真实消费者可观测：桥诊断增加进程累计 read_begin/read_pending_polls/read_complete/read_cancel。组件测试为 begin=3、complete=2、cancel=1，结束 reads=0；无效与重复 discard 不重复计数。Debug 构建及 KAG3 Metal 30 秒截图/输入/正常退出回归通过（`out/apple_host/evidence/readback-counters-kag3/`）。KAG3 本流程 read_begin=0、complete/cancel=0，native_copies=1750、native_readbacks=3（含测试截图），桥 failures=0。因此异步回读组件收益尚未命中该游戏流程，后续优先测量同步呈现快照复制路径；这些计数是进程累计而非每会话重置。

消费者契约修正：实际 `GodotTexture2D::CompletePendingGpuReadback` 在 ready 后清零句柄而不 discard；参考 Godot 桥 `BridgePollReadRgba` 同时消费请求。Metal 桥现已同样在成功 ready poll 后删除记录，修复消费者完成后快照残留。此前“可重复完成 poll 直到 discard”的描述与测试已撤销；discard 对已消费句柄仍安全。桥测试通过，reads/textures=0、failures=0。`EnsureCpuReadable` 在 pending 未完成时会取消并同步回读，因此异步收益依赖复制与首次 CPU 访问之间的间隔，不能推断稳态呈现收益。

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

### Published frame acquire 热路径（2026-10-11）

直通宿主每 tick 都要从 MetalBridge 取得最新 `FrameLease`。此前
`AcquirePublishedFrame` 先锁桥读取 token，再调用 `AcquireFrame` 二次加锁，形成每帧
两次递归锁与一次重复查表。本轮抽出 `AcquireFrameLocked`，让 published 路径在一次锁
持有期间完成代际、纹理和队列前置校验；旧的按 token 接口仍复用同一实现，外部 ABI
语义不变。诊断新增 `published_acquire_calls/misses`，用于确认 sink 暂无帧或代际失效
时没有静默吞帧。

Metal bridge 组件测试、核心库和 Debug 宿主构建通过；KAG3 Metal 30 秒 push-sink
冒烟通过，`published_acquire_calls=1749`、`published_acquire_misses=0`、
`leases_acquired/submitted/completed=1749/1749/1749`、`failures=0`、
`frame_detach_copies=0`，三次截图 RGB max diff 均为 0。单轮 profile 的 direct
稳态为 p50/p95/max=`1.269/1.782/6.209 ms`，该优化规模较小，需在后续配对基准中
继续评估；更大的收益仍来自统一引擎与呈现 command buffer、减少 Swift/ObjC 边界和
纹理分配。
