# iOS Krkr 日志定位（2026-10-03）

## 已确认并修正

### 手动启动文件被自动检测覆盖

`apps/godot_app/scripts/main.gd` 的 `_backfill_game_metadata()` 每次刷新都会将检测得到的 `launchFile` 写回游戏配置。已有的 `GameLaunchEntry.backfill()` 可以保留手动选择，也保留显式空字符串（自动启动），但该调用点没有使用它。

修正：启动文件只在配置字段缺失时补齐；标题候选和检测信号仍正常刷新。

### System.exeName 残留首次游戏路径

`packages/AetherKrkr/core/base/impl/SystemImpl.cpp` 的 `System.exeName` getter 使用函数局部 `static ttstr` 保存 `TVPNormalizeStorageName(ExePath())`。`ExePath()` 返回当前 `TVPNativeProjectDir`，但 static 只初始化一次；退出游戏、重建 System 类、清空自动搜索路径都不会清掉它。

因此在同一进程依次打开 AM、DR、9nine 时，只要首次在 AM 读取该属性，后续仍返回 AM 的入口路径。依赖它拼接资源路径的游戏脚本会访问旧目录。这是明确的跨游戏状态错误，与手动/自动启动方式没有必然关系；是否出现启动弹窗不能作为根因证据。

修正：每次读取时按当前项目计算。补充原生回归测试，依次设置三个项目并重建 System 类，检查其 exeName 属性。

这处修复能够消除该路径残留来源；现有日志不足以证明所有语音崩溃都由它引起。

## 内存问题：已定位触发点，未确认最终终止原因

`krkr2(1).log` 最后一条记录（23:04:25.374）：

```
Heap ceiling triggered: 630MB > 545MB ceiling, forcing full cleanup
```

对应 `core/environ/win32/SystemControl.cpp` 的 `RunMemoryGovernor()`。此分支清理 XP3 segment cache，发送 `TVP_COMPACT_LEVEL_MAX`，再调用 Apple malloc pressure relief。MAX compact 会进入 TJS 脚本缓存清理和完整 GC，此外还会通知其他清理回调。文件名中的 win32 不表示该逻辑仅在 Windows 上运行。

日志没有后续内存统计、异常堆栈或 iOS Jetsam 信息，因此不能从这一条记录断言是泄漏、系统内存终止或 GC/清理回调崩溃。630 MB 是 malloc 堆统计，不能当作进程全部物理内存占用。

值得继续测量的缓存策略：

- governor 将 graphic cache 上限固定为 256 MiB，即使进入低内存配置也不会降低。
- PSBMedia 默认上限 256 MiB，初始化及 setCacheBudget 将下限强制设为 256 MiB；更小的 psb_cache_mb 不会生效。
- 这些是缓存上限，不是日志已证明的实际占用；渲染纹理、正在使用的对象、XP3 解压和私有插件还会额外占内存。

本次没有未经测量就调整这些阈值，也没有将内存问题标记为已修复。

## 日志证据与验证限制

- AM 日志记录了退出时音频暂停、deInitPsbFile、Host render state reset，随后打开 DR 的路径。这说明退出清理至少执行到了这些步骤，并不证明所有状态都已清空。
- AM 的 console 日志重复出现 AM 的 savedata 路径和空自动搜索表；它本身没有明确的语音资源异常或 native crash backtrace。
- 9nine、Monkeys 日志以启动成功结束，缺少用户报告的语音播放崩溃堆栈。不能将缺失插件的启动警告当作语音崩溃根因。
- game_launch_entry_test 和 game_metadata_test 在 Godot 4.6.3 headless 下通过；两个仓库的 diff --check 通过。
- 原生回归测试未运行：当前 Linux 环境没有 CMake，也没有 iOS SDK 或这些游戏资源。AetherInternal 子模块仍受 GitHub 403 限制，无法审计日志中的私有 PackinOne/E-mote 实现。

## 真机回归步骤

1. 为游戏手动选择 EXE/XP3，刷新游戏库、重启应用，确认选择保留；显式选择自动启动也应保留。
2. 完整重启应用，启动 AM、关闭游戏、启动 DR、关闭游戏、启动 9nine 并读档播放语音；确认 System.exeName、exePath、dataPath 均属于当前游戏，重复三轮。
3. 对 Monkeys → 9nine 及 9nine → AM 做同样检查，分别测试有弹窗和无弹窗启动；同时覆盖自动入口和手动入口。
4. 对内存日志对应游戏重复同一操作并采集进程 footprint、各缓存实际大小以及 Xcode 崩溃报告或 JetsamEvent，以区分系统终止和清理路径崩溃。内存问题应单独验收。

原生修改位于 AetherKrkr 子模块工作区；父仓库设置了 ignore=dirty，普通父仓库 git status 不会列出这些文件。发布时需要提交子模块改动并更新父仓库引用。
