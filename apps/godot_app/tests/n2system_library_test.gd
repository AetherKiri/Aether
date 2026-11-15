extends SceneTree

const Main = preload("res://scripts/main.gd")
const Metadata = preload("res://scripts/game_metadata.gd")
const Launch = preload("res://scripts/game_launch_entry.gd")
const Mapping = preload("res://scripts/game_input_mapping.gd")

var fixture: DirAccess
var game_root: String
var failures := 0

func _expect(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error(message)

func _initialize() -> void:
    fixture = DirAccess.create_temp("aether-n2system-library")
    if fixture == null:
        quit(1)
        return
    game_root = fixture.get_current_dir()
    _write("Game.exe", PackedByteArray())
    _write("nss.npa", "not an NPA".to_utf8_buffer())
    _write("system.npa", "not an NPA".to_utf8_buffer())
    _expect(Metadata.inspect(game_root).engine == "kirikiri", "NPA extensions alone must not claim a game")
    _write("nss.npa", PackedByteArray([0x4e, 0x50, 0x41, 1, 0, 0, 0]))
    _expect(Metadata.inspect(game_root).engine == "kirikiri", "One valid NPA marker is insufficient")
    _write("system.npa", PackedByteArray([0x4e, 0x50, 0x41, 1, 0, 0, 0]))
    _expect(Metadata.inspect(game_root).engine == "n2system", "The paired N2 archive markers select N2System")
    var found: Dictionary = Metadata.inspect(game_root.path_join("Game.exe"))
    _expect(found.engine == "n2system" and found.launchFile.is_empty(), "A Windows launcher resolves to the game directory")
    DirAccess.remove_absolute(game_root.path_join("nss.npa"))
    DirAccess.remove_absolute(game_root.path_join("system.npa"))
    _write("script.pak", "unrelated".to_utf8_buffer())
    _write("system.pak", "unrelated".to_utf8_buffer())
    _write("sys_cn.ini", "width=800".to_utf8_buffer())
    _write("game_cn.ini", "Begin=menu.nps".to_utf8_buffer())
    _expect(Metadata.inspect(game_root).engine == "kirikiri", "Legacy PAK extensions alone do not select N2System")
    var pak := PackedByteArray()
    pak.resize(0x108)
    pak[0] = 3
    pak[0x104] = 100
    _write("script.pak", pak)
    _write("system.pak", pak)
    _expect(Metadata.inspect(game_root).engine == "n2system", "Legacy N2 PAK pair and config select N2System")
    for file in ["script.pak", "system.pak", "sys_cn.ini", "game_cn.ini"]:
        DirAccess.remove_absolute(game_root.path_join(file))
    _write("profiles.json", '{"activeProfile":"default","profiles":{}}'.to_utf8_buffer())
    _expect(Metadata.inspect(game_root).engine == "kirikiri", "Unrelated JSON profiles do not select NitroSharp")
    _write("profiles.json", '{"activeProfile":null,"product.name":"Test","designResolution":"1280x720"}'.to_utf8_buffer())
    _expect(Metadata.inspect(game_root).engine == "n2system", "NitroSharp profiles identify loose-script games")
    _write("profiles.json", '{"activeProfile":"demo","profiles":{"demo":{"product.name":"Test","designResolution":"320x180"}}}'.to_utf8_buffer())
    _expect(Metadata.inspect(game_root).engine == "n2system", "The active profile can supply the engine properties")
    DirAccess.remove_absolute(game_root.path_join("profiles.json"))
    _write("aether-n2system.json", "{}".to_utf8_buffer())
    _expect(Metadata.inspect(game_root).engine == "n2system", "An explicit profile retains N2System selection for startup diagnostics")

    var app := Main.new()
    var imported: Dictionary = app._game_info_from_path(game_root)
    _expect(imported.engine == "n2system" and imported.launchFile.is_empty(), "Library import persists the N2System directory runtime")
    _expect(not app._can_configure_launch_file(imported), "N2System does not offer a Windows EXE entry selector")
    _expect(Launch.resolve_for_runtime({"path": game_root, "launchFile": "Game.exe"}, "n2system") == game_root, "Legacy launch-file choices cannot replace the N2 game directory")
    _expect(Mapping.input_surface_size("n2system", Vector2(1280, 720), Vector2(1920, 1080)) == Vector2(1280, 720), "N2System input follows the native frame size")
    app.ui_motion.free()
    app.free()
    for file in fixture.get_files():
        DirAccess.remove_absolute(game_root.path_join(file))
    fixture = null
    print("N2SYSTEM_LIBRARY_OK" if failures == 0 else "N2SYSTEM_LIBRARY_FAILED")
    quit(0 if failures == 0 else 1)

func _write(name: String, bytes: PackedByteArray) -> void:
    var file := FileAccess.open(game_root.path_join(name), FileAccess.WRITE)
    _expect(file != null, "Create isolated metadata fixture")
    if file != null:
        file.store_buffer(bytes)
