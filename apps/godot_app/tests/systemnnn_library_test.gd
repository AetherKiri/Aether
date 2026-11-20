extends SceneTree

const Main = preload("res://scripts/main.gd")
const Metadata = preload("res://scripts/game_metadata.gd")
const Launch = preload("res://scripts/game_launch_entry.gd")
const Mapping = preload("res://scripts/game_input_mapping.gd")
const Locations = preload("res://scripts/game_save_locations.gd")

var fixture: DirAccess
var game_root: String
var failures := 0

func _expect(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error(message)

func _initialize() -> void:
    fixture = DirAccess.create_temp("aether-systemnnn-library")
    if fixture == null:
        quit(1)
        return
    game_root = fixture.get_current_dir()
    _write("Game.exe")
    _write("sys.spt")
    _write("spt/story.spt")
    _expect(Metadata.inspect(game_root).engine == "kirikiri", "Unrelated SPT files do not claim SystemNNN")
    _write("spt/sys.spt.backup")
    _expect(Metadata.inspect(game_root).engine == "kirikiri", "Boot script detection requires the exact filename")
    _write("spt/SyS.SpT")
    _expect(Metadata.inspect(game_root).engine == "systemnnn", "SystemNNN recognizes a case-insensitive boot filename")
    DirAccess.remove_absolute(game_root.path_join("spt/SyS.SpT"))
    _write("SpT/SYS.SPT")
    _expect(Metadata.inspect(game_root).engine == "systemnnn", "SystemNNN recognizes a case-insensitive boot directory")
    var found: Dictionary = Metadata.inspect(game_root.path_join("Game.exe"))
    _expect(found.engine == "systemnnn" and found.launchFile.is_empty(), "The launcher resolves to the SystemNNN game directory")
    var app := Main.new()
    _expect(app.player == null, "Library metadata test runs without a native provider")
    var imported: Dictionary = app._game_info_from_path(game_root)
    _expect(imported.engine == "systemnnn" and imported.launchFile.is_empty(), "Import preserves SystemNNN detection without the native extension")
    _expect(not app._can_configure_launch_file(imported), "SystemNNN does not offer an executable selector")
    _expect(Launch.resolve_for_runtime({"path": game_root, "launchFile": "Game.exe"}, "systemnnn") == game_root, "SystemNNN receives the game directory")
    _expect(Mapping.input_surface_size("systemnnn", Vector2(800, 600), Vector2(1920, 1080)) == Vector2(800, 600), "SystemNNN pointer input uses native frame pixels")
    var bank: Dictionary = Locations.resolve(game_root, "systemnnn", {}, game_root.path_join("user"))
    _expect(bank.main.path == Locations.systemnnn_user_directory(game_root.path_join("user"), game_root).path_join("systemnnn"), "SystemNNN slots use the host per-game writable directory")
    app.ui_motion.free()
    app.free()
    for relative in ["Game.exe", "sys.spt", "spt/story.spt", "spt/sys.spt.backup", "SpT/SYS.SPT"]:
        DirAccess.remove_absolute(game_root.path_join(relative))
    for relative in ["spt", "SpT"]:
        DirAccess.remove_absolute(game_root.path_join(relative))
    fixture = null
    print("SYSTEMNNN_LIBRARY_OK" if failures == 0 else "SYSTEMNNN_LIBRARY_FAILED")
    quit(0 if failures == 0 else 1)

func _write(relative: String) -> void:
    var path := game_root.path_join(relative)
    DirAccess.make_dir_recursive_absolute(path.get_base_dir())
    var file := FileAccess.open(path, FileAccess.WRITE)
    _expect(file != null, "Create isolated library marker")
    if file != null:
        file.store_string("fixture")
