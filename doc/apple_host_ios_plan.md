# iOS 18 / iPadOS 18 迁移实践与验收

- 日期：2026-10-12；状态：I0/I1实施中；要求来源：[iOS spec](apple_host_ios_spec.md)。
- 当前macOS基线 `a52696b6`；正式工程已新增AetherHostIOS/AetherHostIOSTests；目前已接协议门、原生库/Files、封面、基础设置与Metal/软件Demo；完整移动输入、平台请求、设置能力及阶段验收仍在实施。
- 每阶段交付代码、实际执行、失败路径、测试、文档与一次commit/push。阶段标记只依据证据，不依据控件已出现。

## 1. 工作原则

先阅读AGENTS.md、spec、历史移交、ABI及现有iOS Godot构建参考；记录SDK、Xcode、设备与provider可用性。不得撤销其他任务修改。每轮提交完整已验收切片，不为“移动移植”删除macOS实现或修改公共ABI。

顺序I0→I1→I2→I3→I4→I5→I6；I2b外部引用在复制导入完成后推进。按用户安排先用可用iOS26环境推进，随后补iOS18运行验证；deployment仍为18.0。模拟器做布局/逻辑，iPad和iPhone真机做触摸、GPU、音频、内存及商店。iOS18设备或runtime缺失时明示阻塞，不能以更高OS通过冒充18兼容。

## 2. 分阶段实践

### I0：依赖盘点与交叉编译（IOS-01/02）

- [x] 保存工具链与设备清单；运行 `xcodebuild -version`、`xcodebuild -showsdks`、`xcrun simctl list devices available`、`xcrun devicectl list devices`。
- [ ] 盘点CMake/vcpkg/Rust/FFmpeg/OpenAL/插件的iphoneos与iphonesimulator支持；记录每个provider可用、缺依赖或暂缓原因。首期只提供KiriKiri，ONS/Siglus按用户最新安排暂不接入，不用假provider代替。
- [x] 新增可重复的 `tools/apple_host_ios_build.py`（建议名），参数区分device/simulator、configuration和provider集合；产物隔离在 `out/apple_host/ios/{device,simulator}/`。
- [ ] CMake明确iOS system、SDK、arm64、deployment18.0；依赖自身最低版本也审计。device与simulator虽同arm64，平台不同，不共用对象/缓存目录。
- [ ] 确立链接ADR：首版优先静态core+engine闭包，macOS保持现SHARED；如果用动态库须构建合法framework并签名。明确static constructor是否被dead-strip，provider注册须有实际探针；force-load仅对确有需要的归档，避免重复engine单例。
- [ ] `file`/`otool -L`/`xcrun vtool -show-build`检查平台、minOS与依赖；不得出现macOS dylib、Godot或SDL宿主依赖。

验收：两个SDK的真实core构建日志、ABI差异为零、provider注册与API version可查询；将准确triplet/选项固化到脚本，不复制macOS路径当成功。失败依赖有最小复现与下一动作。

### I1：原生target与平台接缝（IOS-01/02/06/08）

- [x] 在XcodeGen中新增 `AetherHostIOS` target/scheme，iOS18.0、iPhone+iPad、独立bundle id与Info.plist；签名team由本机配置提供，不把证书/账户写入仓库。
- [ ] 提取平台路径、浏览器、scene、帧钟、文件与导出接口；AppKit视图保留macOS，UIKit实现按平台source group隔离。共享层不能import AppKit。
- [ ] 桥接头审计，legacy音频session符号可在HostKit内部封装；不修改ABI/provider表。
- [ ] UIKit MTKView、CADisplayLink、FrameScheduler连接最小Demo；保留native lease和GPU错误回退，兼容可选rendered query。
- [ ] 生命周期采用暂停理由集合，旧async回调绑定session generation；不能允许后台timer运行或恢复追赶。
- [ ] 打包五语言/字体/许可证/Demo；双协议门与拒绝页先接入，Release禁用绕过。

验收：iOS18模拟器启动，iPad真机显示Demo且可tick，切后台返回正常，反复启动/退出资源清理；macOS构建和既有行为回归通过。模拟器缺GPU能力可测fallback，但不能替代iPad Metal证明。

### I2：库、导入与移动导航（IOS-03/04/08）

- [ ] iPhone三目的地导航、iPad自适应侧栏、详情推入/返回；停止独立视频库入口，非仅隐藏仍可误触的按钮。
- [ ] 平台目录服务；相对托管路径持久化，库索引与staging原子发布。
- [ ] Files目录/ZIP导入：scope、协调、iCloud材料化、空间预检、解压限制、取消、重复导入、出错恢复。
- [ ] 图片选择/清除/发现；在线搜索绑定游戏与request ID，取消后结果失效，验证图片再替换。
- [ ] 设置草稿、五语言、四主题、Dynamic Type、移动界面比例与横屏偏好迁移；移动默认original/off，macOS默认不变。

