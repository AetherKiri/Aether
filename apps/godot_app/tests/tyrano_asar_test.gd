extends SceneTree

const Asar = preload("res://scripts/tyrano_asar.gd")
const Metadata = preload("res://scripts/game_metadata.gd")
const Launch = preload("res://scripts/game_launch_entry.gd")
var failures := 0
var fixture := "user://tyrano_asar_test"

func _initialize() -> void:
    Asar._remove(fixture)
    var game := fixture.path_join("game")
    var archive_path := game.path_join("resources/app.asar")
    var files := {"index.html": "<html>中文</html>", "tyrano/tyrano.js": "engine",
        "tyrano/plugins/kag/kag.js": "kag", "data/system/Config.tjs": ';System.title = "ASAR 中文";',
        "data/video.bin": "0123456789"}
    _archive(archive_path, files)
    _write(game.path_join("game.exe"), "Electron launcher")
    var detected := Metadata.inspect(game)
    _expect(detected.engine == "tyranoscript" and detected.launchFile == "resources/app.asar", "Packed Electron games are TyranoScript, not EXE/KiriKiri")
    _expect(detected.title == "ASAR 中文" and detected.signals.has("tyranoscript-asar-project"), "Packed config supplies the title and detection signal")
    _expect(Metadata.inspect(game.path_join("game.exe")).engine == "tyranoscript", "Selecting an Electron EXE still detects the enclosing ASAR")
    _expect(Launch.resolve_for_runtime({"path": game, "launchFile": "game.exe"}, detected.engine) == game, "A saved EXE launch entry cannot override ASAR routing")
    var archive := Asar.new()
    _expect(archive.open(archive_path), "The packed index opens")
    var prepared := archive.prepare(fixture.path_join("cache"))
    _expect(prepared.has("entry"), "ASAR prepares a browser project")
    if prepared.has("entry"):
        _expect(FileAccess.get_file_as_string(prepared.entry) == files["index.html"], "UTF-8 HTML is copied intact")
        var video := String(prepared.entry).get_base_dir().path_join("data/video.bin")
        _expect(FileAccess.get_file_as_string(video) == "0123456789", "Binary payload boundaries are respected")
        var reused := archive.prepare(fixture.path_join("cache"))
        _expect(reused.get("entry") == prepared.entry, "A complete cache is reused")
        DirAccess.remove_absolute(video)
        reused = archive.prepare(fixture.path_join("cache"))
        _expect(reused.has("entry") and FileAccess.file_exists(video), "An incomplete cache is rebuilt")
        files["data/video.bin"] = "9876543210"
        _archive(archive_path, files)
        var updated := Asar.new()
        _expect(updated.open(archive_path), "The same-size updated archive opens")
        reused = updated.prepare(fixture.path_join("cache"))
        _expect(reused.has("entry") and reused.entry != prepared.entry, "Content updates invalidate the cache even with identical sizes and timestamps")
    _expect(not FileAccess.file_exists(game.path_join("resources/app/index.html")), "Preparation never writes to the original game")

    var unpacked := fixture.path_join("unpacked/app.asar")
    _archive(unpacked, files, ["data/video.bin"])
    _write(unpacked + ".unpacked/data/video.bin", "external01")
    archive = Asar.new()
    _expect(archive.open(unpacked), "Unpacked-member index opens")
    prepared = archive.prepare(fixture.path_join("cache"))
    _expect(prepared.has("entry"), "app.asar.unpacked resources are included")
    if prepared.has("entry"):
        _expect(FileAccess.get_file_as_string(String(prepared.entry).get_base_dir().path_join("data/video.bin")) == "external01", "External member bytes are used")
    _write(unpacked + ".unpacked/data/video.bin", "external02")
    var changed := archive.prepare(fixture.path_join("cache"))
    _expect(changed.has("entry") and changed.get("entry") != prepared.get("entry"), "Changed unpacked resources invalidate the cache")
    DirAccess.remove_absolute(unpacked + ".unpacked/data/video.bin")
    _expect(archive.prepare(fixture.path_join("cache")).has("error"), "Missing external members cannot silently become empty resources")
    if OS.get_name() in ["macOS", "Linux"]:
        var outside := ProjectSettings.globalize_path(fixture.path_join("outside.bin"))
        _write(outside, "external01")
        var link := ProjectSettings.globalize_path(unpacked + ".unpacked/data/video.bin")
        _expect(DirAccess.open(fixture).create_link(outside, link) == OK, "The external resource symlink fixture is created")
        var linked := Asar.new()
        _expect(linked.open(unpacked), "The symlink test index opens")
        _expect(linked.prepare(fixture.path_join("cache")).has("error"), "Unpacked symlinks cannot read outside the resource root")

    _archive(fixture.path_join("ordinary/app.asar"), {"index.html": "ordinary Electron app"})
    _expect(Metadata.inspect(fixture.path_join("ordinary")).engine != "tyranoscript", "Ordinary Electron apps are not claimed")
    _archive(fixture.path_join("root/app.asar"), files)
    _expect(Metadata.inspect(fixture.path_join("root")).engine == "tyranoscript", "An app.asar at the imported root is recognized")
    var malformed := fixture.path_join("bad.asar")
    for index in [
        {"files": {"..": {"files": {"escape": {"size": 1, "offset": "0"}}}}},
        {"files": {"/absolute": {"size": 1, "offset": "0"}}},
        {"files": {"a\\escape": {"size": 1, "offset": "0"}}},
        {"files": {"link": {"link": "../outside"}}},
        {"files": {"beyond": {"size": 2, "offset": "0"}}},
        {"files": {"overflow": {"size": 1, "offset": "99999999999999999999"}}},
        {"files": {"negative": {"size": -1, "offset": "0"}}},
        {"files": {"fraction": {"size": 0.5, "offset": "0"}}},
        {"files": {"oversized": {"size": Asar.MAX_BYTES + 1, "unpacked": true}}},
    ]:
        _pack(malformed, index, "x".to_utf8_buffer())
        _expect(not Asar.new().open(malformed), "Unsafe or out-of-bounds ASAR indices are rejected")
    _write(malformed, "not an ASAR")
    _expect(not Asar.new().open(malformed), "Truncated headers are rejected")
    var huge := FileAccess.open(malformed, FileAccess.WRITE)
    huge.store_32(4)
    huge.store_32(Asar.MAX_HEADER + 4)
    huge.store_32(Asar.MAX_HEADER)
    huge.store_32(Asar.MAX_HEADER - 4)
    huge.close()
    _expect(not Asar.new().open(malformed), "Oversized index lengths are rejected before allocation")
    archive = Asar.new()
    _expect(archive.open(archive_path), "Cancellation fixture opens")
    archive.cancel()
    _expect(archive.prepare(fixture.path_join("cancelled-cache")).has("error"), "Cancelled preparation cannot publish a cache")
    Asar._remove(fixture)
    print("TYRANO_ASAR_OK" if failures == 0 else "TYRANO_ASAR_FAILED")
    quit(0 if failures == 0 else 1)

