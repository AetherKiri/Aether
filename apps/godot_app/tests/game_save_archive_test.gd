extends SceneTree

const Archive := preload("res://scripts/game_save_archive.gd")
const Locations := preload("res://scripts/game_save_locations.gd")
var failures := 0
var fixture: DirAccess

func check(value: bool, message: String) -> void:
    if not value:
        failures += 1
        printerr("FAIL: " + message)

func put(path: String, bytes: PackedByteArray) -> void:
    DirAccess.make_dir_recursive_absolute(path.get_base_dir())
    var file := FileAccess.open(path, FileAccess.WRITE)
    file.store_buffer(bytes)
    file.close()

func forged(path: String, name: String, entry: String, bytes: PackedByteArray, digest: String = "") -> void:
    var hash := HashingContext.new()
    hash.start(HashingContext.HASH_SHA256)
    hash.update(bytes)
    var manifest := {"format": "aether-saves", "version": 1, "game_name": name, "engine": "catsystem2",
        "files": [{"path": entry, "size": bytes.size(), "sha256": hash.finish().hex_encode() if digest.is_empty() else digest}]}
    var zip := ZIPPacker.new()
    zip.open(path)
    zip.start_file(Archive.MANIFEST)
    zip.write_file(JSON.stringify(manifest).to_utf8_buffer())
    zip.close_file()
    zip.start_file(entry)
    zip.write_file(bytes)
    zip.close_file()
    zip.close()