验收：iPhone/iPad从Files导入fixture，无代码干预完成启动/返回/重启恢复；导入失败不留下幽灵条目。云文件、权限拒绝/磁盘不足分别测试，不用内置Demo替代文件导入验收。

#### I2b：外部目录引用与书签（IOS-03）

- [ ] 独立于复制导入选择；scope贯穿引擎读写会话，开始/停止配对，书签解析、失效重选、provider移动/离线清楚提示。
- [ ] 真实文件provider验证书签与存档写入；受限provider不支持时回到复制导入，不能伪称引用成功。

验收：重启、目录移动、访问撤销、iCloud离线、存档写入。若不支持可靠引用，记录能力原因并禁用该入口，不能牺牲复制闭环。

### I3：触屏、IME、方向与音频（IOS-04/05/07）

- [ ] UIKit触摸状态机：单主指、第二指忽略、cancel/release；宿主按钮与画布互斥命中，系统边缘手势保留。
- [ ] aspect-fit矩形是指针、虚拟拖动与caret共用输入；pt/pixel/output三种尺寸分离，所有resize/旋转取消捕获。
- [ ] 控制板两行/分组44pt布局、顶栏直接开关、状态/诊断统一、Ctrl保持与释放、鼠标指针可见。
- [ ] UIKit IME客户端与provider预编辑能力、手动输入sheet、FIFO平台请求及取消响应；不抢焦点、不重复Unicode提交。
- [ ] scene方向请求失败处理；iPad窄窗口与键盘占用不强制物理横屏。返库恢复方向策略。
- [ ] 引擎音频session激活、中断/路由监听与暂停理由；category和静音开关的实际行为写入最终ADR，前后台不申请后台音频。

必须执行的事件矩阵：

| 场景 | 期望 |
|---|---|
| 画布点击四角/中心、黑边点击 | 映射fixture正确，黑边零down |
| 拖出边界后抬起、系统取消 | 完整down→move→up/cancel，没有残留 |
| 两指交叠、先抬主指 | 无重复点击、无第二指接管 |
| 控制板点击、显示工具栏、系统modal | 不穿透游戏，既有捕获取消 |
| Ctrl按住后隐藏/切模式/失焦/返库 | held=no，引擎收到对应release |
| 旋转、窄窗resize、键盘出现 | 新坐标正确、旧序列取消 |
| 中日韩合成、删除、粘贴、取消 | 候选可用、最终文本一次提交 |
| 来电/系统中断、耳机拔出、前后台 | 音频按契约暂停/恢复，dt无后台间隔 |

验收：单元事件序列+实际引擎fixture+iPhone/iPad真机视频/日志；CJK候选窗不能只用字符串单测证明。辅助技术验证宿主控件，不夸大像素游戏内部可访问性。

### I4：画面、诊断与负载（IOS-06/10）

- [ ] 原生/软件fixture同刻对照，GPU lease清理、resize/旋转/恢复稳定；增强按移动能力开放，未验证4K禁用。
- [ ] 60Hz与高刷新设备真实dt/限频与统计口径；高刷新目标不可超设备能力，低电量/系统变频不加速剧情。
- [ ] compact诊断sheet与宽屏dock；缓存插件信息，不在View.body读磁盘/provider；统计≤4Hz，静态native帧不复制发布新纹理。
- [ ] 复测 `a52696b6` 菜单卡顿修复、`8175b1f2` 控制板状态修复，菜单开关不重建全壳120次/秒。
- [ ] 截图、快照、导出分享实际文件可解析；后台分享完成不响应旧session。
- [ ] 内存警告、thermal策略、可重建缓存回收、无黑屏回退；在低内存代表设备记录峰值及可用输出档。

验收：每种路径至少5分钟短回归；代表iPhone和iPad至少30分钟游玩+10轮后台/返回+10轮会话重开，记录峰值、增长趋势、失败计数和lease。预算未定稿前不勾IOS-10完成；snapshot/self-check通过不替代渲染长期验收。

### I5：StoreKit与产品限制（IOS-09）

- [ ] 从既有apple_storekit.swift核对商品类型、coffee叠加期限、库阈值与平台purchase协议，形成共享权益模型和断言。
- [ ] 启动监听updates、verified交易、transaction ID台账、发放持久成功后finish、恢复/currentEntitlements/撤销；coffee独立台账与Keychain失败保留待发交易。
- [ ] 首先本地StoreKit配置与故障注入：购买成功/取消/pending/unverified/退款/过期/重复通知/崩溃中断；随后sandbox真机。
- [ ] 仅真实provider就绪后启用库限制与购买入口；超限保留既有条目，macOS不受限制。无网不能删除缓存权益，缓存是否过期与重新验证策略明确。

验收：本地和sandbox证据分别列出；恢复非消耗型、coffee重投不重复延长、发放失败重试；实际商店提交/交易由用户操作，代理不得伪造签名或购买成功。需要商店账号/商品状态时先完成其余可验收工作。

### I6：G4与交付审计（IOS-01…10）

