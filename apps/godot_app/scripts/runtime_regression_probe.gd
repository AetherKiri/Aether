extends RefCounted

const ProbeConfig = preload("res://scripts/probe_config.gd")

# Explicit opt-in device regression runner. It never saves screenshots and
# writes engine saves only beneath a separate, seeded regression directory.
var app: Node
var config: Dictionary
var snapshots: Dictionary = {}
var report: Array[Dictionary] = []
var last_state: Dictionary = {}
var started_ms := Time.get_ticks_msec()

func _init(host: Node = null, settings: Dictionary = {}) -> void:
    app = host
    config = settings

static func writable_root(settings: Dictionary) -> String:
    var requested := String(settings.get("writable_root", ""))
    var base := ProjectSettings.globalize_path("user://regressions").simplify_path()
    var resolved := ProjectSettings.globalize_path(requested).simplify_path()
    if not resolved.begins_with(base + "/") or resolved == base:
        return ""
    return resolved

static func field(value: Variant, path: String) -> Variant:
    var current: Variant = value
    for part in path.split("."):
        if current is Dictionary and current.has(part):
            current = current[part]
        elif current is Array and part.is_valid_int() and int(part) >= 0 and int(part) < current.size():
            current = current[int(part)]
        else:
            return null
    return current

static func subset(value: Variant, wanted: Variant) -> bool:
    if wanted is Dictionary:
        if not value is Dictionary:
            return false
        for key in wanted:
            if not value.has(key) or not subset(value[key], wanted[key]):
                return false
        return true
    return value == wanted

static func conditions_match(state: Dictionary, conditions: Array, saved: Dictionary = {}) -> bool:
    for raw in conditions:
        if not raw is Dictionary or not raw.has("field"):
            return false
        var actual: Variant = field(state, String(raw["field"]))
        if actual == null or not (raw.has("equals") or raw.has("not_equals")
                or raw.has("same_as") or raw.has("changed_from")
                or raw.has("contains") or raw.has("not_contains")):
            return false
        if raw.has("equals") and actual != raw["equals"]:
            return false
        if raw.has("not_equals") and actual == raw["not_equals"]:
            return false
        if raw.has("same_as"):
            var reference: Variant = field(saved, String(raw["same_as"]))
            if actual == null or reference == null or actual != reference:
                return false
        if raw.has("changed_from"):
            var reference: Variant = field(saved, String(raw["changed_from"]))
            if actual == null or reference == null or actual == reference:
                return false
        for comparison in ["contains", "not_contains"]:
            if not raw.has(comparison):
                continue
            if not actual is Array:
                return false
            var found := false
            for candidate in actual:
                if subset(candidate, raw[comparison]):
                    found = true
                    break
            if found == (comparison == "not_contains"):
                return false
    return true

func record(event: Dictionary) -> void:
    event["elapsed_ms"] = Time.get_ticks_msec() - started_ms
    report.append(event)
    var line := "runtime_regression " + JSON.stringify(event)
    print(line)
    app._write_probe_marker(line)
    var path := writable_root(config).path_join("regression-result.json")
    var output := FileAccess.open(path, FileAccess.WRITE)
    if output != null:
        output.store_string(JSON.stringify({"events": report, "snapshots": snapshots}, "\t"))
    else:
        push_error("Cannot persist regression result: %s" % path)

func host_state() -> Dictionary:
    return {
        "library_visible": app.shell_root.visible and app.home_view.visible
            and not app.game_view.visible and not app.viewport.visible,
        "route": app.shell_route,
        "library_mode": app.home_library_mode,
        "game_running": app.game_running,
        "frame_texture_cleared": app.viewport.texture == null,
        "engine_initialized": app.player != null and app.player.is_initialized(),
        "player_instance_id": app.player.get_instance_id() if app.player != null else 0,
        "startup_state": app.cached_startup_state,
        "runtime": app.active_runtime_kind,
        "render_errors": app.render_errors,
        "configured_launch_file": String(app.selected_game.get("launchFile", "")),
    }

