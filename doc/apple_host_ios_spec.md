# Aether 原生宿主 iOS/iPadOS 迁移 Spec

- 日期：2026-10-12；版本：1.0；状态：设计基线，尚未实现 iOS target。
- macOS 代码基线：`a52696b6`；既有功能来源见 [UI spec](apple_host_ui_spec.md)。
- 最低部署版本：**iOS 18.0 / iPadOS 18.0**，iPhone 与 iPad 原生应用，不走 Mac Catalyst。
- 关联：[实践与验收](apple_host_ios_plan.md) · [历史移交](apple_host_ios_handoff.md) · [接缝](apple_host_seam_inventory.md)。本 spec 覆盖旧移交说明中的 iOS 16 基线。

## 1. 范围与交付定义

M4 交付可在 iOS 18 起运行的视觉小说宿主：协议门→游戏库→目录/ZIP 导入→详情→游戏→返回，含封面、五语言、四主题、设置、移动输入、诊断与真实 IAP。完成与否由实践文档逐项证据判定。

保留 `engine_api`/provider ABI，不把 Godot/SDL 引入原生 App；不得将 macOS 二进制作为 iOS 链接依赖。首期只提供 KiriKiri；ONS/Siglus 按用户最新安排暂缓，保留原实现，不作为首期运行时闸门。视频库不在 iOS 导航中，不新增维护；Minori 暂缓；未实现 P5b 算法不开放；G1 不阻塞 M4；更新器最后，iOS 分发走商店渠道。游戏中的影片如由既有 runtime 播放，不等同于独立视频库。

G4 仍要求 iPad 真机 Demo + 一个用户提供、允许在该平台测试的真实标题。本 spec 另要求 iPhone 触屏与布局验收；模拟器、StoreKit 本地配置和测试注入不能替代真机证据。verified_games 只在用户确认后登记。

## 2. 可验证要求

| ID | 要求 | 完成证据 |
|---|---|---|
| IOS-01 | iPhone/iPad target 部署18.0，device与simulator分开编译 | SDK/架构/平台元数据、两目标构建日志与 iOS18 启动 |
| IOS-02 | 冻结 ABI、共享引擎资源所有权、平台适配独立 | ABI diff、链接依赖、provider注册探针、macOS回归 |
| IOS-03 | 导入复制、库/存档持久化、失败不留下条目 | 真机 Files 导入、重启/低空间/取消/路径失败测试 |
| IOS-04 | 44pt触控区、安全区、紧凑与宽布局、无hover依赖 | iPhone/iPad横竖屏与窄窗口截图、触屏/无障碍验收 |
| IOS-05 | 点击/拖动/取消/虚拟按键/IME使用正确坐标且不卡键 | 事件序列、非对称fixture、真机操作与重启释放测试 |
| IOS-06 | CADisplayLink真实dt、GPU lease、后台停止、恢复不追赶 | 60/高刷新/后台trace、无额外回读、lease清理 |
| IOS-07 | 音频启动、中断/路由变化/恢复行为明确 | 真机扬声器/耳机/中断测试、激活结果日志 |
| IOS-08 | 设置迁移、能力禁用原因、双文档协议/拒绝页 | 旧schema测试、五语言UI、协议版本与写盘失败测试 |
| IOS-09 | StoreKit verified交易、恢复与coffee幂等、库限制 | 本地故障测试 + sandbox真机 + 交易台账证据 |
| IOS-10 | 诊断导出、低频UI、内存与热状态、完整退出 | 文件验证、菜单响应采样、内存警告与长时真机记录 |

## 3. 架构与复用边界

共享层保持 Foundation/CoreGraphics/Metal 可移植逻辑：库索引、设置草稿、协议记录、输入坐标、FrameScheduler、虚拟控制状态、增强核、诊断数据。`EngineSession.mm`、`MetalBridge.mm`按 iOS SDK 编译，保留队列与 FrameLease 生命周期。