- [ ] iPad iOS18真机Demo + 1真实标题（导入、剧情、选择、存读档、返库/冷启动恢复）；标题出处/平台测试范围满足用户授权，Minori仍不加入。
- [ ] iPhone18真机触摸闭环；再测当前更高OS以确认兼容性；SDK更高不等于能调用仅更高OS API。
- [ ] 中文/繁中/英/日/韩、四主题、Dynamic Type最大辅助档、VoiceOver、Reduce Motion、横竖屏/窄窗/安全区验收。
- [ ] Release归档、资源/许可证、签名、权限声明、隐私manifest按实际SDK诊断核实；不增加无用途权限，不自动发布商店。
- [ ] IOS要求矩阵全部有证据或明确未完成；用户确认后才登记verified_games。

最终交付：构建脚本与复现命令、provider支持矩阵、真机报告、截图/录屏、遗留列表、commit；不因一个绿构建或仅更高OS成功就宣布18支持完成。

## 3. 实施命令契约

以下Debug命令已实际执行。先从CMake生成两个SDK的链接闭包，再生成Xcode工程；Release需对应用 `--configuration Release` 生成自己的归档与响应文件：

```bash
python3 tools/apple_host_ios_build.py --sdk iphoneos --configuration Debug
python3 tools/apple_host_ios_build.py --sdk iphonesimulator --configuration Debug
python3 tools/apple_host_ios_xcode_link.py --configuration Debug
xcodegen generate --spec apps/apple_host/project.yml
xcodebuild -project apps/apple_host/AetherHost.xcodeproj -scheme AetherHostIOS \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath out/apple_host/ios/simulator-app build CODE_SIGNING_ALLOWED=NO
xcodebuild -project apps/apple_host/AetherHost.xcodeproj -scheme AetherHostIOS \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath out/apple_host/ios/device-app build CODE_SIGNING_ALLOWED=NO
python3 tools/apple_host_settings_tests.py
```

无签名device构建只证明编译，安装真机需已配置签名与实际device ID。xcrun devicectl/simctl用本机帮助确认参数，设备ID从清单读取，不编造。iOS18模拟器runtime缺失时记录并配置可用runtime后再验收。

新增共享逻辑应进现有行为套件；新增UIKit逻辑建立iOS XCTest target（建议 `AetherHostIOSTests`），涵盖状态机/映射/scene lifecycle；XCUITest用于控制板/Files/设置/协议交互。若CUA仅能控制桌面，可控制Simulator窗口做可见点验；真机采用实际设备自动化或人工步骤+录屏/日志，不声称桌面CUA等于真机触屏。

## 4. 证据与推进记录模板

证据放 `out/apple_host/evidence/ios-I<n>-<case>/`；out不入Git，进度文档记录目录与关键结论。可复现fixture源码/脚本入Git，真实游戏内容与凭据不入Git。

每份报告记录：commit、Xcode/SDK、OS/device/model、device/simulator、configuration、provider列表、renderer/output/增强、操作步骤、实际结果、日志/截图/视频路径、未覆盖项。日志至少含dt、tick/render/presentation、pause原因、session generation、GPU/lease结果；不得混用scanout与提交FPS。

阶段更新模板：

| 要求ID/案例 | 当前状态 | 证据路径/命令 | 失败原因或未覆盖 | 下一动作 |
|---|---|---|---|---|
| IOS-xx / case | 未开始/实现中/已验证/受阻 | 实际日志或文件 | 明确边界 | 可执行动作 |

Goal模式按阶段持续推进，阶段完成不等于整个M4完成。达到G4前对照IOS-01…10和所有I0…I6检查项重新审计；缺真机/商品/签名时保持未完成，记录具体阻塞，继续独立任务。每轮commit/push并报告验证结果，更新器/视频/Minori暂缓不反复占用队列。


## 5. I0 实践记录（2026-10-12）

- 工具链：Xcode26.0.1 / iOS26 SDK；模拟器只有26.0。配对iPad Pro11 (4th gen)与iPhone16 Pro均offline/unavailable；最低18.0构建不等于已实测18运行。
- 已建立 `tools/apple_host_ios_build.py`，专用arm64-ios18 / arm64-ios18-simulator triplet、独立build/cache、默认且仅允许KiriKiri；Godot宿主及ONS/Siglus/Minori/Internal不构建（依赖manifest仍包含godot-cpp等额外包），旧Godot配置保留。
- iOS host core改STATIC（macOS仍SHARED）；静态App后续必须显式调用initialize并验证注册与链接闭包。当前脚本生成core与engine_api归档，不是App打包器。
- 首次simulator配置在GNU libiconv命令行安装包装器缺 `_memeq` 失败；两SDK系统iconv编译/链接探针通过，新triplet使用SDK iconv，vcpkg已越过该失败点。应用中文编码正确性尚须fixture验证。
- SDK分离、18.0配置、暂缓provider拒绝与脚本语法检查通过；引擎构建结果以各build目录的build-result.json与日志为准，不由脚本语法通过推导完成。

