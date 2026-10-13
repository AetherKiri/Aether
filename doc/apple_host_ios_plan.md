# iOS 18 / iPadOS 18 迁移实践与验收

- 日期：2026-10-12；状态：I0/I1实施中；要求来源：[iOS spec](apple_host_ios_spec.md)。
- 当前macOS基线 `a52696b6`；正式工程已新增AetherHostIOS/AetherHostIOSTests；目前为协议门、主页与软件Demo的产品起步，完整库/设置与Metal仍在实施。
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
