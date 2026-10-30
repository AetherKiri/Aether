extends SceneTree

class TyranoApp:
    extends "res://scripts/main.gd"
    var marked: Array[String] = []
    var play_seconds := 0
    var messages: Array[String] = []
    func _ready() -> void:
        ui_motion.reduced_motion = true
        add_child(ui_motion)
        _apply_ui_font()
        _build_ui()
    func _process(_delta: float) -> void:
        pass
    func _refresh_games() -> void:
        pass
    func _mark_game_played(path: String) -> Dictionary:
        marked.append(path)
        return {}
    func _add_play_duration(_path: String, seconds: int) -> void:
        play_seconds += seconds
    func _show_message(text: String) -> void:
        messages.append(text)

var app: TyranoApp
var failures := 0
var replies: Array[Dictionary] = []
var ready_events := 0
const WAITING = " && TYRANO.kag.ftag.array_tag[TYRANO.kag.ftag.current_order_index]?.name === 'l' && !TYRANO.kag.stat.is_adding_text && TYRANO.kag.key_mouse.util.canClick()"

func _initialize() -> void:
    call_deferred("_run")

func _expect(value: bool, message: String) -> void:
    if not value:
        failures += 1
        push_error(message)

func _receive(event: Dictionary) -> void:
    if String(event.get("type", "")) == "ready":
        ready_events += 1
    if String(event.get("type", "")) in ["evaluation", "evaluation_error"]:
        replies.append(event)

func _query(expression: String):
    replies.clear()
    app.tyrano_view.native.evaluate_script("JSON.stringify(" + expression + ")")
    for _attempt in range(100):
        if not replies.is_empty():
            var reply: Dictionary = replies.pop_front()
            if reply.type == "evaluation_error":
                push_error("Tyrano evaluation failed: " + String(reply.value) + "\nExpression: " + expression)
                failures += 1
                return null
            return JSON.parse_string(String(reply.value))
        await create_timer(0.02).timeout
    _expect(false, "Tyrano evaluation timed out: " + expression)
    return null

func _wait(expression: String, message: String) -> bool:
    for _attempt in range(100):
        if await _query(expression) == true:
            return true
        await create_timer(0.05).timeout
    _expect(false, message + ": " + str(await _query("({step:TYRANO.kag.stat.f.probe_step,route:TYRANO.kag.stat.f.probe_route,tag:TYRANO.kag.ftag.array_tag[TYRANO.kag.ftag.current_order_index]?.name,adding:TYRANO.kag.stat.is_adding_text,canClick:TYRANO.kag.key_mouse.util.canClick()})")))
    return false

func _ready_game() -> bool:
    for _attempt in range(300):
        if not app._is_tyrano_active():
            break
        if app.tyrano_view.ready_received:
            return true
        await create_timer(0.05).timeout
    _expect(false, "The real TyranoScript engine starts in the app")
    return false

func _click_control(control: Control) -> void:
    var point: Vector2 = app.tyrano_view._content_rect().position + control.get_global_rect().get_center()
    var move := InputEventMouseMotion.new()
    move.position = point
    app.tyrano_view._input(move)
    for pressed in [true, false]:
        var button := InputEventMouseButton.new()
        button.position = point
        button.button_index = MOUSE_BUTTON_LEFT
        button.pressed = pressed
        app.tyrano_view._input(button)
        await process_frame

