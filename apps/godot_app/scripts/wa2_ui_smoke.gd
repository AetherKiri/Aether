extends SceneTree

# Real-library smoke: load main.tscn, import through its picker callback,
# click the real detail Play button, then route native mouse events via Window.
# Run in a regular window, with AETHER_WA2_SILENT=1 and AETHERKIRI_BACKEND=DebugCPU.
# Required: -- --wa2-smoke-game-root <install>; optional --wa2-smoke-output <dir>.
var app
var output_dir := ""
var failure := ""
var checks: Array[Dictionary] = []
var original_library := PackedByteArray()
var had_library := false
var library_changed := false
var final_state: Dictionary = {}

func _initialize() -> void:
    _run.call_deferred()

func _argument(name: String, fallback: String = "") -> String:
    var args := OS.get_cmdline_user_args()
    for index in range(args.size()):
        if args[index] == name and index + 1 < args.size():
            return args[index + 1]
        if args[index].begins_with(name + "="):
            return args[index].substr(name.length() + 1)
    return fallback

func _run() -> void:
    output_dir = _argument("--wa2-smoke-output", ProjectSettings.globalize_path("user://wa2-ui-smoke"))
    DirAccess.make_dir_recursive_absolute(output_dir)
    var game_root := _argument("--wa2-smoke-game-root", OS.get_environment("AETHER_WA2_GAME_ROOT"))
    if not _check("installed-game-root", DirAccess.dir_exists_absolute(game_root), game_root):
        _finish()
        return
    had_library = FileAccess.file_exists("user://aetherkiri_games.json")
    if had_library:
        original_library = FileAccess.get_file_as_bytes("user://aetherkiri_games.json")
    var empty_library := FileAccess.open("user://aetherkiri_games.json", FileAccess.WRITE)
    empty_library.store_string("[]")
    empty_library.close()
    library_changed = true
    app = load("res://scenes/main.tscn").instantiate()
    root.add_child(app)
    # Test-only consent state belongs to this disposable scene instance.
    app.legal_accepted_version = app.LEGAL_AGREEMENT_VERSION
    app.ios_statement_accepted_version = app.IOS_STATEMENT_VERSION
    app.wa2_import_root = ""
    app.wa2_auto_launch = false
    app.debug_overlay_mode = "off"
    app.show_perf_monitor = false
    app._set_perf_visible(false)
    var ready_deadline := Time.get_ticks_msec() + 15000
    while Time.get_ticks_msec() < ready_deadline:
        if app.player != null and app.player.is_initialized() and app.legal_gate_completed:
            break
        await process_frame
    if not _check("official-main-ready", app.player != null and app.player.is_initialized(), "res://scenes/main.tscn"):
        _finish()
        return
    app.announcement_state.dismiss(app.NOTICE_ID, app.NOTICE_VERSION)
    if not _check("actual-import-handler", app._add_game_path(game_root), "_add_game_path"):
        _finish()
        return
    app._show_home()
    await _frames(3)
    var imported: Dictionary = app._find_known_game_by_path(game_root)
    if not _check("library-engine-wa2", String(imported.get("engine", "")) == "wa2" and String(imported.get("launchFile", "")).is_empty(), JSON.stringify(imported)):
        _finish()
        return
    await _capture("01-library")
    var card: Button = null
    for child in app.game_list.get_children():
        if child is Button and String(child.get_meta("game_path", "")) == game_root:
            card = child
            break
    if not _check("real-library-card", card != null, game_root):
        _finish()
        return
    card.pressed.emit()
    await _frames(4)
    var launch := _launch_button(app.detail_view)
    if not _check("real-detail-play-button", launch != null, "pressed -> _start_selected_game"):
        _finish()
        return
    launch.pressed.emit()
    var startup_deadline := Time.get_ticks_msec() + 45000
    while Time.get_ticks_msec() < startup_deadline:
        if app._can_forward_game_input() and app.viewport.texture != null:
            break
        if app.cached_startup_state == app.STARTUP_FAILED:
            break
        await process_frame
    if not _check("normal-game-viewport", app._can_forward_game_input() and app.active_runtime_kind == "wa2" and app.current_player_runtime_kind == "wa2" and app.game_view.visible and not app.shell_root.visible, String(app.player.get_last_error())):
        _finish()
        return
    await _capture("02-title")
    var native_point := Vector2(640, 380)
    var ui_point: Vector2 = app._map_surface_point_to_viewport(native_point)
    var mapped: Vector2 = app._map_viewport_point(ui_point)
    if not _check("scaled-title-click-map", mapped.distance_to(native_point) < 1.0 and app._game_input_surface_size() == Vector2(1280, 720), "ui=%s native=%s viewport=%s" % [ui_point, mapped, app.viewport.get_global_rect()]):
        _finish()
        return
    await _click(ui_point)
    await _frames(8)
    final_state = _runtime_state(JSON.parse_string(String(app.player.get_plugin_debug_info())))
    if not _check("title-new-game-click", String(final_state.get("state", "")) == "story", JSON.stringify(final_state)):
        _finish()
        return
    var before := JSON.stringify([final_state.get("pc"), final_state.get("pageText"), final_state.get("waitLatch"), final_state.get("msgRevealFront")])
    var forwarded_before := int(app.input_total_forwarded)
    var body: Vector2 = app._map_surface_point_to_viewport(Vector2(640, 620))
    await _click(body)
    await _frames(8)
    await _click(body)
    await _frames(8)
    final_state = _runtime_state(JSON.parse_string(String(app.player.get_plugin_debug_info())))
    var after := JSON.stringify([final_state.get("pc"), final_state.get("pageText"), final_state.get("waitLatch"), final_state.get("msgRevealFront")])
    _check("real-viewport-body-clicks", int(app.input_total_forwarded) >= forwarded_before + 4 and before != after, "ui=%s state=%s" % [body, JSON.stringify(final_state)])
    for _index in range(160):
        final_state = _runtime_state(JSON.parse_string(String(app.player.get_plugin_debug_info())))
        if not String(final_state.get("pageText", "")).is_empty():
            break
        await process_frame
    await _capture("03-story")
    if OS.get_cmdline_user_args().has("--wa2-smoke-font-capture"):
        for index in range(500):
            final_state = _runtime_state(JSON.parse_string(String(app.player.get_plugin_debug_info())))
            var page := String(final_state.get("pageText", ""))
            if page.length() >= 12:
                break
            if index % 30 == 0 and (not page.is_empty() or bool(final_state.get("movieWaiting", false))):
                await _click(body)
            await process_frame
    await _frames(60)
    final_state = _runtime_state(JSON.parse_string(String(app.player.get_plugin_debug_info())))
    await _capture("04-font")
    _finish()

