extends RefCounted

const SaveStorage := preload("res://scripts/game_save_storage.gd")
const LaunchEntry := preload("res://scripts/game_launch_entry.gd")
const LOCAL_WRITABLE_RUNTIMES := ["system3", "xsystem35", "xsystem4", "mages", "minori"]
## Keep this mapping aligned with runtime storage contracts. Never scan the
## whole application user directory: it contains other games and credentials.

static func _bank(path: String, files: Array = []) -> Dictionary:
    return {"path": path, "files": files, "exclude": ["cache", "font-faces"]}

static func _existing(primary: String, fallback: String) -> String:
    return fallback if not DirAccess.dir_exists_absolute(primary) and DirAccess.dir_exists_absolute(fallback) else primary

static func _fnv(bytes: PackedByteArray, seed: int = -3750763034362895579) -> int:
    var value := seed
    for byte in bytes:
        value = (value ^ byte) * 1099511628211
    return value

static func _hex64(value: int, padded: bool = true) -> String:
    # Godot integers are signed; the native identities are unsigned uint64_t.
    var hex := "%08x%08x" % [(value >> 32) & 0xffffffff, value & 0xffffffff]
    if padded:
        return hex
    hex = hex.lstrip("0")
    return "0" if hex.is_empty() else hex

static func _script_identity(root: String, engine: String) -> String:
    var directory := DirAccess.open(root)
    if directory == null:
        return ""
    var scripts: Array[String] = []
    for name in directory.get_files():
        var lower := name.to_lower()
        var match_script := lower.ends_with(".ain") if engine == "xsystem4" else \
            lower in ["adisk.dat", "gdisk.dat", "agame.dat", "adisk.pat"] if engine == "system3" else \
            lower == "adisk.ald" or lower.ends_with("sa.ald")
        if match_script and not directory.is_link(name):
            scripts.append(name)
    scripts.sort_custom(func(a: String, b: String): return a.to_lower() < b.to_lower())
    var hash_value := -3750763034362895579
    for name in scripts:
        var file := FileAccess.open(root.path_join(name), FileAccess.READ)
        if file == null:
            return ""
        hash_value = _fnv(name.to_lower().to_utf8_buffer(), hash_value)
        hash_value = _fnv(str(file.get_length()).to_utf8_buffer(), hash_value)
        hash_value = _fnv(file.get_buffer(mini(65536, file.get_length())), hash_value)
        file.close()
    return _hex64(hash_value, false) if not scripts.is_empty() else ""

static func _mages_profile(root: String) -> String:
    # Match the public MAGES host's DetectGameRoot order and archive checks.
    var profiles := [
        ["chlcc", "script.cpk", "system.cpk", "script.cpk"],
        ["darling", "script.cls", "system.cpk", ""],
        ["rne", "script.cls", "system.cpk", "model.cpk"],
        ["cclcc", "script", "system.mpk", "bgeffect.mpk"],
        ["dash", "script.cls", "system.cls", "model.cls"],
        ["mo6tw", "script.cls", "system.cpk", ""],
        ["mo8", "script.mpk", "system.mpk", "bg1.mpk"],
    ]
    var directory := DirAccess.open(root)
    if directory == null:
        return ""
    var children := Array(directory.get_directories())
    children.sort()
    var folders: Array = [root]
    for profile in profiles:
        for child: String in children:
            if child.to_lower() == profile[0] and not directory.is_link(child):
                folders.append(root.path_join(child))
    for child: String in children:
        if not directory.is_link(child) and root.path_join(child) not in folders:
            folders.append(root.path_join(child))
    for folder: String in folders:
        var entries := DirAccess.open(folder)
        if entries == null:
            continue
        var names: Array = []
        for entry in Array(entries.get_files()) + Array(entries.get_directories()):
            names.append(String(entry).to_lower())
        for profile in profiles:
            if folder.get_file().to_lower() == profile[0] and (profile[1] in names or profile[2] in names):
                return profile[0]
        for profile in profiles:
            if not String(profile[3]).is_empty() and profile[1] in names and profile[2] in names and profile[3] in names:
                return profile[0]
    return ""