func _run() -> void:
    root.size = Vector2i(1280, 720)
    root.content_scale_factor = 1.5
    root.gui_embed_subwindows = true
    var path := OS.get_environment("AETHERKIRI_TEST_TYRANO")
    if path.is_empty() or not ClassDB.class_exists("AetherTyranoPlayer"):
        push_error("An Apple Debug build and prepared AETHERKIRI_TEST_TYRANO fixture are required")
        quit(2)
        return
    app = TyranoApp.new()
    root.add_child(app)
    var packed: bool = app.TyranoPlayerView.Metadata.tyrano_entry_file(path).ends_with(".asar")
    app.selected_game = app._game_info_from_path(path)
    _expect(app.selected_game.engine == "tyranoscript", "The library classifies the imported project")
    app._start_selected_game_after_entitlements()
    _expect(app._is_tyrano_active() and not app.shell_root.visible, "The normal game launch route opens the embedded browser")
    if not app._is_tyrano_active():
        quit(1)
        return
    if packed:
        _expect(app.tyrano_view.preparation != null, "Packed games prepare on a worker thread")
        app._handle_go_back_request()
        _expect(not app._is_tyrano_active() and app.marked.is_empty(), "Leaving during ASAR preparation cancels without starting a play session")
        await process_frame
        app._start_selected_game_after_entitlements()
    app.tyrano_view.native.event_received.connect(_receive)
    if not await _ready_game():
        app.tyrano_view.close()
        quit(1)
        return
    _expect(app.marked == [path], "Last-played is updated only after a successful engine start")
    _expect(await _query("TYRANO.kag.config.configSave === 'webstorage'") == true, "Desktop file saves switch to browser storage before game initialization")
    await _wait("TYRANO.kag.stat.f.probe_step === 1" + WAITING, "The first Chinese line is rendered")
    _expect(await _query("document.body.innerText.includes('第一句')") == true, "Chinese text reaches the actual DOM")
    var controls = app.tyrano_view.controls
    _expect(controls.get_script() == load("res://scripts/game_virtual_controls.gd"), "Tyrano instantiates the original KiriKiri controls")
    _expect(await _query("!document.getElementById('aether-tyrano-menu') && !document.getElementById('aether-tyrano-controls')") == true,
        "The browser does not implement its own menu or virtual key buttons")
    await _click_control(controls.menu_button)
    _expect(controls.is_menu_open() and controls.keyboard_button.visible and controls.virtual_controls_button.visible,
        "The original button opens Keyboard and Control Pad")
    await _click_control(controls.virtual_controls_button)
    _expect(controls.is_panel_open(), "The original Control Pad opens")
    _expect(await _query("TYRANO.kag.stat.f.probe_step === 1") == true, "Menu gestures do not leak to the scenario")
    await _click_control(controls.enter_button)
    await _wait("TYRANO.kag.stat.f.probe_step === 2" + WAITING, "Virtual Enter advances the real scenario")
    await _click_control(controls.mouse_left_button)
    await _wait("TYRANO.kag.stat.f.probe_step === 3 && jQuery('.glink_button').length === 2", "Pointer advancement reaches the two Chinese choices")
    await _query("(jQuery('.glink_button').filter(function(){return this.textContent.includes('中文选项 A')}).trigger('click'), true)")
    await _wait("TYRANO.kag.stat.f.probe_route === 'A' && !TYRANO.kag.stat.is_adding_text", "The Chinese choice runs its target label")
    await _query("(window.__aether_saved=false, TYRANO.kag.config.configThumbnail='true', TYRANO.kag.menu.doSave(0, function(){window.__aether_saved=true}), true)")
    await _wait("window.__aether_saved === true", "The engine creates a real save slot")
    var save_path: String = app.TyranoPlayerView.storage_path(path)
    for _attempt in range(100):
        if FileAccess.file_exists(save_path):
            break
        await create_timer(0.02).timeout
    _expect(FileAccess.file_exists(save_path), "The save is persisted under Aether's game-specific storage")
    _expect(await _query("TYRANO.kag.menu.getSaveData().data[0].img_data.startsWith('data:image/')") == true,
        "Saving also renders a real browser thumbnail")
    var previous_ready := ready_events
    app.tyrano_view.native.evaluate_script("window.location.reload()")
    for _attempt in range(300):
        if ready_events > previous_ready:
            break
        await create_timer(0.05).timeout
    _expect(ready_events > previous_ready, "In-game page reload starts a fresh document")
    _expect(await _query("TYRANO.kag.menu.getSaveData().data[0].stat.f.probe_route === 'A'") == true,
        "Page reload retains the latest native-backed save instead of the original seed")
    var before := int(app.tyrano_view.native.get_instance_id())
    app.tyrano_view._restart()
    for _attempt in range(100):
        if int(app.tyrano_view.native.get_instance_id()) != before:
            break
        await create_timer(0.02).timeout
    app.tyrano_view.native.event_received.connect(_receive)
    _expect(int(app.tyrano_view.native.get_instance_id()) != before, "Restart recreates the WebView and JS context")
    if not await _ready_game():
        app.tyrano_view.close()
        quit(1)
        return
    await _query("(TYRANO.kag.menu.loadGame(0), true)")
    await _wait("TYRANO.kag.stat.f.probe_route === 'A' && document.body.innerText.includes('已选择 A')", "Reloading restores saved variables and the Chinese scene")
    _expect(app.marked.size() == 1, "Restart does not create a second play session")
    await _query("(window.__aether_counter=0, window.__aether_timer=setInterval(function(){window.__aether_counter++},20), true)")
    await create_timer(0.15).timeout
    app.tyrano_view.native.set_paused(true)
    var frozen = await _query("window.__aether_counter")
    await create_timer(0.2).timeout
    _expect(await _query("window.__aether_counter") == frozen, "Lifecycle pause stops JS timers")
    app.tyrano_view.native.set_paused(false)
    await create_timer(0.1).timeout
    _expect(int(await _query("window.__aether_counter")) > int(frozen), "Resuming restarts JS timers")
    await _query("(window.__aether_sandbox=null, fetch('data/outside.txt').then(function(r){window.__aether_sandbox=r.status}), true)")
    var outside_status := 404 if packed else 403
    await _wait("window.__aether_sandbox !== null", "The resource request completes")
    var resource_status = await _query("window.__aether_sandbox")
    _expect(resource_status == outside_status, "External resources cannot escape the game folder: expected %d, received %s" % [outside_status, str(resource_status)])
    await _query("(window.__aether_range=null, fetch('data/scenario/first.ks',{headers:{Range:'bytes=0-2'}}).then(async function(r){window.__aether_range=[r.status,(await r.arrayBuffer()).byteLength]}), true)")
    await _wait("window.__aether_range && __aether_range[0] === 206 && __aether_range[1] === 3", "Browser resource requests support exact byte ranges")
    root.size = Vector2i(960, 540)
    app._fit_full_rects()
    await create_timer(0.1).timeout
    _expect(app.tyrano_view.size.is_equal_approx(app.size), "The web player follows the resized shell")
    _expect(await _query("window.innerWidth > 0 && window.innerHeight > 0 && window.innerWidth <= 960 && window.innerHeight <= 540") == true,
        "Resizing keeps the complete native page within the window")
    var visual_hold := OS.get_environment("AETHERKIRI_TYRANO_SMOKE_HOLD").to_float()
    if visual_hold > 0:
        print("TYRANO_PLAYER_VISUAL_READY")
        await create_timer(visual_hold).timeout
    app._handle_go_back_request()
    for _attempt in range(100):
        if not app._is_tyrano_active():
            break
        await create_timer(0.02).timeout
    _expect(not app._is_tyrano_active() and app.shell_root.visible, "System back closes WebKit and restores the game library")
    _expect(app.active_game_started_msec == 0 and app.play_seconds > 0, "Returning finalizes play time")
    _expect(app.messages.is_empty(), "No runtime errors were reported: " + str(app.messages))
    app.queue_free()
    await process_frame
    print("TYRANO_PLAYER_SMOKE_OK" if failures == 0 else "TYRANO_PLAYER_SMOKE_FAILED: %d" % failures)
    quit(0 if failures == 0 else 1)