- 后续依赖：OpenSSL配置曾因模拟器旧triplet的分号参数列表被legacy make helper截断而失败；本轮专用triplet改为shell参数串后OpenSSL/curl/FFmpeg继续安装。探针Mach-O平台分别为IOS/IOSSIMULATOR，minOS均18.0，SDK26.0。
- 当轮完整simulator核心构建仍进行依赖安装，未产出可验收引擎归档；I0保持“实施中”。最新进程与状态以 `out/apple_host/ios/simulator/debug/build-result.json` 和configure.log为准，下轮先检查，不因观察超时重启任务。


## 6. iOS 26 优先验证与 UIKit 探针（2026-10-12）

- 用户允许先测26再逐步补18；18.0部署约束、API可用性及最终18运行验收不变。
- 新增内部 `IOSProbe`，通过 `python3 tools/apple_host_ios_build.py --sdk iphonesimulator --probe-app` 构建；链接真实KiriKiri静态闭包，显式initialize，携带仓库KAG3 Demo和字体。它只用于迁移接缝验证，不是产品UI，也不提供商店/协议门/Files导入。
- 探针实现安全区、44pt按钮、软件帧显示、单主指画布映射/黑边拒绝/取消、Enter、停止与scene暂停恢复；使用CADisplayLink真实elapsed并限制恢复追赶。软件帧不构成Metal/GPU性能证据。
- libffi揭示新make helper需要列表而OpenSSL旧helper需要shell参数串；参数串修正现仅限定OpenSSL，避免破坏其他依赖。
- 源码SDK语法检查通过；完整App链接与iOS26 CUA结果须另记实际结果。iOS18运行、device核心、产品Shell与G4仍未完成。

### 2026-10-12：iOS 26 Simulator UIKit 探针验收

- `iphonesimulator` Debug 探针已完成完整链接，Mach-O 为 `IOSSIMULATOR`、最低版本18.0、SDK26.0；已补 CoreText 链接以满足 KiriKiri 字体枚举。
- CUA 设备：iPad Pro 11-inch (M4)，iOS26.0。真实 KAG3 Demo 启动为 `state=2`、输出640x480；点击画布产生 pointer down/up 并推进场景，Enter 产生 key 事件，Stop 清理会话。
- 通过 Home 切后台、再次启动后继续出帧；日志记录 `Host lifecycle deactivate/activate`，没有黑屏或启动错误。证据：`out/apple_host/evidence/ios-I1-probe26/`（stdout/stderr）及 `out/apple_host/ios/simulator/debug/build-result.json`。
- 该证据只覆盖 iOS26 Simulator 的 KiriKiri 软件帧、UIKit 触摸/按键和生命周期；不替代 iOS18 runtime、真机 Metal/音频、产品 Shell、Files/StoreKit 或 G4 验收。


## 7. 双 SDK 与移动生命周期接缝（2026-10-13）

- 中断前的device构建已实际结束且成功。现在 `iphoneos` / `iphonesimulator` Debug 核心和 UIKit 探针均完整构建；两个App的Mach-O分别为IOS / IOSSIMULATOR，minOS18.0、SDK26.0。日志与build-result分别在 `out/apple_host/ios/{device,simulator}/debug/`。device未签名、未安装真机，不据此宣称G4或18运行通过。
- 新增可复用 `IOSHost/MobileSessionDriver`，接管CADisplayLink、毫秒余数、scene/application通知、音频中断与路由暂停；HostKit封装既有 `engine_legacy_activate_audio_session_for_host`，公共ABI/provider表未改。
- 原因集合覆盖scene inactive、application inactive、音频中断、等待用户恢复、音频激活失败、系统modal及媒体服务丢失。清除一个原因不会恢复其他原因仍存在的会话；停止移除观察者并递增generation，延迟旧通知不得访问新会话。
- 实测修复scene先激活、UIApplication仍inactive导致音频激活被拒绝的时序问题：单独保留application暂停原因，收到真正的应用激活后重试。恢复首tick为0，后台间隔不追赶，单次前台stall最多100ms。
- 音频策略ADR：宿主在开启会话前配置 `.playback` / `.default` / 无混音选项，前台游戏音频按代码契约不受静音开关限制；不启用后台音频。runtime负责OpenAL与共享激活。耳机输出消失暂停并允许显式恢复；媒体服务丢失/重置保持暂停，须重开游戏，不把未验证的OpenAL重建当作已实现。静音/扬声器/耳机/电话中断实际行为仍待真机记录。
- `MobileSessionTimingTests.cpp`：120Hz一秒推进1000ms、重叠暂停、恢复/停止时钟清零、长帧上限、非法与倒退时钟通过。
- `tools/apple_host_ios_lifecycle_tests.py --device <booted simulator UUID>`：编译上述测试、构建安装真实KiriKiri探针、运行Debug-only通知注入并保存JSON。15项测试全部通过；暂停期间tick不增加，恢复首dt=0，停止后观察者和帧钟不再响应。证据 `out/apple_host/evidence/ios-I3-lifecycle26/result.json` / stdout.log / stderr.log。这是通知注入，不是真机音频或本轮CUA证据；本轮无可用CUA工具，未声称可见操作验收。
- macOS完整 `apple_host_settings_tests.py` 回归通过。正式XcodeGen iOS产品target、Metal直通、协议门、库/Files、IME/控制板、StoreKit与iOS18/真机验收仍未完成；I0/I1/I3保持实施中。


