extends SceneTree

class SessionHost extends "res://scripts/main.gd":
    var now := 1000
    var saved: Array[Dictionary] = [
        {"path": "/games/one", "playDurationSeconds": 0},
        {"path": "/games/two", "playDurationSeconds": 90},
    ]
    var writes := 0
    var fail_save := false
    func _init() -> void:
        add_child(ui_motion)
    func _ready() -> void:
        pass
    func _process(_delta: float) -> void:
        pass
    func _is_touch_platform() -> bool:
        return true
    func _play_session_now_msec() -> int:
        return now
    func _load_game_list() -> Array[Dictionary]:
        return saved.duplicate(true)
    func _save_game_list(games: Array[Dictionary]) -> Error:
        if fail_save:
            return ERR_CANT_CREATE
        saved = games.duplicate(true)
        writes += 1
        return OK

var failures := 0

func _expect(ok: bool, message: String) -> void:
    if not ok:
        failures += 1
        push_error(message)

func _initialize() -> void:
    var host := SessionHost.new()
    host.known_games = host.saved.duplicate(true)
    host.selected_game = host.saved[0].duplicate()
    _expect(host._format_play_duration(30) == "30s" and host._format_play_duration(0) == "0m",
        "Recorded sub-minute sessions do not look unplayed")
    host._begin_active_game_session("/games/one")
    var launch_writes := host.writes
    host.now = 30500
    host._process_active_game_session(29.5)
    _expect(host.writes == launch_writes, "Frames do not constantly rewrite the game index")
    host.now = 31500
    host._process_active_game_session(1.0)
    _expect(host.saved[0].playDurationSeconds == 30, "A running game checkpoints before normal exit")
    _expect(host.selected_game.playDurationSeconds == 30 and host.known_games[0].playDurationSeconds == 30,
        "Detail and library snapshots receive persisted statistics")
    host.now = 62000
    host._notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
    host._notification(Node.NOTIFICATION_APPLICATION_PAUSED)
    _expect(host.saved[0].playDurationSeconds == 61, "Android pause saves the remaining span once, even with no runtime player")
    _expect(host.saved[1].playDurationSeconds == 90, "Only the active game receives play time")
    var resumed := SessionHost.new()
    resumed.saved = host.saved.duplicate(true)
    _expect(resumed._load_game_list()[0].playDurationSeconds == 61, "An OS-reclaimed process leaves checkpointed time available to the next launch")
    resumed.free()
    host.now = 362000
    host._process_active_game_session(300.0)
    host._notification(Node.NOTIFICATION_APPLICATION_RESUMED)
    host._notification(Node.NOTIFICATION_APPLICATION_FOCUS_IN)
    host.now = 372500
    host._finalize_active_game_session()
    _expect(host.saved[0].playDurationSeconds == 71, "Background time is excluded and resume notifications do not restart the clock")
    host._finalize_active_game_session()
    _expect(host.saved[0].playDurationSeconds == 71, "Repeated exit does not count a span twice")
    host._begin_active_game_session("/games/one")
    host.now += 31000
    host.fail_save = true
    host._checkpoint_active_game_session()
    _expect(host.saved[0].playDurationSeconds == 71, "A failed checkpoint keeps the durable total unchanged")
    host.fail_save = false
    host.now += 1000
    host._checkpoint_active_game_session()
    _expect(host.saved[0].playDurationSeconds == 103, "Retry retains the unsaved span without double-counting earlier checkpoints")
    host.now += 1000
    host._pause_active_game_session()
    host.now += 60000
    host._finalize_active_game_session()
    _expect(host.saved[0].playDurationSeconds == 104, "Exiting while suspended never includes background time")
    host.free()
    print("PLAY_DURATION_TEST failures=", failures)
    quit(1 if failures else 0)
