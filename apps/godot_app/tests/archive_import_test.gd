extends SceneTree

const Launch := preload("res://scripts/game_launch_entry.gd")

var errors := 0

func check(ok: bool, label: String) -> void:
    if not ok:
        printerr(label)
        errors += 1

func write(path: String, bytes: PackedByteArray) -> void:
    var file := FileAccess.open(path, FileAccess.WRITE)
    file.store_buffer(bytes)

func zip(path: String, member: String, contents: PackedByteArray) -> void:
    var pack := ZIPPacker.new()
    check(pack.open(path) == OK, "create ZIP")
    pack.start_file(member)
    pack.write_file(contents)
    pack.close_file()
    pack.close()

func zip_entries(path: String, members: Array) -> void:
    var pack := ZIPPacker.new()
    check(pack.open(path) == OK, "create archive options fixture")
    for pair in members:
        pack.start_file(pair[0])
        pack.write_file(String(pair[1]).to_utf8_buffer())
        pack.close_file()
    pack.close()

func check_plan(reader: RefCounted, root: String) -> void:
    var encrypted := ProjectSettings.globalize_path("res://../../packages/AetherUnzip/tests/fixtures/7z-aes-picker.7z").simplify_path()
    check(reader.inspect(encrypted).status in [-12, -13], "locked header requests a password before reading the layout")
    check(reader.inspect(encrypted, "incorrect").status in [-12, -13], "wrong password cannot expose the encrypted catalog")
    var unlocked: Dictionary = reader.inspect(encrypted, "fixture-pass")
    check(unlocked.status == OK and unlocked.entries >= 2 and not unlocked.placement.can_strip, "correct password reveals the layout before confirming extraction")
    var decrypted: Dictionary = reader.extract_to(encrypted, root.path_join("decrypted"), "fixture-pass", "direct", "stop")
    check(decrypted.status == OK and FileAccess.file_exists(root.path_join("decrypted/private.txt")), "password-protected plan writes the selected structure")
    var src := root.path_join("Layout.zip")
    zip_entries(src, [["Shared/data/scene.txt", "new"], ["Shared/game.exe", "game"]])
    var catalog: Dictionary = reader.inspect(src)
    check(catalog.placement.can_strip and catalog.placement.common_directory == "Shared", "recognize the common top folder")
    for mode: String in ["smart", "direct", "folder", "strip"]:
        var dest := root.path_join("location_" + mode)
        DirAccess.make_dir_recursive_absolute(dest)
        var out: Dictionary = reader.extract_to(src, dest, "", mode, "keep", root.path_join("Games"))
        var expected := {"smart": "Shared", "direct": "Shared", "folder": "Layout/Shared", "strip": ""}.get(mode) as String
        var contents := dest.path_join(expected) if not expected.is_empty() else dest
        check(out.status == OK and FileAccess.get_file_as_string(contents.path_join("data/scene.txt")) == "new", mode + " writes the selected layout into the selected folder")
        check(String(out.game_root).simplify_path() == contents.simplify_path(), mode + " returns the actual game root to register")
        if mode in ["smart", "folder"]:
            var again: Dictionary = reader.extract_to(src, dest, "", mode, "replace")
            check(again.status == OK and String(again.destination).ends_with(" (2)"), mode + " reserves a new folder even with replace")
    var library := root.path_join("SharedCollection")
    DirAccess.make_dir_recursive_absolute(library)
    write(library.path_join("unrelated.dat"), "preserve".to_utf8_buffer())
    var merged: Dictionary = reader.extract_to(src, library, "", "strip", "keep")
    check(merged.game_root == library.path_join("game.exe"), "a game in a shared destination cannot own the directory or sibling games")
    var entry := {"path": merged.game_root, "archiveFileEntry": true, "launchFile": "game.exe"}
    check(Launch.resolve_for_runtime(entry, "yuris") == library, "directory engines receive the containing game folder")
    check(Launch.resolve_for_runtime(entry, "kirikiri") == merged.game_root, "a loose launcher is used exactly once")
    check(reader.extract_to(src, library, "", "strip", "skip").game_root == "", "skipping a preexisting launcher does not claim it as an imported game")
    zip_entries(src, [["extra.txt", "extra"], ["same.txt", "new"]])
    check(not reader.inspect(src).placement.can_strip, "multiple roots cannot be stripped")
    for policy: String in ["keep", "skip", "stop", "replace"]:
        var dest := root.path_join("collision_" + policy)
        DirAccess.make_dir_recursive_absolute(dest)
        var same := dest.path_join("same.txt")
        write(same, "old".to_utf8_buffer())
        var result: Dictionary = reader.extract_to(src, dest, "", "direct", policy)
        if policy == "stop":
            check(result.status == -10 and not FileAccess.file_exists(dest.path_join("extra.txt")), "stop is checked before other files are committed")
        else:
            check(result.status == OK and FileAccess.file_exists(dest.path_join("extra.txt")), policy + " still extracts the remaining files")
        check(FileAccess.get_file_as_string(same) == ("new" if policy == "replace" else "old"), policy + " handles the existing file")
        check(FileAccess.file_exists(dest.path_join("same (2).txt")) == (policy == "keep"), "only keep both creates a numbered copy")
        check(reader.extract_to(src, dest, "", "strip", policy).status < 0, "ineligible strip mode never writes files")
    var single := root.path_join("Loose.zip")
    zip(single, "story.txt", "one".to_utf8_buffer())
    var single_root := root.path_join("plain")
    var plain: Dictionary = reader.extract_to(single, single_root, "", "smart", "keep")
    var numbered: Dictionary = reader.extract_to(single, single_root, "", "smart", "keep")
    check(plain.destination == single_root.path_join("story.txt") and numbered.destination == single_root.path_join("story (2).txt"), "smart places a loose file directly and reports actual numbered path")
    var protected_path := root.path_join("Protect.zip")
    zip(protected_path, "Protect.zip", "different".to_utf8_buffer())
    var original := FileAccess.get_file_as_bytes(protected_path)
    check(reader.extract_to(protected_path, root, "", "direct", "replace").status == -10 and FileAccess.get_file_as_bytes(protected_path) == original, "replace preserves the input archive")
    zip_entries(src, [["a.txt", "first"], ["a.txt", "second"]])
    var duplicates := root.path_join("duplicates")
    var duplicate: Dictionary = reader.extract_to(src, duplicates, "", "direct", "keep")
    check(duplicate.status == OK and FileAccess.file_exists(duplicates.path_join("a (2).txt")), "the file conflict policy also applies to duplicate archive entries")
    if OS.get_name() == "macOS" and OS.get_environment("USER") != "root":
        zip_entries(src, [["One/save.txt", "new"], ["Two/save.txt", "new"], ["added.txt", "new"]])
        for blocked: String in ["One", "Two"]:
            var dest := root.path_join("rollback_" + blocked)
            for folder: String in ["One", "Two"]:
                DirAccess.make_dir_recursive_absolute(dest.path_join(folder))
                write(dest.path_join(folder + "/save.txt"), "old".to_utf8_buffer())
            var read_only := dest.path_join(blocked)
            var previous := FileAccess.get_unix_permissions(read_only)
            var write_bits := FileAccess.UNIX_WRITE_OWNER | FileAccess.UNIX_WRITE_GROUP | FileAccess.UNIX_WRITE_OTHER
            check(FileAccess.set_unix_permissions(read_only, previous & ~write_bits) == OK, "make a read-only destination")
            var interrupted: Dictionary = reader.extract_to(src, dest, "", "direct", "replace")
            FileAccess.set_unix_permissions(read_only, previous)
            check(interrupted.status < 0 and not FileAccess.file_exists(dest.path_join("added.txt")), "a late write error rolls back new output")
            for folder: String in ["One", "Two"]:
                check(FileAccess.get_file_as_string(dest.path_join(folder + "/save.txt")) == "old", "a late write error restores each original")

