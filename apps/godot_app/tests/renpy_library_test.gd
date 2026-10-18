extends SceneTree

const Metadata = preload("res://scripts/game_metadata.gd")
const Launch = preload("res://scripts/game_launch_entry.gd")
var failures := 0
var fixture_root := ""

func _expect(value: bool, message: String) -> void:
    if not value:
        failures += 1
        push_error(message)

func _write(relative: String, contents: String) -> void:
    var path := fixture_root.path_join(relative)
    DirAccess.make_dir_recursive_absolute(path.get_base_dir())
    var file := FileAccess.open(path, FileAccess.WRITE)
    file.store_string(contents)

func _initialize() -> void:
    fixture_root = ProjectSettings.globalize_path("user://renpy_metadata_%d" % Time.get_ticks_usec())
    _write("project/game/options.rpy", 'define config.name = _("中文 Ren’Py 标题")\n')
    _write("project/game/scripts/story.rpy", 'label start:\n    "Hello"\n')
    var project := fixture_root.path_join("project")
    var metadata := Metadata.inspect(project)
    _expect(metadata.engine == "renpy", "An ordinary Ren'Py project is detected")
    _expect(metadata.title == "中文 Ren’Py 标题", "The project title is read without executing Python")
    _expect(Metadata.renpy_game_directory(project) == "game", "Outer distribution resolves to game/")
    _expect(Metadata.inspect(project.path_join("game")).engine == "renpy", "A directly imported game folder is detected")
    _expect(Launch.resolve_for_runtime({"path": project, "launchFile": "Game.exe"}, "renpy") == project, "Ren'Py bypasses a Windows executable launch entry")
    _write("compiled/game/script.rpyc", "RENPY RPC2" + "invalid pickle payload must never be parsed by the metadata scanner")
    _expect(Metadata.inspect(fixture_root.path_join("compiled")).engine == "renpy", "Compiled script headers are recognized without unpickling")
    _write("packed/game/archive.rpa", "RPA-3.0 0000000000000040 00000000\n")
    _expect(Metadata.inspect(fixture_root.path_join("packed")).engine == "renpy", "A packed Ren'Py game is recognized by its archive signature")
    _write("bad/game/archive.rpa", "not a Ren'Py archive")
    _expect(Metadata.inspect(fixture_root.path_join("bad")).engine == "kirikiri", "An arbitrary file with an RPA extension is not claimed")
    _write("bundle.app/Contents/Resources/autorun/game/script.rpy", 'label start:\n    return\n')
    _expect(Metadata.renpy_game_directory(fixture_root.path_join("bundle.app")) == "Contents/Resources/autorun/game", "A macOS game bundle resolves its data directory")
    _write("krkr/game/cache/old.rpy", "cached fixture")
    _write("krkr/data.xp3", "xp3 fixture")
    _expect(Metadata.inspect(fixture_root.path_join("krkr")).engine == "kirikiri", "Cached source files do not steal another engine's project")
    print("RENPY_LIBRARY_OK" if failures == 0 else "RENPY_LIBRARY_FAILED")
    quit(0 if failures == 0 else 1)
