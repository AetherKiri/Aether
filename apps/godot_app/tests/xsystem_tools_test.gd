extends SceneTree

const Tools := preload("res://scripts/xsystem_tools.gd")
const Modifier := preload("res://scripts/ui/xsystem_modifier_view.gd")
const ModList := preload("res://scripts/ui/xsystem_mod_list.gd")
const Controls := preload("res://scripts/game_virtual_controls.gd")
const Tokens := preload("res://scripts/ui/aether_design_tokens.gd")

class Player:
    extends RefCounted
    var options: Array = []
    var snapshot := {}
    var polls := 0
    func set_engine_option(key: String, value: String) -> int:
        options.append([key, value])
        return 0
    func get_plugin_debug_info() -> String:
        polls += 1
        return JSON.stringify(snapshot)
    func manage_xsystem_mods(_path: String, _operation: String, _argument: String) -> String:
        OS.delay_msec(25)
        return '{"ok":true,"mods":[]}'

class Host:
    extends Control
    var active_language := "zh_CN"
    var active_runtime_kind := "xsystem4"
    var game_running := true
    var selected_game := {"path": "/fixture/game"}
    var player = Player.new()
    var ui_tokens = Tokens.new()
    var service
    func _xsystem_tools():
        if service == null:
            service = Tools.new()
            add_child(service)
            service.setup(self)
        return service
    func _dismiss_modal() -> void:
        pass

var failures := 0
func check(value: bool, description: String) -> void:
    if not value:
        failures += 1
        push_error(description)

func _initialize() -> void:
    call_deferred("run")

func run() -> void:
    var host := Host.new()
    root.add_child(host)
    var view := Modifier.new()
    host.add_child(view)
    host.player.snapshot = {"game": "tsumamigui3", "inGame": true, "locks": 2, "gold": 100, "energy": 40,
        "exCharacters": [{"index": 3, "name": "角色 A", "lv": 5, "love": 10}]}
    view.setup(host)
    check(view.profile.get("id") == "tsumamigui3", "native game id selects its profile")
    check(view._locks[2].button_pressed, "native locks populate switches")
    view._toggle_lock(1, true)
    check(host.player.options.back() == ["modifier_lock_mask.tsumamigui3", "3"], "locks retain existing bits and target the current game")
    check(view._character_ids.size() == 2, "individual and all-character targets are offered")
    view._select_character(1)
    var level: LineEdit = view._character_form.find_child("Value_lv", true, false)
    level.text = "21"
    level.text_changed.emit("21")
    view._poll()
    check(level.text == "21", "polling preserves an unsubmitted edit")
    var submit: Button = view._character_form.get_child(view._character_form.get_child_count() - 2)
    submit.pressed.emit()
    var payload = JSON.parse_string(host.player.options.back()[1])
    check(payload is Dictionary and payload.get("exCharEdit", {}).size() == 2 and int(payload.get("exCharEdit", {}).get("lv", -1)) == 21 and int(payload.get("exCharEdit", {}).get("target", -1)) == 3, "only changed fields are sent to the selected character: " + str(payload))
    var count: int = host.player.options.size()
    level.text = "2147483648"
    level.text_changed.emit(level.text)
    submit.pressed.emit()
    check(host.player.options.size() == count, "out-of-range input is rejected")

    var profiles: Array = view.schema.games
    check(profiles.size() == 40, "all supported game profiles are packaged")
    var seen := {}
    for profile in profiles:
        check(not seen.has(profile.id), "profile ids are unique")
        seen[profile.id] = true
        host.active_runtime_kind = profile.engine
        view._runtime = profile.engine
        host.player.snapshot = {"game": profile.id, "inGame": true, "inBattle": true, "locks": 0}
        view._poll()
        check(view.profile.get("id") == profile.id, "profile builds: " + profile.id)
        for panel in view._body.get_children():
            if panel is VBoxContainer:
                for child in panel.get_children():
                    if child is Button and child.text == "编辑数值": child.pressed.emit()
        await process_frame
    host.active_runtime_kind = "xsystem35"
    view._runtime = "xsystem35"
    host.player.snapshot = {"game": "escalayer", "inGame": true, "locks": 0}
    view._poll()
    view._toggle_lock(4, true)
    check(host.player.options.back() == ["modifier_lock_mask", "4"], "System35 uses its own lock option")
    view._send("esc_heal")
    check(host.player.options.back() == ["modifier_action", "esc_heal"], "System35 sends plain commands")
    host.active_runtime_kind = "xsystem4"
    view._runtime = "xsystem4"
    host.player.snapshot = {"game": "sengokurance", "inGame": true, "inBattle": false, "locks": 0,
        "srCharacters": [{"charIdx": 7, "factionIdx": 2, "name": "武将", "troops": 20}]}
    view._poll()
    var action: Dictionary = view._character_action({"charIdx": 7, "factionIdx": 2}, {"resetAction": 1})
    check(action == {"srCharEdit": {"charIdx": 7, "factionIdx": 2, "resetAction": true}}, "Sengoku preserves faction and converts action reset to boolean")
    for gate in view._gates:
        if is_instance_valid(gate.control) and gate.requirement == "inBattle":
            check(gate.control.disabled, "battle actions are unavailable outside battle")
    host.player.snapshot = {"game": "unknown", "inGame": false}
    view._poll()
    check(view.profile.is_empty() and view._locks.is_empty(), "unsupported games have no stale actions")
    var polls: int = host.player.polls
    view.hide()
    view._process(1.0)
    check(host.player.polls == polls and not view._reporting, "hidden modifier stops polling")
    check(host.player.options.back() == ["modifier_state", "0"], "closing releases native state reporting")
    view.queue_free()
    await process_frame

    var controls := Controls.new()
    host.add_child(controls)
    controls.setup(Tokens.new())
    controls.set_enabled(true)
    controls.layout(Vector2(390, 700), Rect2(0, 35, 390, 630))
    controls._toggle_menu()
    check(not controls.modifier_button.visible, "modifier is absent for other engines")
    controls.set_modifier_available(true, "修改器")
    check(controls.modifier_button.visible, "xsystem reveals modifier in the right menu")
    check(Rect2(0, 35, 390, 630).encloses(controls.modifier_button.get_rect()), "three menu buttons fit the safe area")
    controls.set_modifier_available(false)
    check(not controls.modifier_button.visible, "switching runtime removes modifier")
    controls.queue_free()
    host.game_running = false
    var service = host._xsystem_tools()
    var mods := ModList.new()
    host.add_child(mods)
    mods.setup(host, "/fixture/game")
    check(service.busy, "MOD listing uses a worker")
    check(not service.request("/other", "install", "/mod"), "concurrent MOD operations are rejected")
    check(mods.find_child("ChooseModFile", true, false) != null and mods.find_child("ChooseModFolder", true, false) != null, "MOD manager offers file and folder pickers")
    while service.busy:
        await process_frame
    check(service.results["/fixture/game"].ok, "worker result is delivered to the UI")
    host.game_running = true
    check(not service.request("/fixture/game", "install", "/mod"), "MOD changes are blocked during play")
    host.queue_free()
    await process_frame
    print("XSYSTEM_TOOLS_TEST: ", "PASS" if failures == 0 else "FAIL (%d)" % failures)
    quit(0 if failures == 0 else 1)