平台层提供以下宿主能力（内部 Swift/ObjC 接口，不新增 C ABI）：

| 能力 | macOS现状 | iOS实现目标 |
|---|---|---|
| UI与场景 | AppKit窗口、NSViewRepresentable | UIKit/UIViewRepresentable、单个游戏会话所属 scene |
| 文件/封面选择 | NSOpenPanel | UIDocumentPicker、PhotosPicker可选、导入复制 |
| 帧钟 | CVDisplayLink / Timer | CADisplayLink；无活动scene时停止 |
| 游戏输入 | NSView/NSTextInputClient | UIView触摸 + UIKit文本输入客户端 |
| 打开URL/导出 | NSWorkspace/NSSavePanel | UIApplication.open / 系统分享页、明确失败响应 |
| 商店 | 降级provider | StoreKit2 adapter，复用既有商品与协议语义 |
| 方向/沉浸 | NSWindow fullscreen | scene方向请求、显示/隐藏游戏工具栏 |

`ShellModel`与`EngineController`当前直接依赖AppKit，不可宣称可直接编译iOS：提取路径服务、窗口/scene操作、音频与浏览器能力；UI按平台编译隔离。macOS现有target和共享数据格式保持兼容。

采用一个游戏引擎会话和一个拥有者 scene；初期不支持多游戏窗口。scene销毁必须关闭媒体依赖、停止帧钟、drain GPU、释放lease再销毁引擎。异步导入/封面/provider结果绑定会话标识，旧回调不能进入新会话。

## 4. 触屏交互契约

### 4.1 主壳与详情

iPhone紧凑宽度：底部三个目的地「主页 / 游戏库 / 设置」，详情用导航栈推入，导入/搜索有可见入口。iPad宽布局用侧栏+内容；变窄时退为紧凑导航，不能依赖设备型号判断宽度。游戏运行时隐藏壳导航，保留返回、控制板、游戏菜单；活动会话期间不允许另开全局设置。

壳层使用系统文字样式与Dynamic Type；长中日英韩标题可换行或有可访问完整名称。扩大字体时重排，不压缩触控区。四主题需验证文字与按钮在浅/深色游戏背景上可读；Reduce Motion关闭非必要过渡。

可交互区域至少44×44 **pt**，相邻点击区域不得重叠；尺寸调整档位只改变间距/密度，不能缩小到44pt以下。Apple对按钮点击区域的建议见 [Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons)。关键操作有可见文字或VoiceOver标签，不只靠长按、hover或硬件键盘。