func _initialize() -> void:
    if not ClassDB.class_exists("AetherArchiveReader"):
        if OS.get_name() in ["macOS", "iOS", "Android"]:
            printerr("Archive reader is missing from the native extension")
            quit(1)
            return
        print("Archive backend unavailable on this platform")
        quit()
        return
    var fixture := DirAccess.create_temp("aether-archive-test")
    var root := fixture.get_current_dir()
    var games := root.path_join("Games")
    var inner := root.path_join("inner.zip")
    zip(inner, "Game/Game/game.exe", "launcher".to_utf8_buffer())
    var outer := root.path_join("outer.zip")
    zip(outer, "bundle.zip", FileAccess.get_file_as_bytes(inner))
    # The media sample's ZIP has optional ZIP64 end records, ordinary 32-bit
    # directory fields and a trailing payload outside its declared comment.
    var data := FileAccess.get_file_as_bytes(outer)
    var eocd := data.size() - 22
    var record := PackedByteArray()
    record.resize(76)
    record.encode_u32(0, 0x06064b50)
    record.encode_u64(4, 44)
    record.encode_u16(12, 45)
    record.encode_u16(14, 45)
    record.encode_u64(24, 1)
    record.encode_u64(32, 1)
    record.encode_u64(40, data.decode_u32(eocd + 12))
    record.encode_u64(48, data.decode_u32(eocd + 16))
    record.encode_u32(56, 0x07064b50)
    record.encode_u64(64, eocd)
    record.encode_u32(72, 1)
    var trailer := PackedByteArray()
    trailer.resize(20 * 1024)
    var carrier := root.path_join("video.mp4")
    write(carrier, "ftypisomMovie".to_utf8_buffer() + data.slice(0, eocd) + record + data.slice(eocd) + trailer)
    var reader: RefCounted = ClassDB.instantiate("AetherArchiveReader")
    check_plan(reader, root)
    var catalog: Dictionary = reader.inspect(carrier)
    check(catalog.status == OK and catalog.format == "ZIP" and catalog.entries == 1, "inspect wrapped ZIP64")
    var first: Dictionary = reader.extract_to(carrier, games, "")
    check(first.status == OK and first.destination == games.path_join("Game"), "flatten wrapped ZIP and repeated directory")
    check(FileAccess.get_file_as_string(games.path_join("Game/game.exe")) == "launcher", "published game root")
    var second: Dictionary = reader.extract_to(carrier, games, "")
    check(second.destination == games.path_join("Game (2)") and FileAccess.file_exists(carrier), "keep original and both games")
    var assets := root.path_join("assets.zip")
    zip(assets, "My VN/game/script.rpy", "label start:".to_utf8_buffer())
    var renpy: Dictionary = reader.extract_to(assets, games, "")
    check(renpy.destination == games.path_join("My VN") and FileAccess.file_exists(games.path_join("My VN/game/script.rpy")), "keep engine asset directory")
    var split := root.path_join("parts.zip")
    var parts := FileAccess.get_file_as_bytes(inner)
    var cut := floori(parts.size() / 3.0)
    write(split + ".001", parts.slice(0, cut))
    write(split + ".003", parts.slice(cut * 2))
    check(reader.inspect(split + ".003").status < 0, "detect missing intermediate volume")
    write(split + ".002", parts.slice(cut, cut * 2))
    var joined: Dictionary = reader.extract_to(split + ".002", games, "")
    check(joined.status == OK and joined.members.size() == 3 and FileAccess.file_exists(String(joined.destination).path_join("game.exe")), "open split archive from a middle volume")
    var imported: Dictionary = reader.copy_provider_file(inner, games, "Provider.zip")
    check(imported.status == OK and FileAccess.get_file_as_bytes(imported.destination) == parts, "stream provider document into Games")
    var copy: Dictionary = reader.copy_provider_file(inner, games, "Provider.zip")
    check(copy.destination == games.path_join("Provider (2).zip"), "keep provider name and extension on collision")
    write(root.path_join("plain.mp4"), "unrelated media".to_utf8_buffer())
    check(reader.inspect(root.path_join("plain.mp4")).status < 0, "reject plain media")
    reader.cancel()
    check(reader.extract_to(carrier, games, "").status == -9, "cancel without publishing a partial game")
    check(reader.copy_provider_file(inner, games, "cancelled.zip").status == -9 and not FileAccess.file_exists(games.path_join("cancelled.zip")), "interrupted provider copy stays unpublished")
    check(DirAccess.get_directories_at(games).size() == 4, "no temporary directory remains")
    print("ARCHIVE_IMPORT_TEST %d failures" % errors)
    quit(1 if errors else 0)