func state() -> Dictionary:
    var shell := host_state()
    var inactive: bool = shell.library_visible or not shell.engine_initialized
    var parsed: Dictionary = {}
    if not inactive:
        var diagnostics := JSON.new()
        if diagnostics.parse(String(app.player.get_plugin_debug_info())) == OK and diagnostics.data is Dictionary:
            parsed = diagnostics.data
    if not inactive:
        var frame_size: Vector2i = app.player.get_frame_source_size()
        parsed["probe_frame"] = {"width": frame_size.x, "height": frame_size.y}
    parsed["host"] = shell
    last_state = parsed
    return parsed

func launch_from_library(game_path: String) -> bool:
    # Exercise the production pre-open options and handle-reuse decision.
    # Calling _ensure_player_initialized() here would hide reopen regressions.
    app._prepare_cli_probe_view(config)
    app.selected_backend = ProbeConfig.backend(config)
    var game: Dictionary = app._game_info_from_path(game_path)
    var overrides: Variant = config.get("library_game", {})
    if overrides is Dictionary:
        game.merge(overrides, true)
    game["path"] = game_path
    app.selected_game = game
    app._start_selected_game_after_entitlements()
    if not app.game_running:
        return false
    return await app._probe_wait_startup(config)

func check_frame(action: Dictionary, label: String) -> bool:
    if not app.game_running or not app.player.is_initialized() or app.viewport.texture == null:
        record({"event": "failed", "label": label, "reason": "game frame unavailable", "state": state()})
        return false
    # Read the actual Godot output after presentation as well as the provider
    # pixels. Only numerical evidence and hashes are saved, never images.
    await RenderingServer.frame_post_draw
    var frame: Dictionary = app.player.read_frame_rgba()
    var image: Image = app.get_viewport().get_texture().get_image()
    if image == null or image.is_empty():
        record({"event": "failed", "label": label, "reason": "presentation unavailable"})
        return false
    var source_stats: Dictionary = app._frame_stats(frame)
    var presented_stats: Dictionary = app._image_stats(image)
    var minimum := float(action.get("min_visible_ratio", 0.1))
    var source_ratio := float(source_stats.visible) / maxf(1.0, float(source_stats.sampled))
    var presented_ratio := float(presented_stats.visible) / maxf(1.0, float(presented_stats.sampled))
    var hash := HashingContext.new()
    hash.start(HashingContext.HASH_SHA256)
    hash.update(frame.get("rgba", PackedByteArray()))
    var evidence := {
        "event": "frame", "label": label,
        "width": frame.get("width", 0), "height": frame.get("height", 0),
        "serial": frame.get("frame_serial", 0),
        "source": source_stats, "presented": presented_stats,
        "source_visible_ratio": source_ratio, "presented_visible_ratio": presented_ratio,
        "source_sha256": hash.finish().hex_encode(),
        "renderer": app.player.get_renderer_info(), "state": state(),
    }
    record(evidence)
    if int(frame.get("width", 0)) <= 0 or int(frame.get("height", 0)) <= 0 or source_ratio < minimum or presented_ratio < minimum:
        record({"event": "failed", "label": label, "reason": "empty or black frame"})
        return false
    return true

func advance(frames: int) -> bool:
    for i in range(maxi(1, frames)):
        # Once a natural exit has returned to the shell, the engine handle is
        # destroyed. Keep observing the UI without ticking that closed handle.
        if bool(host_state().library_visible) or app.game_running:
            await app.get_tree().process_frame
        elif not await app._probe_advance(1):
            return false
    return true

func wait_for(conditions: Array, timeout_ms: int, stable_frames: int = 1, alternatives: Array = []) -> bool:
    var deadline := Time.get_ticks_msec() + maxi(1, timeout_ms)
    var matching_frames := 0
    while Time.get_ticks_msec() < deadline:
        var current := state()
        var matched := conditions_match(current, conditions, snapshots)
        if not alternatives.is_empty():
            matched = false
            for candidate in alternatives:
                if candidate is Array and conditions_match(current, candidate, snapshots):
                    matched = true
                    break
        if matched:
            matching_frames += 1
            if matching_frames >= maxi(1, stable_frames):
                return true
        else:
            matching_frames = 0
        if not await advance(1):
            return false
    return false

