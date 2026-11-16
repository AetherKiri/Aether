extends SceneTree
## Run the production _ready() path, holding back engine startup and disk scans.
## The first rendered library must already reflect the persisted index.
const Suite = preload("res://tests/astryx_shell_test.gd")

class DemoFixture extends "res://scripts/builtin_demo.gd":
    func reconcile_games(games: Array[Dictionary]) -> Array[Dictionary]:
        return games

class StartupHost extends "res://scripts/main.gd":
    var stored_games: Array[Dictionary] = []
    var metadata_scans := 0

    func _load_game_list() -> Array[Dictionary]:
        return stored_games.duplicate(true)

    func _save_game_list(_games: Array[Dictionary]) -> Error:
        return OK

    func _backfill_game_metadata(_games: Array[Dictionary]) -> bool:
        metadata_scans += 1
        return false

    func _backfill_default_game_covers(_games: Array[Dictionary]) -> bool:
        return false

    func _sync_cover_index(_games: Array[Dictionary]) -> void:
        pass

    func _stage_runtime_fonts() -> void:
        pass

    func _load_shell_settings() -> void:
        active_language = LANG_ZH_HANS
        ui_motion.reduced_motion = true

    func _apply_initial_window_size() -> void:
        pass

    func _apply_global_dpi_scale() -> void:
        pass

    func _restore_scene_test_state() -> void:
        pass

    func _create_runtime_player(_runtime_kind: String = RUNTIME_KIRIKIRI) -> bool:
        # Leave the real deferred library refresh under the test's control.
        return false

    func _process(_delta: float) -> void:
        pass

var failures := 0
var completed_cases := 0
var fixture: DirAccess

func _initialize() -> void:
    call_deferred("_run")

func _expect(value: bool, message: String) -> void:
    if not value:
        failures += 1
        push_error(message)

func _visible_text(node: Node, value: String) -> bool:
    for label in node.find_children("*", "Label", true, false):
        if label.is_visible_in_tree() and label.text == value:
            return true
    return false

func _first_card(host: StartupHost, controller: Suite.TestController) -> Node:
    if controller.enabled:
        return controller.view.find_child("AstryxGameCard", true, false)
    return host.game_list.get_child(0) if host.game_list.get_child_count() > 0 else null

func _check_startup(astryx: bool, viewport_size: Vector2i, cached: bool) -> void:
    root.size = viewport_size
    root.content_scale_size = Vector2i.ZERO
    var host := StartupHost.new()
    host.builtin_demo = DemoFixture.new()
    var games: Array[Dictionary] = [
        {"name": "较早游玩的游戏", "path": fixture.get_current_dir().path_join("older"), "lastPlayed": 10},
        {"name": "最近游玩的游戏", "path": fixture.get_current_dir().path_join("recent"), "lastPlayed": 20},
    ]
    if cached:
        host.stored_games = games
    var controller := Suite.TestController.new()
    controller.name = "ShellInterface"
    controller.preference_path = fixture.get_current_dir().path_join("interface.cfg")
    var preferences := ConfigFile.new()
    preferences.set_value("shell", "interface", "astryx" if astryx else "classic")
    preferences.save(controller.preference_path)
    host.add_child(controller)
    root.add_child(host)
    # Inspect the initial tree immediately and again at the first frame,
    # before the controller's 150 ms poll or any directory/metadata scan.
    var context := "%s %s cached=%s" % ["Astryx" if astryx else "Classic", viewport_size, cached]
    _expect(host.known_games.size() == games.size() if cached else host.known_games.is_empty(), context + ": index restored during _ready")
    _expect(not _visible_text(host, host._t("home.empty_title")), context + ": no false empty state during _ready")
    for _frame in range(4):
        await process_frame
        _expect(not _visible_text(host, host._t("home.empty_title")), context + ": no false empty first frame")
    _expect(host.metadata_scans == 0, context + ": first frame does not require metadata scans")
    controller.set_process(false)
    if cached:
        _expect(host.known_games[0].name == "最近游玩的游戏", context + ": persisted recent order is ready")
        _expect(_visible_text(host, "最近游玩的游戏"), context + ": first frame contains the saved game")
        var first := _first_card(host, controller)
        _expect(first != null, context + ": cached card exists")
        host._refresh_games()
        _expect(_first_card(host, controller) == first, context + ": unchanged reconciliation preserves card identity")
        if astryx:
            controller.sync_state()
            _expect(_first_card(host, controller) == first, context + ": next presenter poll does not replay the entrance")
            host.video_library.entries.append({"path": fixture.get_current_dir().path_join("movie.mp4"), "name": "Movie"})
            controller.sync_state()
            _expect(_first_card(host, controller) == first, context + ": media loading preserves the game cards")
    else:
        _expect(_visible_text(host, host._t("home.loading_title")), context + ": no index shows loading")
        _expect(host.empty_help_label.text.is_empty(), context + ": loading does not suggest importing again")
        if astryx:
            _expect(controller.view.find_child("AstryxEmptyLibraryAction", true, false) == null, context + ": no Astryx empty action while loading")
        host._refresh_games()
        # No process frame or poll between completion and this assertion.
        _expect(_visible_text(host, host._t("home.empty_title")), context + ": confirmed empty state appears immediately")
        _expect(not _visible_text(host, host._t("home.loading_title")), context + ": loading ends for an empty library")
        if astryx:
            _expect(controller.view.find_child("AstryxEmptyLibraryAction", true, false) != null, context + ": confirmed empty library offers import/refresh")
    _expect(not host.game_library_loading, context + ": initial refresh completed")
    host.queue_free()
    await process_frame
    completed_cases += 1

func _check_discovered_games() -> void:
    var host := StartupHost.new()
    host.builtin_demo = DemoFixture.new()
    var controller := Suite.TestController.new()
    controller.name = "ShellInterface"
    controller.preference_path = fixture.get_current_dir().path_join("fresh-interface.cfg")
    host.add_child(controller)
    root.add_child(host)
    await process_frame
    controller.set_process(false)
    _expect(_visible_text(host, host._t("home.loading_title")), "Fresh installation starts in loading state")
    host.stored_games = [{"name": "扫描发现的游戏", "path": fixture.get_current_dir().path_join("discovered")}]
    host._refresh_games()
    _expect(_first_card(host, controller) != null, "Discovered game renders without waiting for the presenter poll")
    _expect(not _visible_text(host, host._t("home.empty_title")), "Discovery never passes through an empty state")
    _expect(not _visible_text(host, host._t("home.loading_title")), "Discovery clears the loading state")
    host.queue_free()
    await process_frame
    completed_cases += 1

func _run() -> void:
    create_timer(45).timeout.connect(func(): quit(1))
    fixture = DirAccess.create_temp("aether-library-startup")
    for viewport_size in [Vector2i(393, 852), Vector2i(1194, 834)]:
        for astryx in [true, false]:
            for cached in [true, false]:
                await _check_startup(astryx, viewport_size, cached)
    await _check_discovered_games()
    _expect(completed_cases == 9, "All startup cases completed without script errors")
    print("Library startup failures: ", failures)
    quit(0 if failures == 0 else 1)