## 8. 正式 iOS target 与协议门（2026-10-13）

- 新增XcodeGen `AetherHostIOS` / `AetherHostIOSTests`，原生iPhone+iPad、最低18.0，独立bundle ID `org.github.aetherkiri.host.ios`。Debug的device与simulator产品构建通过；签名团队由本机Xcode提供，未写入账户/证书。
- `apple_host_ios_xcode_link.py`通过CMake File API读取已构建探针的真实静态链接闭包，输出按configuration/SDK分开的driver响应文件。产品独立编译自己的HostKit/IOSHost对象，不链接探针main或测试helper；过滤构建机rpath，macOS依赖/target保持原样。首次产品构建须先生成响应文件，不能仅拿两个.a当完整engine。
- 移动主壳复用LegalAcceptanceStore和全部五语言法律/字体/许可证资源，按privacy→statement独立版本记录；拒绝进入独立页面，允许重读；资源不可读禁用接受、写盘失败不放行。主页提供可实际启动的Demo和文档阅读，未提供未完成的库/设置控件。
- 独立MobileGameController复用MobileSessionDriver与抽出的MobileGameCanvas；当前为software/raw_source原始输出，绑定逻辑尺寸与输入，确认返回暂停modal，停止时释放输入、停钟、drain后销毁。返回实际主页；后续I2接完整游戏库后再改返库。
- Debug/Release语义的隔离模型测试通过：拒绝/重读、双文档顺序、独立持久化、失败写入、损坏记录、Demo原子安装、Release忽略Debug绕过。iOS26实际XCTest四项通过，包括打包的五语言两文档资源（`xctest-r3.xcresult`）。
- iPadOS26的iPad Pro M4与iOS26的iPhone17 Pro Simulator普通首启截图均为协议页，正文可滚动、操作区避开安全区；Debug环境 `AETHER_HOST_BYPASS_LEGAL_GATE=1` + `--ios-demo-smoke`启动真实Demo，日志API17170432、第一帧software640x480。没有代理点击同意按钮，没有写入真实协议接受记录。该入口在Release条件编译移除。
- 证据 `out/apple_host/evidence/ios-I1-product-shell/`，含gate.png、demo.png、模型测试日志、XCTest结果、正式App运行日志。截图为simctl开发工具捕获并视觉核查，不声称本轮CUA点击/返回流程已验收；CUA工具本轮未提供。
- 抽取画布后15项真实引擎生命周期注入及macOS完整行为回归通过。仍未完成：Metal/lease直通、完整库/Files/封面/设置/主题/移动IME控制板、平台请求、StoreKit、iOS18 runtime、真机音频/长时/G4及Release正式归档。


## 9. iOS Metal 同队列呈现（2026-10-13）

- 产品游戏控制器默认启用既有godot_native ABI后端和原始帧；新增MobileMetalPresenter，通过MTKView、同一bridge队列及FrameLease提交边界显示，不做正常路径CPU回读。没有新帧时保留纹理，不重新获取同一serial的lease；drawable按比例适配，输入仍以原始逻辑像素映射。
- 实测修复静态App的frame sink注册缺失：iOS直接调用已有 `engine_register_native_frame_sink`，防止dlsym可见性/dead-strip使注册静默失效；macOS保持可选动态符号查找，ABI未改。
- 初始化失败选择软件引擎；呈现失败移除Metal视图、释放lease/drain后使用软件图像，保留实际引擎后端。界面显示五语言降级文案；Debug注入 `AETHER_IOS_FAIL_PRESENTATION=1`用于验证后者，Release不包含注入。
- iPadOS26 Simulator真实KAG3 Metal首帧640x480，截图视觉核查方向、比例与文本；正常XCTest至少提交10帧，`native_copies=0`、`native_readbacks=0`，结束后 `leases_live=0`、`lease_failures=0`、`render_generation=0`。失败注入产生至少3张软件图像并收到 `metalPresentationFailed`，同样正常清理；这是编码前故障注入，不等于物理GPU device-loss测试。
- 全部6项iOS XCTest通过，device Debug产品构建与macOS完整行为回归通过。证据 `out/apple_host/evidence/ios-I1-metal/`（`tests-final.xcresult`、运行日志、frame.png）；无本轮CUA点击或真机验收。
- I1仍需平台能力/请求完善及完整产品资源行为审计；I4还需同刻像素对照、旋转/窄窗、60/高刷新与长时/内存/真实GPU故障恢复。现有帧钟暂用60上限，高刷新与持久FPS偏好尚未接入，不勾完整IOS-06/10。历史GPU错误计数与drain/新会话恢复路径也需专项故障审计。