static func systemnnn_user_directory(base: String, root: String) -> String:
    var normalized := ProjectSettings.globalize_path(root).simplify_path().trim_suffix("/")
    return base.path_join("systemnnn_games").path_join(normalized.sha256_text())

static func _native_bank(root: String, engine: String, base: String) -> Dictionary:
    match engine:
        "system3", "xsystem35", "xsystem4":
            var key := _script_identity(root, engine)
            if not key.is_empty():
                var bank := engine.path_join(key)
                return {"bank": "savedata".path_join(bank), "legacy": base.path_join(bank), "writable": "savedata"}
        "mages":
            var profile := _mages_profile(root)
            if not profile.is_empty():
                var bank := "saves".path_join(profile)
                return {"bank": "savedata/mages".path_join(bank), "legacy": base.path_join(bank), "writable": "savedata/mages"}
        "minori":
            # The legacy files have no reliable installation identity. Never
            # expose the shared application-wide bank as this game's saves.
            return {"bank": "savedata/minori", "legacy": "", "writable": "savedata/minori"}
    return {}

static func prepare_native_writable_root(root: String, engine: String, base: String) -> Dictionary:
    root = ProjectSettings.globalize_path(root).simplify_path().trim_suffix("/")
    var layout := _native_bank(root, engine, base)
    if layout.is_empty():
        return {"path": "", "error": "Cannot identify the %s save bank for %s" % [engine, root]}
    var bank := SaveStorage.require_local_bank(root, layout.bank, layout.legacy, {}, ["cache", "font-faces"])
    if not String(bank.error).is_empty():
        return bank
    var writable := root.path_join(String(layout.writable))
    # Impacto also creates host-generated configuration beside its saves.
    if engine == "mages" and not SaveStorage._safe_local_bank(writable):
        return {"path": "", "error": "Unsafe MAGES writable directory: " + writable}
    return {"path": writable, "error": ""}

static func _minori_legacy_files(base: String) -> Dictionary:
    var dir := DirAccess.open(base)
    if dir == null or dir.is_link("save"):
        return {}
    var slots := DirAccess.open(base.path_join("save"))
    if slots == null:
        return {}
    var selection := {}
    for index in range(1, 11):
        var name := "slot-%02d.sav" % index
        if not slots.file_exists(name) or slots.is_link(name):
            continue
        var file := FileAccess.open(base.path_join("save").path_join(name), FileAccess.READ)
        if file != null and file.get_buffer(8).get_string_from_ascii() == "MINORISV":
            selection[name] = [name]
    if selection.is_empty():
        return {}
    # This identifies the format, not the title. The user still needs to
    # confirm that this shared bank belongs to the selected installation.
    return {"system.dat": ["system.dat"], "save": selection}

static func has_minori_legacy() -> bool:
    return not _minori_legacy_files(OS.get_user_data_dir()).is_empty()

static func recover_minori_legacy(root: String, base: String) -> Dictionary:
    var files := _minori_legacy_files(base)
    if files.is_empty():
        return {"path": "", "error": "No identifiable Minori legacy slots"}
    return SaveStorage.require_local_bank(root, "savedata/minori", base, files, [], true)

static func prepare_wa2_flags(root: String, base: String) -> Dictionary:
    return SaveStorage.require_local_bank(root, "savedata/wa2", base.path_join("wa2"),
        {"sysflags.bin": ["sysflags.bin"]})

static func tyrano_legacy_directory(root: String, user_root: String) -> String:
    var identity := root.simplify_path().trim_suffix("/")
    if identity.begins_with(user_root + "/"):
        identity = "user://" + identity.substr(user_root.length() + 1)
    return user_root.path_join("tyrano_saves").path_join(identity.sha256_text())