黑背景可延伸到屏幕边缘，工具栏、控制板与有效点击内容避开刘海和Home指示条；以实际安全区与窗口尺寸布局，不硬编码型号边距。见 Apple [Layout](https://developer.apple.com/design/human-interface-guidelines/layout)。

导入显示进度与取消；移除只移除记录，明确是否保留托管文件；删除文件如以后提供，另设独立确认。封面选择/清除/在线搜索保留，在线搜索只在用户显式触发时发送标题，损坏图片、取消与迟到结果不替换现有封面。

### 4.2 游戏画布与事件所有权

默认直接触摸模式。单指按下/移动/抬起按既有 POINTER_DOWN/MOVE/UP 协议发送，主触点映射左键。不要同时使用SwiftUI tap与UIKit触摸重复发送点击。游戏逻辑画布始终为原始游戏像素，不随Retina/output档位改变。

统一映射：UIKit本地pt → 安全区布局后的实际aspect-fit矩形 → 逻辑游戏坐标。黑边按下不发送事件；画布内开始的拖动移出画布仍保留捕获，坐标按既有映射策略夹到边界，抬起/取消必须回传。旋转、resize、键盘弹出或显示模式变化时取消旧手势并重新计算映射，不能用整个view宽高分别缩放拖动delta。

初期每次手势只捕获一个主触点；第二指不发游戏点击、不切换主指，不实现未验证的双指手势。主指离开后其余手指必须全部离开才开始新序列。触控板/鼠标、Apple Pencil如有输入按主指针处理，不依赖压力，不作为必备设备。

系统边缘手势保留。返回/菜单/虚拟控制板消费自己的触摸，不能穿透到游戏；打开会拦截输入的sheet时取消捕获并释放所有宿主按键。scene inactive/background、来电、方向改变、界面消失、游戏返回与失败都执行幂等release/cancel。

### 4.3 虚拟控制板

顶栏「显示控制板/隐藏控制板」一次操作生效；画布入口、菜单与诊断共享会话状态，入口偏好不阻止顶栏显式打开。面板避开安全区，iPhone以两行/分组布局展示回车、空格、Esc、方向、PgUp/PgDn与Ctrl，不把macOS单行键盘缩小移植。

普通虚拟键为一次down/up；保持Ctrl必须有明确选中状态，关闭/隐藏/模式切换/失焦时释放。快速双击不会留下重叠持有键。直接触摸/虚拟鼠标模式可选择，虚拟鼠标支持拖动手柄与独立左键按钮，按aspect-fit同一比例映射，指针位置可见。

键帽透明度只影响视觉，不减小触控范围；模式文字与指针保持可读，不能以透明度导致功能不可发现。沉浸模式隐藏工具栏后保留44pt的「显示工具栏」按钮；点它不推进游戏。初版不自动隐藏关键入口。

### 4.4 文字与可访问性

系统键盘仅在用户手动输入或引擎编辑控件有效时出现。实现UIKit输入客户端/编辑代理，不每帧抢firstResponder；合成与提交分离，中文/日文/韩文候选期间不逐次提交中间文本。复用TEXT_INPUT及既有preedit选项，provider不支持preedit时保留最终提交路径，明确记录能力。

键盘占用空间触发布局重算；caret由逻辑画布映射到当前窗口，不能穿到刘海/键盘下。手动文本、平台请求FIFO弹窗的提交/取消只回应一次，新游戏不接收旧响应。VoiceOver可操作宿主导航/控制板/错误与协议，游戏像素画面内部无语义时明确限制，不能声称游戏文本全部可读。

## 5. 调度、Metal与生命周期

iOS使用CADisplayLink而非CVDisplayLink，复用纯FrameScheduler与毫秒余数；请求刷新率不是实际保证，系统可因电源/热策略调整。参考 [CADisplayLink](https://developer.apple.com/documentation/quartzcore/cadisplaylink)。目标档60/80/90/120/144保留跨平台偏好，UI说明“目标上限”；实际不超设备/系统回调率，不为了144在120Hz设备上忙轮询。

默认不限引擎FPS、跟随显示回调；用户限制时下发fps_limit并门控宿主tick，真实elapsed推进；不继续传固定16ms。inactive先释放输入与重置时钟，background停止tick/draw并调用现有pause；active且无中断原因时resume。暂停理由集合覆盖后台、音频中断和系统modal，清除一个理由不能绕过其他暂停。恢复首tick不包含后台耗时，无catch-up burst。

GPU与producer同队列，lease随命令完成释放；停止后先drain再destroy。无新帧复用纹理，不发布新的身份触发壳重建；UI统计最多4Hz（macOS `a52696b6`回归项）。CPU fallback必须记录实际管线，增强失败退原画面，正常路径不逐帧CPU回读。

首次移动默认输出original、增强off以控制内存；旧设置中的算法/输出选择不静默覆盖，启动能力不足报告有效回退。4K只在移动内存预算验收后开放；能力未验证时禁用并说明原因。内存警告清理可重建缓存；thermal serious/critical降低有效输出/增强负载并报告，不修改持久偏好。具体设备预算由阶段I4测试定稿，不能用macOS 32GiB结果推导iPhone安全预算。

## 6. 文件、音频与协议

Documents/Games为托管库，Application Support存设置/库索引/协议/诊断，Caches存可重建数据。保存重启后不依赖临时URL；可移动文件路径用相对路径或重新定位策略。默认从Files选择目录/ZIP并复制到临时staging，校验入口与空间后原子入库；受限解压规则沿用现实现并按剩余空间收紧。

读取外部目录时成对管理security scope与文件协调，等待iCloud下载、拒绝越界/链接、失败可重试；不把外部security-scoped URL直接当永久普通路径。外部引用/书签作为I2b独立能力，先以复制完成闭环。Apple [Providing access to directories](https://developer.apple.com/documentation/uikit/providing-access-to-directories)说明目录选择返回security-scoped URL。

启动前使用已声明的`engine_legacy_activate_audio_session_for_host`，必要的内部HostKit封装不改变公共ABI；引擎负责OpenAL输出。默认前台游戏音频，后台停止，不申请背景播放；category/静音开关策略在I3明确配置并真机记录，避免宿主与runtime竞争修改会话。音频中断开始暂停，结束按系统恢复提示及用户会话状态恢复；路由拔出暂停并提示。见 [Handling audio interruptions](https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions)。Minori不因本条重新进入适配队列。

双文档协议按版本独立存储，拒绝进入「已拒绝」页，可重新阅读/同意，不调用exit/terminate。保存接受失败不能放行；Debug绕过不进入Release。平台请求逐项明确支持/失败响应，浏览器/分享失败可观测，不让runtime无限等待。

## 7. 设置、StoreKit与诊断

移动设置增加横屏锁定与compact/comfortable/standard（默认comfortable），版本化迁移，保持草稿事务；macOS不显示移动项。横屏是scene支持的请求，失败保留当前可用布局并提示，退出游戏恢复壳方向策略，不强制设备朝向。iPad窄窗口仍可玩，不要求全屏排他。参考 [requestGeometryUpdate](https://developer.apple.com/documentation/uikit/uiwindowscene/requestgeometryupdate(_:errorhandler:))。

`com.aether.list.limit`非消耗型永久解锁；`com.aether.coffee`消耗型30天权益复用现有台账规则，先对照实现明确期限叠加，不自创新商品。未解锁条目阈值在I5从Godot实际gate与商品配置核实并锁定测试，文档不猜数量；限制只阻止新增超限条目，不删除现有游戏/存档。StoreKit未接入阶段不开假购买、不启用无法解锁的产品限制。

交易处理验证签名→按transaction ID幂等持久发放→finish；启动监听updates，非消耗型读取currentEntitlements，撤销/退款更新权益。coffee消耗台账需持久化与重复投递测试，不把currentEntitlements当消耗型历史。恢复/查询/等待批准/取消/无网/失败各有UI状态；未验证交易不发权益。参考 [currentEntitlements](https://developer.apple.com/documentation/storekit/transaction/currententitlements)。本地StoreKit配置只能验证逻辑，sandbox真机验证真实链路；真实购买由用户操作。

诊断紧凑设备用独立sheet/页，宽iPad可并排，关闭后恢复画布映射。事件/插件探针只在采样或明确动作发生，不在View.body内做磁盘/provider查询。日志分页或限长，统计低频，过滤/暂停只影响显示。导出使用临时文件与系统分享，保留真实renderer、tick/render/presentation口径；本机路径不默认上传。截图需用户明确动作，保存失败不显示成功。

## 8. 完成与证据边界

全部IOS-01…10及实践文档阶段I0…I6闭环后才可称M4完成；构建成功或模拟器单图不能证明真机可玩。证据记录commit、设备/OS、构建配置、provider集合、数据fixture、执行步骤和PASS/FAIL；未覆盖、阻塞与暂缓逐项保留。

本 spec 是项目实现要求；Apple链接用于技术依据，不等于本项目已通过Apple审核。当前仅文档建立，iOS构建/触屏/StoreKit都未验收。
