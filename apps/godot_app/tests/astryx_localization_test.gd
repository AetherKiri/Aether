extends SceneTree
const Suite := preload("res://tests/astryx_shell_test.gd")
const Library := preload("res://scripts/video_library.gd")
var failures := 0
var host: Suite.TestHost
var controller: Suite.TestController

func _initialize() -> void:
    call_deferred("_run")

func _expect(ok: bool, message: String) -> void:
    if not ok:
        failures += 1
        push_error(message)

func _texts(node: Node) -> PackedStringArray:
    var result := PackedStringArray()
    if node is Control and not node.is_visible_in_tree():
        return result
    if node is Label or node is Button:
        result.append(node.text)
    if node is LineEdit:
        result.append(node.placeholder_text)
    if node is Control and not node.accessibility_name.is_empty():
        result.append(node.accessibility_name)
    for child in node.get_children():
        result.append_array(_texts(child))
    return result

func _contains(node: Node, expected: Array) -> void:
    var values := _texts(node)
    for value in expected:
        _expect(value in values, "Traditional UI includes: " + value)

func _frames() -> void:
    for _frame in range(5):
        await process_frame

func _run() -> void:
    root.size = Vector2i(1194, 834)
    var directory := DirAccess.create_temp("aether-localization-", false)
    var base := directory.get_current_dir()
    host = Suite.TestHost.new()
    host.active_language = host.LANG_ZH_HANT
    host.language_mode = host.LANG_ZH_HANT
    host.known_games = [{"id": "one", "name": "简体游戏名", "path": base, "type": "Directory"}]
    host.selected_game = host.known_games[0]
    host.video_library = Library.new(base.path_join("videos.json"), base.path_join("hidden.json"))
    host.flash_library = Library.new(base.path_join("flash.json"), base.path_join("flash-hidden.json"), ["swf"])
    controller = Suite.TestController.new()
    controller.name = "ShellInterface"
    controller.preference_path = base.path_join("interface.cfg")
    host.add_child(controller)
    root.add_child(host)
    await _frames()
    for viewport in [Vector2i(1194, 834), Vector2i(393, 852)]:
        root.size = viewport
        await _frames()
        controller.view.navigate("library")
        await _frames()
        _contains(controller.view, ["遊戲庫", "全部遊戲", "最近遊玩", "搜尋遊戲…", "简体游戏名"])
        controller.view.navigate("videos")
        await _frames()
        _contains(controller.view, ["影片", "搜尋檔案…"])
        controller.view.navigate("settings")
        await _frames()
        _contains(controller.view, ["設定", "介面", "畫面", "相容性", "診斷", "關於"])
        for section in ["interface", "render", "compatibility", "diagnostics", "about"]:
            controller.view.section = section
            controller.view.settings_detail = true
            controller.view.rebuild()
            await _frames()
            var expected := {
                "interface": ["外觀", "主題", "介面語言", "介面版本", "遊戲控制"],
                "render": ["畫面與渲染", "幀率"],
                "compatibility": ["執行階段相容性"],
                "diagnostics": ["診斷與日誌"],
                "about": ["目前安裝的應用程式版本"],
            }
            _contains(controller.view, expected[section])
        host._show_detail(host.known_games[0])
        await _frames()
        _contains(controller.view, ["開始遊戲", "遊戲資訊", "遊戲名稱", "遊玩紀錄", "存檔", "匯出存檔", "简体游戏名"])
        controller.view._show_cover_sources()
        await _frames()
        _contains(host.modal_layer, ["選擇封面來源", "本機搜尋", "VNDB 搜尋"])
        host.find_child("AstryxCoverSource_vndb", true, false).pressed.emit()
        await _frames()
        _contains(host.modal_layer, ["VNDB 搜尋", "輸入遊戲名稱", "搜尋"])
        host._dismiss_modal()
    # Existing host dictionaries must not fall back to Simplified Chinese.
    for key in host.UI_TEXT[host.LANG_ZH_HANS]:
        _expect(host.UI_TEXT[host.LANG_ZH_HANT].has(key), "Traditional host table covers " + key)
    host.queue_free()
    await _frames()
    print("ASTRYX_LOCALIZATION_TEST failures=", failures)
    quit(1 if failures else 0)
