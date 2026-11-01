extends SceneTree

const Storage := preload("res://scripts/renpy_save_storage.gd")

var failures := 0
var legacy_directories: Array[String] = []

func _expect(value: bool, message: String) -> void:
    if not value:
        failures += 1
        push_error(message)

func _write(path: String, contents: String) -> void:
    DirAccess.make_dir_recursive_absolute(path.get_base_dir())
    var file := FileAccess.open(path, FileAccess.WRITE)
    file.store_string(contents)

func _legacy(game: String) -> String:
    var path := Storage.legacy_storage_path(game)
    _expect(not DirAccess.dir_exists_absolute(path), "Fixture cannot touch an existing save bank")
    legacy_directories.append(path)
    return path

func _remove_tree(path: String) -> void:
    var directory := DirAccess.open(path)
    if directory == null:
        return
    directory.include_hidden = true
    for name in directory.get_files():
        DirAccess.remove_absolute(path.path_join(name))
    for name in directory.get_directories():
        _remove_tree(path.path_join(name))
    DirAccess.remove_absolute(path)

func _initialize() -> void:
    var fixture := DirAccess.create_temp("aether-renpy-storage")
    var base := fixture.get_current_dir()
    _check_legacy_identity()
    _check_migration(base)
    _check_existing_bank(base)
    _check_fallback_and_retry(base)
    for path in legacy_directories:
        _remove_tree(path)
    fixture = null
    print("RENPY_STORAGE_OK" if failures == 0 else "RENPY_STORAGE_FAILED")
    quit(0 if failures == 0 else 1)

func _check_legacy_identity() -> void:
    var base := ProjectSettings.globalize_path("user://renpy_saves")
    _expect(Storage.legacy_storage_path("/games/example") == base.path_join("/games/example".sha256_text()),
        "Find existing desktop saves with the original hash")
    _expect(Storage.legacy_storage_path(ProjectSettings.globalize_path("user://games/example")) == base.path_join("user://games/example".sha256_text()),
        "Retain the stable app-relative identity used on mobile")

func _check_migration(base: String) -> void:
    var game := base.path_join("日本語 中文")
    _write(game.path_join("game/script.rpy"), "original script")
    var legacy := _legacy(game)
    var bank := {
        "1-1-LT1.save": "signed save",
        "persistent": "read history and preferences",
        "security_keys.txt": "signing key",
        "sync": "save synchronization",
        "upgraded.txt": "format version",
        "_engine/compiled/script.rpyc": "statement identities",
        "_backup/1-1-LT1.save": "backup slot",
    }
    for name: String in bank:
        _write(legacy.path_join(name), bank[name])
    _write(game.path_join("savedata/.DS_Store"), "Finder metadata")
    var local := Storage.storage_path(game)
    _expect(local == game.path_join("savedata"), "Use the imported root, not its game subdirectory")
    for name: String in bank:
        _expect(FileAccess.get_file_as_string(local.path_join(name)) == bank[name], "Migrate the complete bank: " + name)
        _expect(FileAccess.get_file_as_string(legacy.path_join(name)) == bank[name], "Preserve the original: " + name)
    _expect(FileAccess.get_file_as_string(game.path_join("game/script.rpy")) == "original script", "Keep game resources intact")
    DirAccess.remove_absolute(local.path_join("1-1-LT1.save"))
    _expect(Storage.storage_path(game) == local, "Reuse the migrated bank")
    _expect(not FileAccess.file_exists(local.path_join("1-1-LT1.save")), "Do not resurrect deleted saves")
    var moved := base.path_join("relocated")
    _expect(DirAccess.rename_absolute(game, moved) == OK, "Move the game with its saves")
    _expect(Storage.storage_path(moved) == moved.path_join("savedata"), "Retain saves when the game moves")
    _expect(FileAccess.get_file_as_string(moved.path_join("savedata/security_keys.txt")) == bank["security_keys.txt"], "Signing keys travel with the saves")

func _check_existing_bank(base: String) -> void:
    var game := base.path_join("local-wins")
    var local := game.path_join("savedata")
    _write(local.path_join("1-1-LT1.save"), "new signed save")
    _write(local.path_join("security_keys.txt"), "new key")
    var legacy := _legacy(game)
    _write(legacy.path_join("1-1-LT1.save"), "old signed save")
    _write(legacy.path_join("security_keys.txt"), "old key")
    _write(legacy.path_join("2-1-LT1.save"), "signed with the old key")
    _expect(Storage.storage_path(game) == local, "An existing local bank is authoritative")
    _expect(FileAccess.get_file_as_string(local.path_join("1-1-LT1.save")) == "new signed save", "Do not overwrite local progress")
    _expect(FileAccess.get_file_as_string(local.path_join("security_keys.txt")) == "new key", "Do not replace local signing keys")
    _expect(not FileAccess.file_exists(local.path_join("2-1-LT1.save")), "Do not mix saves signed by different keys")

func _check_fallback_and_retry(base: String) -> void:
    var game := base.path_join("blocked")
    _write(game.path_join("savedata"), "file blocks the directory")
    _expect(Storage.storage_path(game) == Storage.legacy_storage_path(game), "An unwritable destination keeps the legacy store")
    var missing := base.path_join("missing")
    _expect(Storage.storage_path(missing) == Storage.legacy_storage_path(missing), "Missing games use isolated fallback")
    _expect(not DirAccess.dir_exists_absolute(missing), "Do not recreate a missing game")
    var retry := base.path_join("retry")
    var local := retry.path_join("savedata")
    var legacy := _legacy(retry)
    _write(legacy.path_join("1-1-LT1.save"), "complete slot")
    _write(legacy.path_join("security_keys.txt"), "original key")
    DirAccess.make_dir_recursive_absolute(local.path_join(Storage.MIGRATION_MARKER))
    _expect(Storage.storage_path(retry) == legacy, "Failed migration opens the intact original bank")
    _expect(not FileAccess.file_exists(local.path_join("1-1-LT1.save")), "Roll back incomplete migration")
    _expect(not FileAccess.file_exists(local.path_join("security_keys.txt")), "Roll back copied signing keys too")
    _expect(FileAccess.get_file_as_string(legacy.path_join("1-1-LT1.save")) == "complete slot", "Retain original saves after failure")
    DirAccess.remove_absolute(local.path_join(Storage.MIGRATION_MARKER))
    _expect(Storage.storage_path(retry) == local, "Retry migration after the obstruction is removed")
    _expect(FileAccess.get_file_as_string(local.path_join("security_keys.txt")) == "original key", "Retry restores the matching key")
