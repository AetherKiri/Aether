extends SceneTree

const Metadata = preload("res://scripts/game_metadata.gd")
const Launch = preload("res://scripts/game_launch_entry.gd")
const Mapping = preload("res://scripts/game_input_mapping.gd")
const Controls = preload("res://scripts/game_virtual_controls.gd")
var fixture := "user://xsystem35_library_test"

func _initialize() -> void:
    _remove()
    _write("System39.ain")
    assert(Metadata.inspect(fixture).engine == "kirikiri", "An AIN alone is ambiguous")
    _write("Rance4Sa.AlD")
    _write("System39.exe")
    var found := Metadata.inspect(fixture)
    assert(found.engine == "xsystem35")
    assert(found.launchFile.is_empty())
    assert(Metadata.inspect(fixture.path_join("System39.exe")).engine == "xsystem35")
    assert(Launch.runtime_uses_directory("xsystem35"))
    assert(Launch.resolve_for_runtime({"path": fixture, "launchFile": "System39.exe"}, "xsystem35") == fixture)
    _write("ALICESTART.INI")
    assert(Metadata.inspect(fixture).engine == "xsystem4", "System4 INI takes priority over ALD")
    DirAccess.remove_absolute(fixture.path_join("ALICESTART.INI"))
    DirAccess.remove_absolute(fixture.path_join("Rance4Sa.AlD"))
    _write("ADISK.dat")
    assert(Metadata.inspect(fixture).engine == "kirikiri", "DAT alone is ambiguous")
    _write("ACG.DAT")
    assert(Metadata.inspect(fixture).engine == "system3", "Older Rance4.1/4.2 need System3")
    assert(Mapping.input_surface_size("xsystem35", Vector2(640, 480), Vector2(1920, 1080)) == Vector2(640, 480))
    assert(Mapping.map_point(Vector2(960, 540), Rect2(0, 0, 1920, 1080), Vector2(640, 480)).is_equal_approx(Vector2(320, 240)))
    var controls := Controls.new()
    assert(not controls.is_panel_open() and not controls.is_menu_open())
    controls.free()
    _remove()
    print("XSYSTEM35_LIBRARY_OK")
    quit()

func _write(name: String) -> void:
    DirAccess.make_dir_recursive_absolute(fixture)
    var file := FileAccess.open(fixture.path_join(name), FileAccess.WRITE)
    assert(file != null)
    file.store_string("")

func _remove() -> void:
    var directory := DirAccess.open(fixture)
    if directory == null:
        return
    for child in directory.get_files():
        DirAccess.remove_absolute(fixture.path_join(child))
    DirAccess.remove_absolute(fixture)