func point(action: Dictionary) -> Vector2:
    if action.has("button"):
        var buttons: Variant = state().get("buttons", [])
        for button in buttons:
            if subset(button, action["button"]) and int(button.get("v", 0)) == 1 and int(button.get("e", 0)) == 1 and int(button.get("draw_visible", 1)) == 1:
                var pos := Vector2(float(button.get("draw_x", button.get("x", 0))) + float(button.get("w", 0)) * 0.5,
                    float(button.get("draw_y", button.get("y", 0))) + float(button.get("h", 0)) * 0.5)
                var frame: Vector2i = app.player.get_frame_source_size()
                if pos.x >= 0 and pos.y >= 0 and pos.x < frame.x and pos.y < frame.y:
                    return pos
        return Vector2(-1, -1)
    if action.has("point_from"):
        var rect: Variant = field(snapshots, String(action["point_from"]))
        if rect is Dictionary and float(rect.get("w", 0)) > 0 and float(rect.get("h", 0)) > 0:
            return Vector2(float(rect["x"]) + float(rect["w"]) * 0.5, float(rect["y"]) + float(rect["h"]) * 0.5)
        return Vector2(-1, -1)
    return Vector2(float(action.get("x", -1)), float(action.get("y", -1)))

func tap(action: Dictionary, label: String) -> bool:
    if int(action.get("button_index", 0)) != 0 or int(action.get("touch_index", 0)) < 0:
        record({"event": "failed", "label": label, "reason": "invalid touch button or index"})
        return false
    var source := point(action)
    var frame: Vector2i = app.player.get_frame_source_size()
    if source.x < 0 or source.y < 0 or source.x >= frame.x or source.y >= frame.y or app.viewport.texture == null:
        record({"event": "failed", "label": label, "reason": "missing touch target", "state": state()})
        return false
    # Enter the same handler as real ScreenTouch events, including the
    # viewport-to-game transform, gesture classification and delayed release.
    # The probe owns ticking, so normal game_running GUI dispatch stays off.
    var position: Vector2 = app._map_surface_point_to_viewport(source)
    var mapped: Vector2 = app._map_viewport_point(position)
    if mapped.distance_to(source) > 1.0:
        record({"event": "failed", "label": label, "reason": "touch coordinate round trip", "source": [source.x, source.y], "mapped": [mapped.x, mapped.y]})
        return false
    var forwarded := int(app.input_total_forwarded)
    var failed := int(app.input_total_send_failed)
    var pointer_id := int(action.get("touch_index", 0))
    var event := InputEventScreenTouch.new()
    event.index = pointer_id
    event.position = position
    event.pressed = true
    if not app._handle_game_pointer_event(event):
        record({"event": "failed", "label": label, "reason": "touch press not handled"})
        return false
    if int(action.get("hold_frames", 1)) > 0 and not await advance(int(action.get("hold_frames", 1))):
        return false
    event = InputEventScreenTouch.new()
    event.index = pointer_id
    event.position = position
    event.pressed = false
    if not app._handle_game_pointer_event(event):
        record({"event": "failed", "label": label, "reason": "touch release not handled"})
        return false
    var deadline := Time.get_ticks_msec() + 1000
    while app.pending_touch_index == pointer_id or app.delayed_touch_releases.has(pointer_id):
        if Time.get_ticks_msec() >= deadline:
            record({"event": "failed", "label": label, "reason": "touch release timeout"})
            return false
        if not await advance(1):
            return false
    var sent := int(app.input_total_forwarded) - forwarded
    if sent < 3 or int(app.input_total_send_failed) != failed:
        record({"event": "failed", "label": label, "reason": "touch not forwarded", "forwarded": sent, "state": state()})
        return false
    record({"event": "input", "label": label, "kind": "touch", "source": [source.x, source.y], "viewport": [position.x, position.y], "forwarded": sent})
    return true

