extends SceneTree
const Fixtures := preload("res://tests/xsystem_tools_test.gd")
var failures := 0
func check(value: bool, message: String) -> void:
    if not value:
        failures += 1
        push_error(message)
func _initialize() -> void:
    call_deferred("run")
func put(path: String, value: String) -> void:
    var file := FileAccess.open(path, FileAccess.WRITE)
    file.store_string(value)
func run() -> void:
    check(ClassDB.class_has_method("AetherRuntimePlayer", "manage_xsystem_mods"), "native MOD API is bound")
    if failures:
        quit(1)
        return
    var fixture := DirAccess.create_temp("aether-mod-bridge", false)
    var base := fixture.get_current_dir()
    fixture.make_dir("game")
    fixture.make_dir("mod")
    put(base.path_join("game/Game.ain"), "original")
    put(base.path_join("mod/Game.ain"), "modded")
    var host := Fixtures.Host.new()
    host.game_running = false
    host.player = ClassDB.instantiate("AetherRuntimePlayer")
    root.add_child(host)
    host.add_child(host.player)
    var service = host._xsystem_tools()
    check(service.request(base.path_join("game"), "install", base.path_join("mod")), "native worker starts")
    while service.busy:
        await process_frame
    var result: Dictionary = service.results[base.path_join("game")]
    check(result.get("ok", false), "native install result: " + str(result))
    check(FileAccess.get_file_as_string(base.path_join("game/Game.ain")) == "modded", "native install replaces the asset")
    if result.get("ok", false):
        service.request(base.path_join("game"), "uninstall", result.installed_id)
        while service.busy:
            await process_frame
        check(FileAccess.get_file_as_string(base.path_join("game/Game.ain")) == "original", "native uninstall restores bytes")
    # The main player is a scene child and may be freed before the service.
    # Closing during work must still finish the owned worker safely.
    service.request(base.path_join("game"), "list")
    host.queue_free()
    await process_frame
    print("XSYSTEM_MOD_BRIDGE_TEST: ", "PASS" if failures == 0 else "FAIL")
    quit(0 if failures == 0 else 1)
