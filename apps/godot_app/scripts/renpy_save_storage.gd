extends RefCounted

const SaveStorage := preload("res://scripts/game_save_storage.gd")
const MIGRATION_MARKER := ".aether-renpy-migrated"

static func storage_path(root: String) -> String:
    # Move the complete bank, including signing keys, persistent data and
    # compiled statement identities used when restoring saves from loose RPY.
    return SaveStorage.prefer_local(root, legacy_storage_path(root), MIGRATION_MARKER)

static func legacy_storage_path(root: String) -> String:
    var identity := root.simplify_path()
    var user_root := ProjectSettings.globalize_path("user://").trim_suffix("/")
    if identity.begins_with(user_root + "/"):
        identity = "user://" + identity.substr(user_root.length() + 1)
    return ProjectSettings.globalize_path("user://renpy_saves").path_join(identity.sha256_text())