static func prepare_tyrano(root: String, user_root: String = "") -> Dictionary:
    var base := ProjectSettings.globalize_path("user://").trim_suffix("/") if user_root.is_empty() else user_root
    # Android AtomicFile treats .bak as the last committed value. Never
    # promote an unfinished .new file or copy the rest of the WebView data.
    return preload("res://scripts/game_save_storage.gd").require_local_bank(
        root, "savedata/tyranoscript", tyrano_legacy_directory(root, base),
        {"local_storage.json": ["local_storage.json.bak", "local_storage.json"]})

# Resolve links before hashing, as the RFVP host does for a selected HCB.
# Resolve the parent first so relative link targets and ".." are interpreted
# from the actual directory, not the spelling of the path used to reach it.
static func _rfvp_resolve_path(path: String, links_left: int = 40) -> String:
    var parent := path.get_base_dir()
    if parent.is_empty() or parent == path or path.get_file().is_empty():
        return path
    parent = _rfvp_resolve_path(parent, links_left)
    if parent.is_empty():
        return ""
    var name := path.get_file()
    if name == ".":
        return parent
    if name == "..":
        return parent.get_base_dir()
    var directory := DirAccess.open(parent)
    if directory == null:
        return ""
    if not directory.is_link(name):
        return parent.path_join(name)
    if links_left == 0:
        return ""
    var target := directory.read_link(name)
    if target.is_empty():
        return ""
    return _rfvp_resolve_path(target if target.is_absolute_path() else parent.path_join(target), links_left - 1)

static func _rfvp_bank(root: String, game: Dictionary, base: String) -> Dictionary:
    var launch := String(game.get("startupScript", "")).strip_edges()
    if launch.is_empty():
        launch = String(game.get("launchFile", ""))
    if launch.is_empty() or not launch.get_extension().to_lower() == "hcb":
        launch = preload("res://scripts/game_metadata.gd").hcb_launch_file(root)
    if launch.is_empty():
        return {}
    var script := (launch if launch.is_absolute_path() else root.path_join(launch)).simplify_path()
    if not script.begins_with(root + "/") or not FileAccess.file_exists(script):
        return {}
    var resolved_root := _rfvp_resolve_path(root)
    script = _rfvp_resolve_path(script)
    if resolved_root.is_empty() or not script.begins_with(resolved_root + "/") \
            or script.get_extension().to_lower() != "hcb" or not FileAccess.file_exists(script):
        return {}
    var config := preload("res://scripts/game_text_config.gd").read(root, "rfvp", game)
    if config.error != OK:
        return {}
    var override_value := OS.get_environment("AETHERKIRI_RFVP_ENCODING")
    if not String(config.document.get("text", {}).get("encoding", "")).is_empty():
        override_value = "" # Native Open gives the explicit game setting priority.
    var encoding := LaunchEntry.rfvp_encoding({LaunchEntry.RFVP_ENCODING_FIELD: config.text.encoding}, override_value)
    var nls: String = LaunchEntry.RFVP_SAVE_NLS[encoding]
    var portable := PackedByteArray([0])
    portable.append_array(script.substr(resolved_root.length() + 1).to_utf8_buffer())
    portable.append(0)
    portable.append_array(nls.to_utf8_buffer())
    var legacy := resolved_root.to_utf8_buffer()
    legacy.append(0)
    legacy.append_array(script.to_utf8_buffer())
    legacy.append(0)
    legacy.append_array(nls.to_utf8_buffer())
    return {"local": root.path_join("savedata/rfvp").path_join(_hex64(_fnv(portable))),
        "legacy": base.path_join("rfvp").path_join(_hex64(_fnv(legacy)))}

static func _migrated_bank(local: String, legacy: String, for_write: bool, files: Array = []) -> Dictionary:
    if not for_write and not legacy.is_empty():
        local = _existing(local, legacy)
    return _bank(local, files)