func _initialize() -> void:
    fixture = DirAccess.create_temp("aether-save-test")
    var root := fixture.get_current_dir()
    var game := root.path_join("game/savedata")
    var other := root.path_join("other/savedata")
    var banks := {"main": {"path": game, "exclude": ["cache"]}}
    var bytes := PackedByteArray([0, 1, 128, 255, 6])
    var first := game.path_join("slot.aecs2")
    var second := game.path_join("中文/缩略图.bin")
    put(first, bytes)
    put(second, "预览".to_utf8_buffer())
    put(game.path_join("cache/secret"), "cache".to_utf8_buffer())
    put(other.path_join("slot.aecs2"), "other game".to_utf8_buffer())
    var archive := root.path_join("saves.zip")
    var backup := root.path_join("backup.zip")
    var exported := Archive.export_zip(" 游戏甲 ", "catsystem2", banks, archive)
    check(exported.ok and exported.get("count") == 2, "Only current game's saves, including thumbnails, are archived")
    check(Archive._bounded_zip(archive), "Export passes bounded ZIP validation")
    var zip := ZIPReader.new()
    check(zip.open(archive) == OK, "Export is a standard ZIP")
    check(zip.read_file("main/slot.aecs2") == bytes, "Binary save content survives ZIP")
    check(zip.file_exists("main/中文/缩略图.bin") and not zip.file_exists("main/cache/secret"), "Unicode paths work and caches are excluded")
    var metadata = JSON.parse_string(zip.read_file(Archive.MANIFEST).get_string_from_utf8())
    check(metadata.game_name == "游戏甲" and not JSON.stringify(metadata).contains(root), "Portable manifest carries a game name, never local paths")
    zip.close()
    put(first, "new local save".to_utf8_buffer())
    var rejected := Archive.import_zip("游戏乙", "catsystem2", banks, archive, backup)
    check(not rejected.ok and rejected.error == "different_game", "A different game name is rejected")
    check(FileAccess.get_file_as_bytes(first) == "new local save".to_utf8_buffer() and not FileAccess.file_exists(backup), "Rejected import never writes or backs up unrelated saves")
    check(not Archive.import_zip("游戏甲", "bgi", banks, archive, backup).ok, "A different engine is rejected")
    var restored := Archive.import_zip("游戏甲", "catsystem2", banks, archive, backup)
    check(restored.ok and FileAccess.get_file_as_bytes(first) == bytes, "Matching archive restores the selected game")
    check(zip.open(backup) == OK and zip.read_file("main/slot.aecs2") == "new local save".to_utf8_buffer(), "Previous local saves are retained in a ZIP backup")
    zip.close()
    check(FileAccess.get_file_as_bytes(other.path_join("slot.aecs2")) == "other game".to_utf8_buffer(), "Other games remain untouched")
    for path in ["main/../escape", "/absolute", "main/C:/escape", "main/dir\\escape", "unknown/file"]:
        var bad := root.path_join("bad.zip")
        forged(bad, "游戏甲", path, bytes)
        check(not Archive.import_zip("游戏甲", "catsystem2", banks, bad, backup).ok, "Reject traversal or unrecognized bank: " + path)
    var bad := root.path_join("bad.zip")
    forged(bad, "游戏甲", "main/slot.aecs2", bytes, "incorrect")
    check(not Archive.import_zip("游戏甲", "catsystem2", banks, bad, backup).ok and FileAccess.get_file_as_bytes(first) == bytes, "Checksum failures are detected before writing")
    # A write failure after one file was replaced must roll that file back.
    put(first, "before rollback".to_utf8_buffer())
    put(second + ".aether-restore-old", "occupied".to_utf8_buffer())
    check(not Archive.import_zip("游戏甲", "catsystem2", banks, archive, root.path_join("rollback.zip")).ok, "Conflicting transaction file rejects restore")
    check(FileAccess.get_file_as_bytes(first) == "before rollback".to_utf8_buffer(), "A partial write is rolled back")
    DirAccess.remove_absolute(second + ".aether-restore-old")
    if OS.get_name() != "Windows":
        fixture.create_link(other, game.path_join("linked"))
        check(not Archive.export_zip("游戏甲", "catsystem2", banks, root.path_join("linked.zip")).ok, "Exports do not follow links into another game")
        forged(bad, "游戏甲", "main/linked/slot.aecs2", bytes)
        check(not Archive.import_zip("游戏甲", "catsystem2", banks, bad, backup).ok, "Imports do not follow links into another game")
        DirAccess.remove_absolute(game.path_join("linked"))
    var empty := {"main": {"path": root.path_join("empty")}}
    check(Archive.export_zip("Game", "catsystem2", empty, root.path_join("empty.zip")).get("error") == "no_saves", "No empty archive is offered for sharing")
    check(Archive.folder_name("游戏甲") != Archive.folder_name("游戏乙"), "Cloud folders separate games by name")
    check(Archive.folder_name("a/b") != Archive.folder_name("a:b"), "Filename sanitization cannot collide between names")
    check(Archive.safe_relative(Archive.folder_name("../坏名字")), "Cloud folder names cannot escape the selected folder")
    var user := root.path_join("user")
    var resolved := Locations.resolve(root.path_join("game"), "catsystem2", {}, user)
    check(resolved.main.path == game, "Game-local saves use the current game directory")
    put(root.path_join("alice/Game.ain"), bytes)
    resolved = Locations.resolve(root.path_join("alice"), "xsystem4", {}, user)
    check(String(resolved.main.path).begins_with(user + "/xsystem4/") and resolved.main.path != user, "System4 selects a game-specific bank")
    check(Locations.resolve(root.path_join("other"), "minori", {}, user).is_empty(), "Legacy shared saves cannot be attributed to the current game")
    for file in ["script.cls", "system.cpk", "model.cpk"]:
        put(root.path_join("mages/" + file), bytes)
    resolved = Locations.resolve(root.path_join("mages"), "mages", {}, user)
    check(resolved.main.path == user.path_join("saves/rne"), "MAGES exports only the detected game's profile")
    put(root.path_join("rfvp/story.hcb"), bytes)
    put(root.path_join("rfvp/aether_config.json"), '{"text":{"encoding":"GBK"}}'.to_utf8_buffer())
    var gbk := Locations.resolve(root.path_join("rfvp"), "rfvp", {"launchFile": "story.hcb"}, user)
    put(root.path_join("rfvp/aether_config.json"), '{"text":{"encoding":"CP932"}}'.to_utf8_buffer())
    var sjis := Locations.resolve(root.path_join("rfvp"), "rfvp", {"launchFile": "story.hcb"}, user)
    check(gbk.main.path != sjis.main.path, "RFVP follows the configured encoding's actual save bank")
    var allowed_bank := {"main": {"path": root.path_join("wa2"), "files": ["save_00.sav"]}}
    put(root.path_join("wa2/save_00.sav"), bytes)
    put(root.path_join("wa2/game.dat"), "private assets".to_utf8_buffer())
    if OS.get_name() != "Windows":
        fixture.create_link(other, root.path_join("wa2/unrelated-assets"))
    var limited := root.path_join("limited.zip")
    check(Archive.export_zip("WA2", "wa2", allowed_bank, limited).get("count") == 1, "Root-level saves do not traverse assets or unrelated links")
    print("Save archive failures: %d" % failures)
    quit(0 if failures == 0 else 1)
