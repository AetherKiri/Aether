# SystemNNN 源码交付说明

本次交付是 **可审查、可复现的源码集成**，不是已获许可公开发布的完整二进制产品。发布许可仍有未解决事项，PR 保持 Draft。

## 仓库与分支

- Aether：[PR #532](https://github.com/AetherKiri/Aether/pull/532)，分支 `feat/systemnnn-emberfall`。
- Emberfall：[AetherKiri fork](https://github.com/AetherKiri/SystemNNN-Emberfall)，分支 `feat/aether-integration`，gitlink 固定 `f52d77fe05104726d35389266f0ba6f5be3a3f59`。
- 移动目标验证分支：`feat/systemnnn-mobile-verify`，已通过的最终运行时代码提交为 `de4a1f29`。桌面与 Linux 图形验证的运行时代码与之相同；后续审计/测试辅助文件不会冒充新的运行时执行结果。

```sh
git clone --branch feat/systemnnn-emberfall https://github.com/AetherKiri/Aether.git
cd Aether
git submodule update --init --recursive packages/SystemNNN-Emberfall
```

以上只初始化本引擎的源码；完整产品还需要所选其他运行时和依赖。请按实际构建选项初始化它们，不要把仅初始化此子模块当作完整产品依赖已就绪。

## 接入范围

注册独立 `systemnnn` provider，以不区分大小写的 `spt/sys.spt` 识别目录；接入 Godot 的 CPU RGBA 图形通路、FreeType/CP932 文本、原生逐字/Auto/Skip 时间规则、OpenAL 音频、FFmpeg 影片、启动序列、PC 存读档和全局进度。标题/Omake 可进入十种已配置小游戏，具有规则与输入，并按各类型协议接入完成事件和奖励持久化；Paint 按设计没有胜利条件或奖励。各平台构建开关、字体、输入坐标、私有存储和静态归档接线均已实现；Web 默认关闭本运行时。

## 已完成的验证

| 范围 | 实际证据与边界 |
|---|---|
| Linux / macOS adapter | `81c09626` 托管 CI 均通过 12/12 合约；Linux 另通过生成影片集成，Godot shell 通过五套测试。 |
| Windows adapter | 最终冷启动 vcpkg 构建仍在运行；以[桌面验证记录](systemnnn_desktop_validation.md)的最终结果为准，尚不标为通过。 |
| Android ARM64 | 实际 NDK r28b / Clang 19 编译、whole-archive 完整链接、安装和 ELF 检查通过；AArch64、16 KiB LOAD 对齐、指定三库直接依赖及注册符号通过。不是 APK 或真机运行。 |
| iPhoneOS ARM64 | AppleClang 17 编译、完整链接、安装和 Mach-O 检查通过；iOS 平台、arm64、最低系统 16.0 及注册符号有日志证据。GNU iconv 头文件/库不匹配已在真正运行时构建中修复并验证。不是 IPA 或真机运行。 |
| 真实 Linux GDExtension | 完整 `KRKR2;SYSTEMNNN` 产品目标在 Godot 4.7.2/X11/Mesa 加载并通过独立编写的图形场景：可见文字、纹理读回、键盘分支、槽 13 存读档与继续位置恢复；正常环境的 `ldd -r` 无缺库/未定义符号。依赖宿主发行版库，不是干净机器发行认证。 |
| 内存/未定义行为检查 | 全十个 native 合约在新建 ASan/UBSan/泄漏检测构建中通过；只说明已运行场景未报告诊断。 |
| Python 辅助合约 | 14 个新 fixture/检查器测试与 6 个 selector/初始化测试通过。广泛 Python 回归中的七个既有诊断测试依赖宿主 ADB 发现；不修改生产代码的 resolver mock 可使这七项通过，不宣称原始全套全绿。 |

复现入口：[运行时说明](systemnnn_runtime.md)、[汇总验证](systemnnn_validation.md)、[桌面](systemnnn_desktop_validation.md)、[移动目标](systemnnn_mobile_validation.md)、[真实产品图形构建](systemnnn_production_validation.md)、[图形 fixture](../tests/systemnnn_godot/README.md)、[sanitizer](systemnnn_sanitizer_validation.md)。

## 不隐瞒的剩余边界

1. **暂缓二进制发布**：Emberfall 明示 GPL-2.0-only，Aether 明示 GPL-3.0-or-later，产品 FFmpeg Bink2 启用 GPL/version3。尚无足够授权证据消除该发布门槛；需有资格的发布决策与必要授权。已阻止集成分支的产品 CI 上传，移动 CI 只保留诊断文本。[许可审计](systemnnn_redistribution.md)。
2. 没有商业游戏完整路线、移动设备生命周期、真实扬声器输出、干净机器全平台产品包认证。图形验证是 Godot 纹理读回，不冒充屏幕扫描输出或完整 UI 动画等价。
3. 本次确实读完八个可用公开其他引擎 provider 及其构建边界，并补充了公共宿主图形方法和完整 Emberfall render 实现；**未声称所有引擎、所有 core/platform/第三方源码逐行读完**。[适配阅读台账](systemnnn_adapter_reading.md)、[完整 renderer 阅读补充](systemnnn_render_reading.md)标出 F/P/U。
4. CardSystem 模式 45 在当前 Emberfall core/Android 版本没有可用游戏/完成协议；不编造前端支持，也不与 Monte/Pyramid/Golf 等小游戏混同。[审计](systemnnn_cardsystem_audit.md)。部分 UI 动画、ruby 跨行、backlog 回放等仍有边界。
5. renderer 阅读发现直接 native snapshot 恢复缺少某些 effect 特有状态约束；当前 PC-save bridge 通过 restore_layer/configure 重建 effect 状态，不直接读入 native State；这两个 native-state 绕过点未在该路径建立可达性。另一个上游 Android JNI 使用 native snapshot，未审计其 Java 持久化/信任来源；不宣称已验证的恶意存档漏洞或全局解析安全。CPU 发布回执与实际显示的区别、批量 tick 的调度风险同样记录在 renderer 补充中。

请在发布门槛关闭、Windows 最终结果收集以及所需真实设备/游戏验收完成前，不将 Draft PR 标记为“全平台发行就绪”。