func two_finger_tap(action: Dictionary, label: String) -> bool:
    var source := point(action)
    var frame: Vector2i = app.player.get_frame_source_size()
    if source.x < 0 or source.y < 0 or source.x >= frame.x or source.y >= frame.y or app.viewport.texture == null:
        record({"event": "failed", "label": label, "reason": "missing gesture target"})
        return false
    var position: Vector2 = app._map_surface_point_to_viewport(source)
    var mapped: Vector2 = app._map_viewport_point(position)
    if mapped.distance_to(source) > 1.0:
        record({"event": "failed", "label": label, "reason": "gesture coordinate round trip"})
        return false
    var forwarded := int(app.input_total_forwarded)
    var failed := int(app.input_total_send_failed)
    # Both contacts arrive before a frame can flush the pending primary tap.
    # The real gesture handler chooses the secondary button and cancels the
    # contacts; injecting a native right-click here would bypass that code.
    for pressed in [true, false]:
        for index in [0, 1]:
            var event := InputEventScreenTouch.new()
            event.index = index
            event.position = position
            event.pressed = pressed
            if not app._handle_game_pointer_event(event):
                record({"event": "failed", "label": label, "reason": "gesture not handled"})
                return false
    var sent := int(app.input_total_forwarded) - forwarded
    if sent < 3 or int(app.input_total_send_failed) != failed:
        record({"event": "failed", "label": label, "reason": "gesture not forwarded", "forwarded": sent})
        return false
    record({"event": "input", "label": label, "kind": "two_finger_tap", "source": [source.x, source.y], "forwarded": sent})
    return true

func prepare_virtual_mouse() -> bool:
    app._sync_game_virtual_controls()
    var controls = app.game_virtual_controls
    if controls == null or not controls.visible or not app._can_forward_virtual_controls_input():
        return false
    if not controls.is_panel_open():
        if not controls.is_menu_open():
            controls.menu_button.emit_signal("pressed")
        controls.virtual_controls_button.emit_signal("pressed")
    if controls.is_touch_mode():
        controls.input_mode_button.emit_signal("pressed")
    return controls.is_panel_open() and controls.input_mode_button.text == "Mode: Mouse"