func _archive(path: String, files: Dictionary, unpacked: Array = []) -> void:
    var tree := {"files": {}}
    var body := PackedByteArray()
    for name in files:
        var node: Dictionary = tree
        var parts: PackedStringArray = name.split("/")
        for i in range(parts.size() - 1):
            if not node.files.has(parts[i]):
                node.files[parts[i]] = {"files": {}}
            node = node.files[parts[i]]
        var bytes: PackedByteArray = files[name].to_utf8_buffer()
        var item := {"size": bytes.size()}
        if name in unpacked:
            item.unpacked = true
        else:
            item.offset = str(body.size())
            body.append_array(bytes)
        node.files[parts[-1]] = item
    _pack(path, tree, body)

func _pack(path: String, tree: Dictionary, body: PackedByteArray) -> void:
    DirAccess.make_dir_recursive_absolute(path.get_base_dir())
    var header := JSON.stringify(tree).to_utf8_buffer()
    var padding := (4 - header.size() % 4) % 4
    var file := FileAccess.open(path, FileAccess.WRITE)
    file.store_32(4)
    file.store_32(8 + header.size() + padding)
    file.store_32(4 + header.size() + padding)
    file.store_32(header.size())
    file.store_buffer(header)
    for _i in range(padding):
        file.store_8(0)
    file.store_buffer(body)

func _write(path: String, value: String) -> void:
    DirAccess.make_dir_recursive_absolute(path.get_base_dir())
    var file := FileAccess.open(path, FileAccess.WRITE)
    file.store_string(value)

func _expect(value: bool, message: String) -> void:
    if not value:
        failures += 1
        push_error(message)
