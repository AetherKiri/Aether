extends SceneTree

const Metadata = preload("res://scripts/game_metadata.gd")
const Launch = preload("res://scripts/game_launch_entry.gd")
const Mapping = preload("res://scripts/game_input_mapping.gd")
const Controls = preload("res://scripts/game_virtual_controls.gd")
var fixture := "user://xsystem4_library_test"

func _initialize() -> void:
    _remove(fixture)
    _write("System40.ini")
    assert(Metadata.inspect(fixture).engine == "kirikiri", "INI alone is insufficient")
    _write("Rance7.AIN")
    _write("Rance7.exe")
    var found := Metadata.inspect(fixture)
    assert(found.engine == "xsystem4")
    assert(found.launchFile.is_empty(), "System4 opens the asset directory")
    assert(Metadata.inspect(fixture.path_join("Rance7.exe")).engine == "xsystem4")
    assert(Launch.runtime_uses_directory("xsystem4"))
    assert(Launch.resolve_for_runtime({"path": fixture, "launchFile": "Rance7.exe"}, "xsystem4") == fixture)
    DirAccess.remove_absolute(fixture.path_join("System40.ini"))
    assert(Metadata.inspect(fixture).engine == "kirikiri", "AIN alone is insufficient")
    _write("ALICESTART.INI")
    assert(Metadata.inspect(fixture).engine == "xsystem4", "Alternate INI and mixed case are supported")

    # A 4:3 game letterboxed in a wide HiDPI window still consumes 800x600.
    assert(Mapping.input_surface_size("xsystem4", Vector2(800, 600), Vector2(1920, 1080)) == Vector2(800, 600))
    var target := Rect2(0, 0, 1920, 1080)
    assert(Mapping.map_point(Vector2(960, 540), target, Vector2(800, 600)).is_equal_approx(Vector2(400, 300)))
    assert(Mapping.map_point(Vector2(100, 540), target, Vector2(800, 600)).x < 0, "Letterbox clicks stay outside the game")
    var controls := Controls.new()
    assert(not controls.is_panel_open() and not controls.is_menu_open(), "Shared visual-novel controls start closed")
    controls.free()
    _remove(fixture)
    print("XSYSTEM4_LIBRARY_OK")
    quit()

func _write(name: String) -> void:
    DirAccess.make_dir_recursive_absolute(fixture)
    var file := FileAccess.open(fixture.path_join(name), FileAccess.WRITE)
    assert(file != null)
    file.store_string("")

func _remove(path: String) -> void:
    var directory := DirAccess.open(path)
    if directory == null:
        return
    for child in directory.get_files():
        DirAccess.remove_absolute(path.path_join(child))
    DirAccess.remove_absolute(path)
