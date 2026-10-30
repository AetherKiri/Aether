# 手柄支持：接手和验证

## 工作范围与隔离

- 工作树：`D:\imopara1\AetherKiri-ui-test-gamepad`
- 分支：`codex/ui-test-gamepad-support`
- 派生点：当前 UI 测试分支 `codex/ui-only-test-mode` 的 `b02304e6`。
- 没有更新或修改另一位开发者使用的 `AetherKiri-latest-internal-ui` 工作树。
- 旧手柄提交 `e5e00cf5` 仅作为迁移来源，已适配当前 UI/runtime 与 UI-only 生命周期。
- 已 cherry-pick UI 测试分支新增的 `c04aebb7`，本分支对应提交为 `9515e8ab`（液态玻璃虚拟控制）。

**不是新做一套 UI。** 首页、库、设置、弹窗、加载页、游戏容器和空游戏测试场景仍然是
`apps/godot_app/scripts/main.gd` 构建的现有 UI。共享 UI 控件的修改会同时影响普通场景和测试场景；
只有引擎输入的发送端不同。UI-only 不创建 native player，普通游戏把手柄映射成现有键盘/指针事件。

## 立即运行

在本工作树中双击 `run_ui_only.bat`，不要使用另一工作树的启动脚本。
此分支继承的启动器设置 `AETHERKIRI_UI_TEST_MODE=1`，**启动后自动进入加载页和空游戏场景**。
按 B 返回原首页后，可以在“设置 → 高级 → UI-only launch”再次进入。

第一次运行新工作树，先导入 Godot 资源：

```powershell
Set-Location D:\imopara1\AetherKiri-ui-test-gamepad
$godot = 'D:\imopara1\godot\Godot_v4.7.2-stable_win64_console.exe'
& $godot --headless --editor --path apps/godot_app --quit
```

普通模式：清除当前 PowerShell 中的测试模式环境变量，再启动同一个项目。
实际游戏需要相应 native 扩展与运行时；UI-only 和下述模拟输入测试不需要。

```powershell
Remove-Item Env:AETHERKIRI_UI_TEST_MODE -ErrorAction SilentlyContinue
& $godot --path apps/godot_app
```

## 默认操作（Godot 标准位置映射）

以下 A/B/X/Y 按 Godot 的标准手柄按钮位置命名，不保证各品牌印字相同。
由 Godot 负责设备识别与映射，不直接依赖 Windows XInput。

| 操作 | 游戏外 / UI 弹层 | 普通游戏内 |
| --- | --- | --- |
| 左摇杆 | 自由移动圆点鼠标，靠近控件吸附 | 方向键（支持连发） |
| 十字键 | 空间焦点导航；滑块左右调值；分段控件左右选择 | 方向键（支持连发） |
| 右摇杆 | 同样可自由移动圆点鼠标 | 移动游戏指针，约束在实际画面内 |
| A（下方按钮） | 点击圆点吸附的按钮/开关/下拉项；滑块按位置调值；焦点模式下激活当前控件 | 指针点击，发送成对按下/松开 |
| B（右侧按钮） | 先关下拉/弹窗/虚拟控制；详情或设置返回 | Escape；UI-only 场景则返回首页 |
| X（左侧按钮） | 不发送游戏事件 | 按住 Control（常见快进键），松开即释放 |
| Y（上方按钮） | 不发送游戏事件 | Space |
| LB / RB | 当前列表、设置、弹窗内容向上/下翻页 | 滚轮向上/下 |
| Start / Menu | 打开设置；视频中显示控制条 | 打开/收起现有虚拟控制面板 |
| Back / Select | 返回 | 主 runtime 弹出退出确认；独立播放器走自己的关闭路径 |

UI-only 空场景：摇杆移动圆点、十字键导航、A 操作控件、Start 打开虚拟控制，B 先关弹层再返回，
“重新加载”仍经过共享加载页。不向空场景发送 native 引擎事件。

设置中新增“手柄”分组：启用、死区、灵敏度、指针速度。沿用原有设置草稿、应用/丢弃与持久化路径。

圆点在控件可见区域外 72px 内吸附，持续推动摇杆超过 112px 后脱离；底层自由位置持续移动，
不会被吸附锁住。弹窗、下拉和虚拟控制只使用当前前台层的目标；隐藏、禁用、已删除及被滚动容器
完全裁剪的控件不会吸附。空白处 A 不会误触上一个焦点。滑块与分段选择保留横向定位。
原生 PopupMenu 保留 Godot 窗口内的方向导航。原生游戏帧不提供按钮几何数据，保持自由鼠标。
圆点点击和触摸轨迹共用 `ui/aether_pointer_ripple.gd`，复用 `c04aebb7` 的 56px 白色扩散圆圈及 0.45s 动画；
减少动态效果开启时手柄不播放圆圈。圆点热点与发出的点击位置一致。