## 10. 移动游戏库与 Files 复制导入（2026-10-13）

- 共享GameLibrary保持旧JSON字段与macOS默认目录，新增可选独立managedGamesRoot/运行时集合；iOS索引在Application Support、托管游戏在Documents/Games，以UUID相对目录定位。原sourcePath只作来源/重复识别，不用于托管游戏重启定位。iOS仅接受KiriKiri；不开放无书签的外部引用。
- 新增MobileLibraryState、UIDocumentPicker（目录/ZIP）、NSFileCoordinator与成对security scope；后台复制、≤4Hz进度、取消协调/复制/解压，发布阶段明确拒绝过晚取消。源、stage与原子索引发布分离；失败回收本次目录，移除只删除记录，保留游戏与存档。
- 复制器用选定根目录描述符/openat/O_NOFOLLOW拒绝链接逃逸，拒绝特殊文件，限制10万项及实际字节；ZIP通过调用方拥有的fd解压，保留路径/链接/大小/编码/CRC等防护。空间预检保留32MiB余量；ZIP预算考虑解压后再次复制的双份占用。/var与/private/var别名误拒绝已实测修复。
- iOS自动封面相对路径与索引在同次发布中保存，列表和详情异步生成缩略图；无法解码时显示占位图。不读取未授权external记录/外部封面，不可用游戏禁止启动。手动封面/清除/搜索仍待后续。
- 宽布局原生侧栏，紧凑布局主页/游戏库tab；列表→详情→游戏，支持重命名/保留文件移除。设置目的地尚未接入，未用空设置页凑三tab；统计、完整设置/主题/手动封面继续I2。
- iOS26 XCTest共11项通过：目录/ZIP、重复与存档保留、搬迁后相对路径、索引重开、封面索引、KiriKiri-only、取消/发布边界、预算、链接拒绝/失败回滚，及之前协议/Metal回归。device Debug产品构建、macOS完整行为回归与独立GameArchiveTests/GameLibraryTests通过；独立归档工具的过时Swift依赖清单已修正。
- 证据 `out/apple_host/evidence/ios-I2-library-final5.xcresult`，UI隔离预览/截图在 `out/apple_host/evidence/ios-I2-library/`。Debug `--ios-library-preview`在临时目录复制仓库Demo并显示列表，不写真实库/协议接受记录；Release不提供该入口。
- 本轮没有CUA工具，未声称完成Files系统选择/真实外部provider、iCloud材料化与离线、实际磁盘不足、用户触屏取消的端到端验收。测试用App/测试bundle与临时目录的URL验证协调链路，不能替代真机Files。I2/I2b/IOS-03/04完整验收仍未完成；I6补入磁盘/文件元数据所用API的隐私manifest审计。

## 11. 移动封面编辑与库搜索（2026-10-13）

- 游戏库加入原生搜索；详情页提供 Files 图片选择、清除、在线 VNDB 封面搜索。首次打开详情/搜索面板不发送标题；用户点击查询才复用共享 VNDB API，候选显示标题与受限缩略图。在线下载失败、损坏图片、取消/离开详情后的迟到结果均保留原封面。
- 新增 MobileCoverEditor，按游戏 UUID + request generation 绑定异步结果；编辑期间禁用并行导入、重命名/移除与启动。离开详情使 editor 失效；取消释放 UI 锁并取消任务，文件协调亦支持取消。网络 provider/图片 loader 可注入，不修改 engine_api/provider ABI。
- 手动图片使用成对 security scope、NSFileCoordinator、O_NOFOLLOW 与 regular-file 检查；文件/网络编码字节最多16MiB，输入最多4000万像素且单边不超过16384，ImageIO按2048上限解码并重编码PNG。网络仅HTTPS，下载按实际字节限额；候选预览失败只显示占位。
- 校验后的图片复制到 Application Support/Covers，UUID新文件与索引事务分离；保存失败或迟到结果移除本次文件，不覆盖原文件。共享索引增加可解析的 library:// 相对路径，setCover默认macOS行为不变；iOS路径迁移后仍可重定位。清除写入 coverSuppressed，重启扫描不自动恢复；此前已发布的缓存图片暂不垃圾回收。
- iOS26共13项XCTest通过（含之前11项协议/导入/Metal）：手动复制后删除外部源、索引重开与Support迁移、损坏/超限图片、清除持久化、路径逃逸拒绝、索引写失败无孤儿新文件；在线只传标题、取消后旧结果隔离、成功替换与后续失败保留、详情失效拒绝重发。线上服务与图片由fixture注入，不声称真实VNDB服务可用性验收。
- 最新结果 `out/apple_host/evidence/ios-I2-covers-final2.xcresult`；device Debug产品构建、macOS完整行为与GameArchiveTests/GameLibraryTests回归通过。本轮无CUA工具，系统Files图片选择、候选点击、VoiceOver/最大Dynamic Type与真实外部provider待端到端核验；iOS18/真机/G4保持未验收。
- I2下一步：完整设置草稿、四主题、第三个设置目的地、移动默认original/off与比例/横屏偏好；封面/搜索实现已落地但不据此勾满I2。