# Before replacing matching files from a remote archive, bring the existing
# bank forward so that other local slots are not hidden or left behind.
static func prepare_import(root: String, engine: String, game: Dictionary, base: String) -> String:
    if engine in LOCAL_WRITABLE_RUNTIMES:
        return String(prepare_native_writable_root(root, engine, base).error)
    match engine:
        "tyranoscript":
            return String(prepare_tyrano(root, base).error)
        "wa2":
            return String(prepare_wa2_flags(root, base).error)
        "softpal", "rfvp":
            var bank := resolve(root, engine, game, base, true)
            if bank.is_empty() or not DirAccess.dir_exists_absolute(String(bank.main.path)):
                # Let the provider migrate its own bank before creating any
                # files that could make it look like migration already ran.
                return "launch_required"
            if not SaveStorage.is_existing_local_bank(root, String(bank.main.path)):
                return "Unsafe game-local save directory: " + String(bank.main.path)
    return ""

static func resolve(root: String, engine: String, game: Dictionary, user_root: String = "", for_write: bool = false) -> Dictionary:
    root = ProjectSettings.globalize_path(root).simplify_path().trim_suffix("/")
    var base := ProjectSettings.globalize_path("user://").trim_suffix("/") if user_root.is_empty() else user_root
    var local := root.path_join("savedata")
    var banks := {"main": _bank(local)}
    match engine:
        "renpy":
            var legacy: String = preload("res://scripts/renpy_save_storage.gd").legacy_storage_path(root)
            banks.main = _bank(_existing(local, legacy))
        "tyranoscript":
            banks.main = _migrated_bank(local.path_join("tyranoscript"), tyrano_legacy_directory(root, base), for_write, ["local_storage.json"])
        "yuris":
            banks.main = _bank(_existing(local, base.path_join("yuris").path_join(root.sha256_text())))
        "systemnnn":
            banks.main = _bank(systemnnn_user_directory(base, root).path_join("systemnnn"))
        "systemc":
            var legacy := base.path_join("systemc_games").path_join(root.sha256_text().left(24)).path_join("systemc")
            banks.main = _bank(_existing(local, legacy))
        "siglus":
            if DirAccess.dir_exists_absolute(root.path_join("save_chs")):
                banks.main = _bank(root.path_join("save_chs"))
        "onscripter":
            var safe := ""
            for byte in root.get_file().to_utf8_buffer():
                safe += String.chr(byte) if (byte >= 48 and byte <= 57) or (byte >= 65 and byte <= 90) or (byte >= 97 and byte <= 122) or byte in [45, 95] else "_"
            var key := safe + "-%016x" % _fnv(root.to_utf8_buffer(), 1469598103934665603)
            banks.main = _bank(_existing(local, base.path_join("onscripter_saves").path_join(key)))
        "catsystem2":
            var key := "%016x" % _fnv(root.to_utf8_buffer(), 1469598103934665603)
            banks.main = _bank(_existing(local, base.path_join("catsystem2/savedata").path_join(key)))
        "bgi":
            banks.main = _bank(_existing(local, base.path_join("bgi").path_join("%x" % _fnv(root.to_utf8_buffer()))))
        "xsystem4", "xsystem35", "system3", "mages", "minori":
            var layout := _native_bank(root, engine, base)
            if layout.is_empty():
                return {}
            var bank := root.path_join(String(layout.bank))
            var legacy := String(layout.legacy)
            banks.main = _migrated_bank(bank, legacy, for_write)
        "flash":
            # Explicit localPath scopes can be shared by SWFs in one folder.
            # There is no safe single-movie archive of a folder-wide bank.
            return {}
        "softpal":
            banks.main = _bank(local.path_join("softpal"))
        "rfvp":
            var rfvp := _rfvp_bank(root, game, base)
            if rfvp.is_empty():
                return {}
            banks.main = _migrated_bank(rfvp.local, rfvp.legacy, for_write)
        "wa2":
            var files: Array = ["save_Q.sav"]
            for index in range(100):
                files.append("save_%02d.sav" % index)
            banks.main = _bank(root, files)
            banks.flags = _migrated_bank(local.path_join("wa2"), base.path_join("wa2"), for_write, ["sysflags.bin"])
    return banks