func virtual_mouse_click(action: Dictionary, label: String) -> bool:
    if int(action.get("button_index", 0)) != 0 or not prepare_virtual_mouse():
        record({"event": "failed", "label": label, "reason": "virtual mouse unavailable"})
        return false
    var controls = app.game_virtual_controls
    var source := point(action)
    var frame: Vector2i = app.player.get_frame_source_size()
    var target: Vector2 = app._map_surface_point_to_viewport(source)
    if source.x < 0 or source.y < 0 or source.x >= frame.x or source.y >= frame.y \
            or app._map_viewport_point(target).distance_to(source) > 1.0:
        record({"event": "failed", "label": label, "reason": "invalid virtual mouse target"})
        return false
    # Use the real Mouse-mode trackpad recognizer. A finger's position is
    # separate from the cursor hotspot; no native click is injected here.
    var safe: Rect2 = controls._safe_rect
    var touchpad := Vector2(-1, -1)
    for y in [0.28, 0.42, 0.58]:
        for x in [0.55, 0.45, 0.65]:
            var candidate := safe.position + safe.size * Vector2(x, y)
            if not controls._visible_interactive_control_at(candidate) and not controls._dpad_contains_point(candidate):
                touchpad = candidate
                break
        if touchpad.x >= 0:
            break
    if touchpad.x < 0:
        record({"event": "failed", "label": label, "reason": "no virtual trackpad area"})
        return false
    var edges: Array[Dictionary] = []
    var observe := func(pressed: bool, button: int, modifiers: int, position: Vector2):
        edges.append({"pressed": pressed, "button": button, "modifiers": modifiers,
            "position": [position.x, position.y], "frame": Engine.get_process_frames()})
    controls.pointer_button_requested.connect(observe)
    var forwarded := int(app.input_total_forwarded)
    var failed := int(app.input_total_send_failed)
    var drags := 0
    while controls.cursor_screen_position().distance_to(target) > 1.0 and drags < 32:
        var delta: Vector2 = target - controls.cursor_screen_position()
        var room: Vector2 = Vector2(minf(touchpad.x - safe.position.x, safe.end.x - touchpad.x),
            minf(touchpad.y - safe.position.y, safe.end.y - touchpad.y)) * 0.8
        delta = delta.limit_length(minf(room.x, room.y))
        var down := InputEventScreenTouch.new()
        down.index = 40
        down.position = touchpad
        down.pressed = true
        var handled: bool = controls.routes_pointer(down)
        # Crossing the drag threshold also prevents a tiny final movement
        # from being mistaken for another trackpad tap.
        for movement in [delta.normalized() * maxf(delta.length(), 12.0), delta]:
            var drag := InputEventScreenDrag.new()
            drag.index = down.index
            drag.position = touchpad + movement
            handled = controls.routes_pointer(drag) and handled
        var up := InputEventScreenTouch.new()
        up.index = down.index
        up.position = touchpad + delta
        up.pressed = false
        handled = controls.routes_pointer(up) and handled
        drags += 1
        if not handled or not edges.is_empty() or not await advance(1):
            break
    var positioned: bool = controls.cursor_screen_position().distance_to(target) <= 1.0
    var handled := false
    if positioned and edges.is_empty():
        var down := InputEventScreenTouch.new()
        down.index = 41
        down.position = touchpad
        down.pressed = true
        handled = controls.routes_pointer(down)
        if int(action.get("hold_frames", 3)) > 0:
            handled = await advance(int(action.get("hold_frames", 3))) and handled
        var up := InputEventScreenTouch.new()
        up.index = down.index
        up.position = touchpad
        up.pressed = false
        handled = controls.routes_pointer(up) and handled
    controls.pointer_button_requested.disconnect(observe)
    var sent := int(app.input_total_forwarded) - forwarded
    var valid_edges: bool = edges.size() == 2 and edges[0].pressed and not edges[1].pressed \
        and edges[0].button == 0 and edges[1].button == 0 and edges[0].frame == edges[1].frame
    if not positioned or not handled or not valid_edges or sent < 2 or int(app.input_total_send_failed) != failed:
        record({"event": "failed", "label": label, "reason": "virtual mouse gesture not forwarded",
            "positioned": positioned, "edges": edges, "forwarded": sent, "state": state()})
        return false
    record({"event": "input", "label": label, "kind": "virtual_mouse", "mode": controls.input_mode_button.text,
        "source": [source.x, source.y], "viewport": [target.x, target.y],
        "touchpad": [touchpad.x, touchpad.y], "drags": drags, "edges": edges, "forwarded": sent})
    return true