## 12. 移动设置事务、第三目的地与四主题（2026-10-13）

- 新增 MobilePreferences/Store/State，settings.json使用移动envelope v1包裹全部HostSettings v9字段；不更改macOS schema。旧共享flat文件读入后保留输出/算法/增强/FPS等偏好，下一次成功保存转为envelope。新移动安装默认original/off、comfortable。损坏/未来版本不可写，失败保留源文件；草稿保存、丢弃与快捷语言修改的独立重基均有测试。
- iPhone三个tab「主页/游戏库/设置」，宽iPad三个侧栏目的地；离开脏设置页先提供保存/丢弃/继续，写盘失败留在设置。游戏全屏cover屏蔽壳导航，启动使用已提交HostSettings快照，未提交草稿不进入引擎。
- 设置页接入五语言/跟随系统、四主题、compact/comfortable/standard间距密度、Metal/software和插件范围/Mock/错误日志选项。UIKit版本的界面比例调整列表最低行高与库行间距，不缩放系统字体或触控坐标；保持Dynamic Type与至少44pt。对Godot按viewport整体缩放的方式做原生适配，不强行缩小辅助字体。
- 保存语言/主题/密度立即生效；renderer与三项插件选项经已有setOption在下次open前应用，默认Metal、请求software真实走软件引擎。FPS选项尚未应用，输出/采样/增强目前只显示保存值及有效original/off原因，保留偏好不伪装已启用；虚拟控制、诊断、翻译与横屏仍待迁移。错误日志选项只验证传入引擎，移动平台异常对话行为需后续请求应答验收。
- 四主题复用Godot/桌面palette，用accentText给原生选项/tab可读文字着色，用controlAccent给白字主按钮。初版全局controlAccent导致暗色主题文字偏暗，截图审阅后已改正；全局foregroundStyle亦移除，恢复原生禁用状态。列表/详情/设置使用主题背景，系统控件保留原生布局。
- iOS26共16项XCTest通过：含此前13项、设置草稿/丢弃/保存/重开/flat迁移/写失败/损坏保留、已保存software真实Demo出帧与mock选项，以及四主题文字/白字按钮至少4.5对比度。device Debug与macOS完整行为回归通过。`out/apple_host/evidence/ios-I2-settings-final.xcresult`为行为证据。
- 两模拟器四主题共8张设置预览在 `out/apple_host/evidence/ios-I2-settings/`。Debug-only --ios-settings-preview与--ios-preview-theme使用临时库/设置根，不写真实偏好或法律接受；Release无此入口。截图来自simctl视觉核查，不是CUA点选或真机证明。CUA、最大Dynamic Type/VoiceOver、实际离页确认点击、iOS18/真机仍待验收。
- 下一步按I2/I3继续横屏scene策略与恢复、完整移动输入/控制板和平台请求；再接帧钟/输出预算、诊断与StoreKit。当前不能勾满I2/IOS-08或M4。

## 13. 横屏偏好与 scene 方向恢复（2026-10-13）

- 移动设置envelope升级v2，加入landscapeLocked，默认false（沿用Godot）；v1缺失字段迁移false，flat共享字段与原输出/增强/密度保留。未来版本/损坏文件禁止覆盖。保存后的完整MobilePreferences快照进入游戏，未保存横屏草稿不生效。
- MobileOrientationPolicy由一个scene/游戏token拥有，通过UIApplicationDelegate窗口方向掩码与UIWindowScene.requestGeometryUpdate请求横屏；递归通知实际root/呈现/子controller更新支持范围。不使用UIDevice KVC强迫物理方向，不给iPad设置全屏排他。
- 系统拒绝时释放landscape限制、显示五语言说明与重试，继续现有aspect-fit布局，保持偏好。每次重试另有request ID，旧请求/旧会话错误不能改变新策略；scene断开或stop释放拥有者。回到壳先恢复允许范围，并请求进入游戏前方向；即使游戏尚未完成旋转也发恢复请求，覆盖排队中的旧几何请求。系统拒绝恢复时仍保留已恢复的壳策略，不阻止返回。
- 游戏controller增加sceneReady/didClose宿主回调，开始前要求拥有scene；监听该scene断开直接stop，stop幂等且在停钟、取消输入、lease/drain/销毁后释放方向；回调独立拥有方向lease，不依赖已析构的SwiftUI模型。engine_api/provider ABI不变。
- iOS26 iPhone17 Pro实际请求成功转横屏，stop后interfaceOrientation从landscape回到进入前portrait；iPad Pro M4当前窗口模式拒绝程序方向请求（UIKit说明当前窗口模式不允许），提示且Metal继续出帧，stop策略恢复。两模拟器各21项XCTest通过，覆盖v1/v2/未来版本、重试/旧错误/旧owner隔离、解锁/断开通知注入与真实引擎lease/drain清理。证据 `ios-I3-orientation-phone-verified.xcresult`、`ios-I3-orientation-pad-final2.xcresult`及对应日志。
- 新增独立AetherHostIOSUI scheme和UITest target：正式SwiftUI fullScreen游戏→点返回→点确认→设置页，断言横屏/竖屏geometry与横屏偏好保持，实际UI测试通过。iOS26的confirmationDialog产生同action嵌套Button节点，使用命名action firstMatch消除重复查询；不是放宽结果断言。证据 `out/apple_host/evidence/ios-I3-orientation-ui-verified.xcresult`，截图附件导出到 `ios-I3-orientation-ui-verified-attachments/`。
- 横屏UI检查也修正旧「返回主页」文案为「返回 / 退出并返回」，因为游戏应回到来源页（库详情、主页，或隔离预览设置页）。Debug预览现在连Demo/法律读取/设置/库都在同一临时沙盒根；--ios-preview-landscape仅在Debug设置预览内应用，不写真实用户数据。
- device Debug构建与macOS完整回归通过，最低18.0不变。本轮没有CUA工具；XCUITest是实际UI自动点击证据，仍不替代真机触摸/iPad窄窗多任务/外接屏、所有旋转中捕获取消、音频与iOS18运行。不能勾满I3/IOS-04/05/07/G4。
- 下一步：移动虚拟控制板、UIKit IME/平台FIFO请求与输入共享矩形；之后完善调度、诊断、输出预算与StoreKit。

