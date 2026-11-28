extends SceneTree

const Telemetry = preload("res://scripts/telemetry.gd")
const Flash = preload("res://scripts/flash_player_view.gd")
const Tyrano = preload("res://scripts/tyrano_player_view.gd")
const Renpy = preload("res://scripts/renpy_player_view.gd")

class App extends "res://scripts/main.gd":
    func _ready() -> void:
        pass

    func _process(_delta: float) -> void:
        pass

class LocalCollector extends "res://scripts/telemetry.gd":
    var test_path := ""

    func _install_id_path() -> String:
        return test_path

var failures := 0

func _initialize() -> void:
    _run.call_deferred()

func _run() -> void:
    var app := App.new()
    root.add_child(app)
    var collector := LocalCollector.new()
    collector.test_path = "user://telemetry-playback-test-" + Telemetry._new_uuid()
    collector.configure("", "1.2.2-alpha.3", "8501", "debug")
    app.telemetry = collector
    app.add_child(collector)

    app._telemetry_begin_engine("kirikiri", {"title": "Private while disabled"})
    app._telemetry_engine_result(false, "startup_failed")
    _expect(collector._events.is_empty() and app.telemetry_game_name.is_empty(), "Disabled playback leaves no telemetry context")
    app.telemetry_enabled = collector.set_consent(true)
    _expect(app.telemetry_enabled, "The test can persist an opt-in ID")
    app._telemetry_begin_engine("kirikiri", {"title": "星空の物語", "path": "/home/user/private/game"})
    _expect(collector._events.size() == 1, "Beginning a native launch does not report success yet")
    app._telemetry_engine_result(true)
    app._telemetry_engine_result(true)
    _expect(collector._events.size() == 2 and collector._events[1].success, "The native ready transition reports success once")
    app._telemetry_engine_error("tick_failed")
    _expect(collector._events[2].game_name == "星空の物語" and collector._events[2].error_code == "tick_failed", "Runtime errors keep the player-visible title and a stable code")
    app._telemetry_end_engine()

    for entry in [[Tyrano, "tyranoscript"], [Renpy, "renpy"], [Flash, "flash"]]:
        var view: Control = entry[0].new()
        app._connect_view_telemetry(view, entry[1], {"name": "Test Game", "path": "/private/path"})
        view.launch_requested.emit()
        view.playback_failed.emit("view_load_failed")
        var first: Dictionary = collector._events.back()
        _expect(first.engine == entry[1] and first.game_name == "Test Game" and not first.success, "Each view reports a failed launch")
        view.launch_requested.emit()
        view.game_ready.emit()
        var second: Dictionary = collector._events.back()
        _expect(second.engine == entry[1] and second.success, "Each view counts a restart as a new attempt")
        view.closed.emit()
        _expect(app.telemetry_engine.is_empty() and collector._engine.is_empty(), "Closing a view ends its usage")
        view.free()

    app._notification(Node.NOTIFICATION_APPLICATION_PAUSED)
    app._notification(Node.NOTIFICATION_APPLICATION_FOCUS_IN)
    _expect(not collector._foreground, "Focus does not resume collection while the app is still paused")
    app._notification(Node.NOTIFICATION_APPLICATION_RESUMED)
    _expect(collector._foreground, "Resume restores collection after both focus and pause checks")
    _expect(not JSON.stringify(collector._events).contains("/private/"), "Local paths are never part of the event payload")
    collector.set_consent(false)
    app.free()
    print("TELEMETRY_PLAYBACK_TEST failures=", failures)
    quit(1 if failures else 0)

func _expect(ok: bool, message: String) -> void:
    if not ok:
        failures += 1
        push_error(message)
