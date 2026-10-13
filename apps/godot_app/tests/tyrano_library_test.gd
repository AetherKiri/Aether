extends SceneTree

const Metadata = preload("res://scripts/game_metadata.gd")
const Launch = preload("res://scripts/game_launch_entry.gd")
var failures := 0
var fixture := "user://tyrano_metadata_test"

func _initialize() -> void:
    _remove(fixture)
    _write("index.html", "<html>ordinary page</html>")
    _expect(Metadata.inspect(fixture).engine == "kirikiri", "An arbitrary HTML page is not TyranoScript")
    _write("tyrano/tyrano.js", "")
    _write("tyrano/plugins/kag/kag.js", "")
    _expect(Metadata.inspect(fixture).engine == "kirikiri", "Incomplete projects are not claimed")
    _write("data/system/Config.tjs", '// comment\n;System.title = "中文项目";\n;projectID = probe;')
    var found := Metadata.inspect(fixture)
    _expect(found.engine == "tyranoscript", "Browser project is detected")
    _expect(found.title == "中文项目" and found.launchFile == "index.html", "Config title and HTML entry are retained")
    _expect(Metadata.inspect(fixture.path_join("index.html")).engine == "tyranoscript", "An explicit HTML selection resolves its project")
    _expect(Launch.runtime_uses_directory("tyranoscript"), "Tyrano is a directory runtime rather than an EXE/XP3 launch")
    _expect(Launch.resolve_for_runtime({"path":fixture, "launchFile":"game.exe"}, "tyranoscript") == fixture,
        "A stale Windows launcher cannot replace the project root")
    var nested := fixture.path_join("desktop")
    for file in ["index.html", "tyrano/tyrano.js", "tyrano/plugins/kag/kag.js", "data/system/Config.tjs"]:
        _write("desktop/resources/app/" + file, ';System.title = "Electron project";')
    found = Metadata.inspect(nested)
    _expect(found.engine == "tyranoscript" and found.launchFile == "resources/app/index.html", "Unpacked Electron projects resolve their nested HTML entry")
    _expect(Metadata.inspect(nested).title == "Electron project", "Nested projects read their own config")
    _remove(fixture)
    print("TYRANO_LIBRARY_OK" if failures == 0 else "TYRANO_LIBRARY_FAILED")
    quit(0 if failures == 0 else 1)

func _write(relative: String, text: String) -> void:
    var path := fixture.path_join(relative)
    DirAccess.make_dir_recursive_absolute(path.get_base_dir())
    var file := FileAccess.open(path, FileAccess.WRITE)
    file.store_string(text)

func _expect(value: bool, message: String) -> void:
    if not value:
        failures += 1
        push_error(message)

func _remove(path: String) -> void:
    var directory := DirAccess.open(path)
    if directory == null:
        return
    for child in directory.get_files():
        DirAccess.remove_absolute(path.path_join(child))
    for child in directory.get_directories():
        _remove(path.path_join(child))
    DirAccess.remove_absolute(path)