## 14. 移动控制板与触摸序列（2026-10-13）

- 顶栏直接显示/隐藏控制板，画布入口与游戏菜单共享同一会话状态；入口关闭不阻止顶栏打开。菜单/返回弹层取消捕获、释放按键并暂停；菜单键动作先解除自己的modal原因，不覆盖其他暂停原因。顶栏ViewThatFits在窄窗/大字体重排，初期不自动隐藏入口；沉浸工具栏恢复仍待实现。
- 回车/空格/Esc/四方向/PgUp/PgDn与保持Ctrl使用共享KeyInputState，普通键down/up、重复Ctrl去重。隐藏、模式切换、失焦/音频暂停、resize/旋转、source变化、取消、stop均release。派发期间的重入reset也必须只有一个up；Ctrl通过input epoch防止重入后重新锁定视觉状态或modifiers。
- 原生控制板自适应网格、最小44pt；字体跟随Dynamic Type，不缩字。键帽透明度不改变命中区，模式/鼠标手柄/指针不随透明度变暗。移动设置明确复用字段：virtualControls=启动时显示，virtualControlMenuEnabled=画布入口，另有模式与按键透明度；移动新安装默认touch，已有mouse偏好保留。
- AetherMobileCanvas提供统一contentRect，触摸坐标、虚拟鼠标delta和可见白色指针共用aspect-fit比例与逻辑尺寸，黑边拒绝、拖出夹边，取消回传最后有效点。模式mouse只由手柄移动与独立左键按钮发事件；离开/resize后的旧手柄移动由epoch拒绝。
- 共享C++ TouchSequence用于画布与原生手柄：主指抬起后剩余手指不能接管，等全部离开才开始新序列。直接UIView内容触摸在ScrollView中会被延迟/纵向滚动抢走；UI测试暴露该问题后改用公开UIGestureRecognizer子类，先捕获主指并让面板滚动等待，移动不使用多指质心，保留系统边缘手势。
- iPhone26/iPad26各23项XCTest通过，覆盖真实引擎的键对/修饰符、Ctrl重复/暂停/模式/resize/隐藏/stop释放、重入派发、虚拟鼠标同一比例与旧拖动失效；另有MobileTouchSequenceTests.cpp覆盖第二指、all-lift、取消和黑边拒绝。输入observer证明真实EngineSession派发，不据此声称所有游戏解释VK行为相同。
- 原生UI测试共3项通过：入口点击不产生游戏点击、Ctrl隐藏后释放/重新打开未选中、鼠标横纵拖动与左键成对；最大辅助字号实际UIKit category核对、面板滚动后完整可见按钮操作与44pt检查；原横屏返回回归。发现的纵向拖动抢占已修复。证据 `out/apple_host/evidence/ios-I3-controls-ui-final2.xcresult`、`ios-I3-controls-{phone,pad}-final2.xcresult`，截图附件在 `ios-I3-controls-ui-final2-attachments/`。
- 游戏像素图像有五语言VoiceOver标签/语义限制提示，指针手柄提供四方向可访问动作；完整VoiceOver操作尚未实际验收。Debug-only AX输入计数/字号类别辅助测试，Release不提供这些诊断值。device Debug、macOS完整行为与五语言回归通过，engine_api/provider ABI未改。
- 无CUA工具；本轮证据是XCUITest实际点按/拖动、XCTest、截图核查，不代替真机多指/Pencil/鼠标、iOS18或所有游戏输入验收。I3继续：UIKit IME/手动文本、平台FIFO请求、沉浸工具栏恢复与完整无障碍，不能勾满IOS-04/05/G4。
