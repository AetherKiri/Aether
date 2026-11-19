extends RefCounted
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
    return "%x" % hash_value if not scripts.is_empty() else ""

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

static func save_engine(host: Node, game: Dictionary) -> String:
    var engine := String(game.get("engine", ""))
    if engine.is_empty() or engine == "kirikiri":
        # Older QLIE entries can have the generic KiriKiri engine label.
        var detected: String = host._game_runtime_kind(String(game.get("path", "")))
        if engine.is_empty() or detected == "qlie":
            return detected
    return engine

static func game_root_save_dir(root: String, engine: String) -> String:
    return root.path_join("SaveData" if engine == "qlie" else "savedata")

static func qlie_save_dir(root: String, user_root: String = "") -> String:
    if root.is_empty():
        return ""
    root = ProjectSettings.globalize_path(root).simplify_path().trim_suffix("/")
    var local := game_root_save_dir(root, "qlie")
    if not DirAccess.dir_exists_absolute(root):
        return local
    var base := ProjectSettings.globalize_path("user://").trim_suffix("/") if user_root.is_empty() else user_root
    var identity := root
    if root.begins_with(base + "/"):
        identity = "user://" + root.substr(base.length() + 1)
    var fallback := base.path_join("qlie_saves").path_join(identity.sha256_text()).path_join("SaveData")
    return preload("res://scripts/game_save_storage.gd").with_writable_fallback(local, fallback)

static func resolve(root: String, engine: String, game: Dictionary, user_root: String = "") -> Dictionary:
    root = ProjectSettings.globalize_path(root).simplify_path().trim_suffix("/")
    var base := ProjectSettings.globalize_path("user://").trim_suffix("/") if user_root.is_empty() else user_root
    var local := qlie_save_dir(root, base) if engine == "qlie" else game_root_save_dir(root, engine)
    if local.is_empty():
        return {}
    var banks := {"main": _bank(local)}
    match engine:
        "renpy":
            var legacy: String = preload("res://scripts/renpy_save_storage.gd").legacy_storage_path(root)
            banks.main = _bank(_existing(local, legacy))
        "tyranoscript":
            var identity := root
            if identity.begins_with(base + "/"):
                identity = "user://" + identity.substr(base.length() + 1)
            banks.main = _bank(base.path_join("tyrano_saves").path_join(identity.sha256_text()), ["local_storage.json"])
        "yuris":
            banks.main = _bank(_existing(local, base.path_join("yuris").path_join(root.sha256_text())))
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
        "xsystem4", "xsystem35", "system3":
            var key := _script_identity(root, engine)
            if key.is_empty():
                return {}
            banks.main = _bank(base.path_join(engine).path_join(key))
        "softpal":
            # Private runtimes must expose their save-bank identity through a
            # host contract; do not duplicate their archive formats here.
            return {}
        "rfvp":
            var launch := String(game.get("launchFile", ""))
            if launch.is_empty():
                launch = preload("res://scripts/game_metadata.gd").hcb_launch_file(root)
            if launch.is_empty():
                return {}
            var script := launch if launch.is_absolute_path() else root.path_join(launch)
            var config := preload("res://scripts/game_text_config.gd").read(root, "rfvp", game)
            if config.error != OK:
                return {}
            var encoding: String = config.text.encoding
            var override_value := OS.get_environment("AETHERKIRI_RFVP_ENCODING").strip_edges().to_lower()
            if override_value in ["sjis", "gbk", "utf8"]:
                encoding = override_value
            var nls := "GBK" if encoding.to_upper() in ["GBK", "CP936"] else "UTF8" if encoding.to_upper() in ["UTF-8", "UTF8"] else "ShiftJIS"
            var bytes := root.to_utf8_buffer()
            bytes.append(0)
            bytes.append_array(script.to_utf8_buffer())
            bytes.append(0)
            bytes.append_array(nls.to_utf8_buffer())
            banks.main = _bank(base.path_join("rfvp").path_join("%016x" % _fnv(bytes)))
        "wa2":
            var files: Array = ["save_Q.sav"]
            for index in range(100):
                files.append("save_%02d.sav" % index)
            banks.main = _bank(root, files)
        "mages":
            var profile := _mages_profile(root)
            if profile.is_empty():
                return {}
            banks.main = _bank(base.path_join("saves").path_join(profile))
        "minori":
            # Older hosts used shared save roots. Those cannot be attributed to
            # the selected installation safely; don't export another title.
            return {}
    return banks