func run(game_path: String) -> int:
    var pointer_input := String(config.get("pointer_input", "mouse"))
    if pointer_input not in ["mouse", "touch", "virtual_mouse"]:
        record({"event": "failed", "reason": "invalid pointer_input"})
        return 1
    var launch_mode := String(config.get("launch_mode", "probe"))
    if launch_mode not in ["probe", "library"]:
        record({"event": "failed", "reason": "invalid launch_mode"})
        return 1
    record({"event": "start", "name": config.get("name", "regression"), "screenshots": false, "pointer_input": pointer_input, "launch_mode": launch_mode})
    var opened := false
    if launch_mode == "library":
        opened = await launch_from_library(game_path)
    else:
        opened = app._probe_open_game(config, game_path, "AETHERKIRI_PROBE_BACKEND") and await app._probe_wait_startup(config)
    if not opened:
        record({"event": "failed", "reason": "startup", "error": app.player.get_last_error()})
        return 1
    for raw in config.get("steps", []):
        if not raw is Dictionary:
            record({"event": "failed", "reason": "invalid step"})
            return 1
        var action: Dictionary = raw
        var label := String(action.get("label", action.get("type", "wait")))
        var kind := String(action.get("type", "wait"))
        if action.has("when") and not conditions_match(state(), action["when"], snapshots):
            record({"event": "step_skipped", "label": label})
            continue
        record({"event": "step_start", "label": label})
        if kind == "reopen":
            if not bool(host_state().library_visible):
                record({"event": "failed", "label": label, "reason": "library is not visible", "state": state()})
                return 1
            if launch_mode == "library":
                opened = await launch_from_library(game_path)
            else:
                app._prepare_cli_probe_view(config)
                opened = app._ensure_player_initialized() and app._probe_open_game(config, game_path, "AETHERKIRI_PROBE_BACKEND") and await app._probe_wait_startup(config)
            if not opened:
                record({"event": "failed", "label": label, "reason": "reopen", "error": app.player.get_last_error()})
                return 1
        elif kind == "exit_to_library":
            app._exit_game_for_go_back()
        elif kind == "frame":
            if not await check_frame(action, label):
                return 1
        elif kind == "wait":
            if not await wait_for(action.get("until", []), int(action.get("timeout_ms", 15000)), int(action.get("stable_frames", 3)), action.get("until_any", [])):
                record({"event": "failed", "label": label, "reason": "timeout", "state": last_state, "error": app.player.get_last_error()})
                return 2
        elif kind == "snapshot":
            snapshots[label] = state().duplicate(true)
            record({"event": "snapshot", "label": label, "state": snapshots[label]})
        elif kind == "virtual_mouse_click" or (kind == "click" and pointer_input == "virtual_mouse"):
            if not await virtual_mouse_click(action, label):
                return 1
        elif kind == "virtual_key":
            if not prepare_virtual_mouse():
                record({"event": "failed", "label": label, "reason": "virtual controls unavailable"})
                return 1
            var control: Variant = app.game_virtual_controls.get(String(action.get("control", "escape_button")))
            if not control is Button or not control.visible:
                record({"event": "failed", "label": label, "reason": "missing virtual key"})
                return 1
            control.emit_signal("button_down")
            if not await advance(int(action.get("hold_frames", 3))):
                control.emit_signal("button_up")
                return 1
            control.emit_signal("button_up")
            record({"event": "input", "label": label, "kind": "virtual_key", "control": control.name})
        elif kind == "tap" or (kind == "click" and pointer_input == "touch"):
            if not await tap(action, label):
                return 1
        elif kind == "two_finger_tap":
            if not two_finger_tap(action, label):
                return 1
        elif kind == "move":
            var pos := point(action)
            app.player.send_pointer_event(app.POINTER_MOVE, 0, pos.x, pos.y, 0.0, 0.0, 0)
        elif kind == "click":
            var pos := point(action)
            if pos.x < 0 or pos.y < 0:
                record({"event": "failed", "label": label, "reason": "missing click target", "state": state()})
                return 1
            app.player.send_pointer_event(app.POINTER_MOVE, 0, pos.x, pos.y, 0.0, 0.0, 0)
            if not await advance(1):
                return 1
            var result: int = app.player.send_pointer_event(app.POINTER_DOWN, 0, pos.x, pos.y, 0.0, 0.0, int(action.get("button_index", 0)))
            if result != app.ENGINE_RESULT_OK:
                record({"event": "failed", "label": label, "reason": "input rejected", "error": app.player.get_last_error()})
                return 1
            if int(action.get("hold_frames", 3)) > 0 and not await advance(int(action.get("hold_frames", 3))):
                return 1
            app.player.send_pointer_event(app.POINTER_UP, 0, pos.x, pos.y, 0.0, 0.0, int(action.get("button_index", 0)))
        elif kind == "key":
            var key := int(action.get("key_code", 13))
            app.player.send_key_event(true, key, 0, 0)
            if not await advance(int(action.get("hold_frames", 2))):
                return 1
            app.player.send_key_event(false, key, 0, 0)
        elif kind == "assert":
            if not conditions_match(state(), action.get("conditions", []), snapshots):
                record({"event": "failed", "label": label, "reason": "assertion", "state": last_state})
                return 1
        else:
            record({"event": "failed", "label": label, "reason": "unknown action"})
            return 1
        if not await advance(int(action.get("after_frames", 2))):
            var failure_error: String = app.player.get_last_error()
            record({"event": "failed", "label": label, "reason": "runtime error", "error": failure_error, "state": state()})
            return 1
        record({"event": "step_pass", "label": label})
    record({"event": "passed", "name": config.get("name", "regression")})
    return 0
