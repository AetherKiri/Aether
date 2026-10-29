extends SceneTree

const Metadata = preload("res://scripts/game_metadata.gd")
const Launch = preload("res://scripts/game_launch_entry.gd")
const Mapping = preload("res://scripts/game_input_mapping.gd")
const Controls = preload("res://scripts/game_virtual_controls.gd")
var fixture := "user://system3_library_test"

func _initialize() -> void:
    _remove()
    _write("ADISK.DAT")
    assert(Metadata.inspect(fixture).engine == "kirikiri", "DAT alone is ambiguous")
    _write("AcG.dAt")
    _write("SyStEm3.ExE")
    var found := Metadata.inspect(fixture)
    assert(found.engine == "system3" and found.launchFile.is_empty())
    assert(Metadata.inspect(fixture.path_join("SyStEm3.ExE")).engine == "system3")
    assert(Launch.runtime_uses_directory("system3"))
    assert(Launch.resolve_for_runtime({"path": fixture, "launchFile": "SyStEm3.ExE"}, "system3") == fixture)
    _write("RanceSa.AlD")
    assert(Metadata.inspect(fixture).engine == "xsystem35")
    _write("ALICESTART.INI")
    _write("Game.ain")
    assert(Metadata.inspect(fixture).engine == "xsystem4")
    _remove()
    _write("GDISK.DAT")
    _write("GCG.DAT")
    assert(Metadata.inspect(fixture).engine == "system3", "Hint disk variants retain directory launch")
    assert(Mapping.input_surface_size("system3", Vector2(640, 400), Vector2(1920, 1080)) == Vector2(640, 400))
    assert(Mapping.map_point(Vector2(960, 540), Rect2(0, 0, 1920, 1080), Vector2(640, 400)).is_equal_approx(Vector2(320, 200)))
    var controls := Controls.new()
    assert(not controls.is_panel_open() and not controls.is_menu_open())
    controls.free()
    _remove()
    print("SYSTEM3_LIBRARY_OK")
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