### 独立播放器

- Flash：复用 `_send()` / `_map()`，支持指针、按键、滚轮及其虚拟控制面板。
- Ren’Py：复用 `native.send_input(Dictionary)`，归一化坐标；Start 在游戏与工具栏焦点间切换。
- Tyrano：复用 `AetherTyranoHost.key()`；A 为 Enter，肩键为 PageUp/PageDown，方向键等保持现有语义。
  **没有新增任意 DOM 指针点击功能**，右摇杆位置不等于 Tyrano 页面可点击坐标。
- 视频页：显示现有控制条并聚焦，A 激活按钮，B 返回视频库。

## 修改入口

- `apps/godot_app/scripts/gamepad_controller.gd`：设备热插拔、死区、摇杆曲线、方向连发、按钮边沿。
- `apps/godot_app/scripts/gamepad_cursor.gd`：全局圆点指针；`ui/aether_pointer_ripple.gd`：共享点击圆圈。
- `apps/godot_app/scripts/gamepad_player_input.gd`：独立播放器的现有输入协议适配。
- `apps/godot_app/scripts/main.gd`：搜索 `_on_gamepad_`、`_gamepad_focus_root`、`_configure_gamepad`。
- `apps/godot_app/scripts/game_virtual_controls.gd`：既有虚拟控件的可聚焦状态与收起接口。

输入优先交给当前下拉、弹窗、调试抽屉、虚拟控制等前台层，不穿透到后台游戏。
加载遮罩阻止确认/方向/指针输入；UI-only 加载过程中 B 可取消。
断连、切换设备、失焦、禁用手柄、退出游戏时清理按住的快进键，避免粘键。
原有鼠标、触摸、键盘输入不替换。

## 无引擎自动测试

从本工作树运行，测试应打印各自 `PASS`，不能仅依赖 Godot 退出码（脚本断言失败不一定返回非零）：

```powershell
$godot = 'D:\imopara1\godot\Godot_v4.7.2-stable_win64_console.exe'
$tests = @('gamepad_controller_test', 'gamepad_ui_test', 'gamepad_ui_only_test',
           'gamepad_player_input_test', 'game_virtual_controls_test',
           'virtual_control_settings_test', 'runtime_form_dialog_test')
foreach ($test in $tests) {
    & $godot --headless --path apps/godot_app --script "res://tests/$test.gd" --quit-after 3600
}
```

- controller：死区/限值、方向连发、边沿去重、断连/失焦/禁用释放。
- UI：焦点隔离、禁用项、开关、AetherSelect 与原生 OptionButton、滑块、指针坐标、按键/滚轮；圆点吸附/脱离、空白点击、删除目标、裁剪目标、弹窗隔离。
- UI-only：真实 UI 构建 + 注入 Joypad 按钮，覆盖入口→加载→控件→虚拟控制→重载→返回；不读写用户库。
- player adapter：假 native 传输端验证 Flash/Ren’Py/Tyrano 的协议与坐标，不启动真实引擎。

窗口化自动测试（结束后自行退出）：

```powershell
& $godot --path apps/godot_app --rendering-method gl_compatibility --resolution 1280x720 --script res://tests/gamepad_ui_only_test.gd
```

**验证边界：** 自动注入事件/假传输测试不等于实体手柄或真实游戏实测。
合入前仍需连接目标设备验证热插拔、摇杆漂移、实际按住快进、切后台、各平台游戏输入。
缺失 GDExtension 二进制时 Godot 启动会报扩展加载错误；这些测试可继续运行，
但这不表示扩展“成功加载”，也不能用来声明真实引擎已验证。

## 提交注意

本次圆点指针交付：七项 headless 测试与窗口化 `gamepad_ui_only_test` 均打印 PASS。
窗口截图保存于 `C:\Users\wolfp\AppData\Local\Temp\opencode\gamepad-dot-delivery`，
包含 `gamepad-dot-snapped.png` 与 `gamepad-dot-click.png`。
`virtual_control_settings_test` 退出时仍报告少量 ObjectDB/resource 清理警告；未将该警告视为通过依据。

只提交手柄源码、对应 `.gd.uid`、测试及本文档；不提交 `.godot` 缓存、自动重写的 `.import` 或子模块变更。
不要为了同步 UI 重置另一位开发者的分支、工作树或其未提交改动；后续由双方选择合适时机整合。