func _launch_button(node: Node) -> Button:
    if node is Button:
        for connection in node.get_signal_connection_list("pressed"):
            var callback: Callable = connection.get("callable", Callable())
            if callback.get_method() == "_start_selected_game":
                return node
    for child in node.get_children():
        var found := _launch_button(child)
        if found != null:
            return found
    return null

func _runtime_state(value: Variant, depth: int = 0) -> Dictionary:
    if depth > 8:
        return {}
    if value is String:
        return _runtime_state(JSON.parse_string(value), depth + 1)
    if value is Dictionary:
        if value.has("choicePending") and value.has("scriptGlobals"):
            return value
        for child in value.values():
            if child is Dictionary or child is String:
                var found := _runtime_state(child, depth + 1)
                if not found.is_empty():
                    return found
    return {}

func _click(position: Vector2) -> void:
    var motion := InputEventMouseMotion.new()
    motion.position = position
    motion.global_position = position
    root.push_input(motion, true)
    await process_frame
    for pressed: bool in [true, false]:
        var event := InputEventMouseButton.new()
        event.button_index = MOUSE_BUTTON_LEFT
        event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
        event.pressed = pressed
        event.position = position
        event.global_position = position
        root.push_input(event, true)
        await process_frame

func _frames(count: int) -> void:
    for _index in range(count):
        await process_frame

func _capture(label: String) -> void:
    await RenderingServer.frame_post_draw
    var image := root.get_texture().get_image()
    image.save_png(output_dir.path_join(label + ".png"))

func _check(label: String, passed: bool, detail: String) -> bool:
    checks.append({"name": label, "pass": passed, "detail": detail})
    print("[wa2-ui-smoke] %s %s %s" % [label, "PASS" if passed else "FAIL", detail.left(1600)])
    if not passed:
        failure = label + ": " + detail
    return passed

func _finish() -> void:
    if app != null and app.player != null:
        app.game_running = false
        app.player.destroy_engine()
    if library_changed and had_library:
        var restore := FileAccess.open("user://aetherkiri_games.json", FileAccess.WRITE)
        restore.store_buffer(original_library)
        restore.close()
    elif library_changed:
        DirAccess.remove_absolute(ProjectSettings.globalize_path("user://aetherkiri_games.json"))
    var result := {"pass": failure.is_empty(), "failure": failure, "checks": checks, "runtime": final_state, "scene": "res://scenes/main.tscn", "inputRoute": "Window.push_input -> Main._input -> _handle_game_pointer_event"}
    var file := FileAccess.open(output_dir.path_join("result.json"), FileAccess.WRITE)
    if file != null:
        file.store_string(JSON.stringify(result, "  "))
        file.close()
    print("[wa2-ui-smoke] RESULT " + JSON.stringify(result))
    quit(0 if failure.is_empty() else 1)
