class_name GameMetadata
extends RefCounted

const RUNTIME_KIRIKIRI := "kirikiri"
const RUNTIME_ONSCRIPTER := "onscripter"
const RUNTIME_RFVP := "rfvp"
const RUNTIME_ARTEMIS := "artemis"
const RUNTIME_SIGLUS := "siglus"
const RUNTIME_CATSYSTEM2 := "catsystem2"
const RUNTIME_TYRANO := "tyranoscript"
const RUNTIME_RENPY := "renpy"
const GBK_COMMON_PAIRS := [0xb5c4, 0xcac7, 0xb2bb, 0xced2, 0xc1cb, 0xd4da, 0xd3d0, 0xc8cb]

static func inspect(path: String) -> Dictionary:
    var root := path
    if FileAccess.file_exists(root):
        root = root.get_base_dir()
    var result := {
        "engine": RUNTIME_KIRIKIRI,
        "title": "",
        "titleCandidates": PackedStringArray(),
        "launchFile": "",
        "signals": PackedStringArray(),
    }
    if root.is_empty() or not DirAccess.dir_exists_absolute(root):
        return result

    var candidates: PackedStringArray = []
    var files := _file_names(root)
    var tyrano_entry := tyrano_entry_file(root)
    var renpy_directory := renpy_game_directory(root)
    var hcb := _hcb_launch_profile(root, path)
    if not tyrano_entry.is_empty():
        result.engine = RUNTIME_TYRANO
        result.launchFile = tyrano_entry
        result.signals.append("tyranoscript-web-project")
        var config := _read_text(root.path_join(tyrano_entry).get_base_dir().path_join("data/system/Config.tjs"))
        var title_pattern := RegEx.new()
        title_pattern.compile('(?m)^\\s*;?System\\.title\\s*=\\s*"([^"\\r\\n]+)"')
        var title_match := title_pattern.search(config)
        if title_match != null:
            candidates.append(title_match.get_string(1))
    elif not renpy_directory.is_empty():
        result.engine = RUNTIME_RENPY
        result.signals.append("renpy-game-directory")
        var options := _read_text(root.path_join(renpy_directory).path_join("options.rpy"))
        var pattern := RegEx.new()
        pattern.compile('(?m)^\\s*define\\s+config\\.name\\s*=\\s*_?\\(?\\s*"([^"\\r\\n]+)"')
        var title_match := pattern.search(options)
        if title_match != null:
            candidates.append(title_match.get_string(1))
    elif not hcb.is_empty():
        result.engine = RUNTIME_RFVP
        result.signals.append("fvp-hcb")
        result.merge(hcb, true)
    elif (
        files.has("0.txt")
        or files.has("00.txt")
        or files.has("nscr_sec.dat")
        or files.has("nscript.___")
        or files.has("nscript.dat")
        or _has_prefix(files, "onscript.nt")
    ):
        result.engine = RUNTIME_ONSCRIPTER
        result.signals.append("onscript-marker")
    elif _is_catsystem2_package(files):
        # CatSystem2 titles commonly ship a Windows launcher beside loose or
        # packed INT resources.  Keep the directory as the launch path so the
        # provider can mount those resources instead of sending cs2.exe to
        # the legacy KiriKiri storage layer.
        result.engine = RUNTIME_CATSYSTEM2
        result.signals.append("catsystem2-marker")
    elif files.has("system.ini") and _is_artemis_package(
        files,
        _read_text(root.path_join("system.ini"))
    ):
        result.engine = RUNTIME_ARTEMIS
        result.signals.append("artemis-system-ini")
        var ini := _read_text(root.path_join("system.ini"))
        if (
            _has_extension(files, "pfs")
            and _value_after(ini, "BOOT").to_lower().ends_with(".iet")
        ):
            result.signals.append("artemis-pfs-boot")
        var save_path := _value_after(ini, "SAVEPATH")
        if not save_path.is_empty():
            candidates.append(save_path.replace("\\\\", "/").get_file())
    elif _has_extension(files, "pfs") and not _has_extension(files, "xp3"):
        # A number of Artemis releases keep system.ini inside root.pfs rather
        # than beside the archive.  There is no loose marker for the metadata
        # scanner to read, but PF archives are an engine-specific container;
        # classify the directory as Artemis so the launcher passes the game
        # root to the provider instead of handing Untei.exe to KiriKiri.
        result.engine = RUNTIME_ARTEMIS
        result.signals.append("artemis-pfs-archive")
    elif (
        files.has("gameexe.ini")
        or files.has("gameexe.dat")
        or files.has("scene.pck")
    ):
        result.engine = RUNTIME_SIGLUS
        result.signals.append("siglus-marker")
    else:
        result.signals.append("kirikiri-xp3-or-default")

    if result.engine == RUNTIME_KIRIKIRI:
        var launch := _first_file(root, [".exe", ".xp3"])
        if not launch.is_empty():
            result.launchFile = launch
    for marker in ["README.md", "title.ini", "title.ks", "startup.tjs", "config.tjs"]:
        var marker_path := root.path_join(marker)
        if FileAccess.file_exists(marker_path):
            var text := _read_text(marker_path)
            candidates.append_array(_extract_title_candidates(text))
            result.signals.append("content:" + marker)
    candidates.append_array(_title_from_path(root))
    candidates = _unique_nonempty(candidates)
    result.titleCandidates = candidates
    if not candidates.is_empty():
        result.title = candidates[0]
    return result

static func tyrano_entry_file(root: String) -> String:
    # A normal HTML export and an unpacked Electron export both carry their
    # own engine. An arbitrary index.html must not be classified as Tyrano.
    for relative in ["index.html", "resources/app/index.html", "app/index.html"]:
        var directory := root.path_join(relative).get_base_dir()
        if (
            FileAccess.file_exists(root.path_join(relative))
            and FileAccess.file_exists(directory.path_join("tyrano/tyrano.js"))
            and FileAccess.file_exists(directory.path_join("tyrano/plugins/kag/kag.js"))
            and FileAccess.file_exists(directory.path_join("data/system/Config.tjs"))
        ):
            return relative
    return ""

static func renpy_game_directory(root: String) -> String:
    for relative in ["game", "Contents/Resources/autorun/game", "."]:
        var directory := root.path_join(relative)
        if _has_renpy_scripts(directory, 3 if relative != "." or root.get_file().to_lower() == "game" else 0):
            return relative
    return ""

static func _has_renpy_scripts(root: String, depth: int) -> bool:
    var directory := DirAccess.open(root)
    if directory == null:
        return false
    for name in directory.get_files():
        var extension := name.get_extension().to_lower()
        if extension == "rpy":
            return true
        if extension not in ["rpyc", "rpa"]:
            continue
        var file := FileAccess.open(root.path_join(name), FileAccess.READ)
        if file == null:
            continue
        var signature := file.get_buffer(10).get_string_from_ascii()
        if (extension == "rpyc" and signature.begins_with("RENPY RPC2")) or (extension == "rpa" and (signature.begins_with("RPA-3.0 ") or signature.begins_with("RPA-2.0 "))):
            return true
    if depth > 0:
        for name in directory.get_directories():
            if name in ["cache", "saves", "savedata", "renpy", "lib", ".git"] or directory.is_link(name):
                continue
            if _has_renpy_scripts(root.path_join(name), depth - 1):
                return true
    return false

static func _hcb_launch_profile(root: String, requested: String) -> Dictionary:
    var dir := DirAccess.open(root)
    if dir == null:
        return {}
    dir.include_hidden = true
    var entries := dir.get_files()
    entries.sort()
    var valid := {}
    for entry in entries:
        if entry.get_extension().to_lower() == "hcb":
            var end := _hcb_descriptor_end(root.path_join(entry))
            if end >= 0:
                valid[entry] = end
    if valid.is_empty():
        return {}
    # An explicitly selected file always wins over automatic patch selection.
    if FileAccess.file_exists(requested) and valid.has(requested.get_file()):
        return _hcb_profile(root, requested.get_file(), valid[requested.get_file()])
    for entry in valid:
        if entry.begins_with(".") or not valid.has("." + entry):
            continue
        var patch: String = "." + entry
        var original_end: int = valid[entry]
        if original_end != int(valid[patch]):
            continue
        var original := FileAccess.open(root.path_join(entry), FileAccess.READ)
        var translated := FileAccess.open(root.path_join(patch), FileAccess.READ)
        var descriptor := original.get_32()
        if translated.get_32() != descriptor:
            continue
        original.seek(descriptor)
        translated.seek(descriptor)
        # Translation overlays retain the original descriptor and append VM
        # strings. Neither a dot filename nor the folder language proves GBK.
        if original.get_buffer(original_end - descriptor) != translated.get_buffer(original_end - descriptor):
            continue
        if _hcb_has_gbk_overlay(root.path_join(patch), original_end):
            return {"launchFile": patch, "rfvpEncoding": "gbk"}
    for entry in valid:
        if not entry.begins_with("."):
            return _hcb_profile(root, entry, valid[entry])
    var fallback: String = valid.keys()[0]
    return _hcb_profile(root, fallback, valid[fallback])


static func _hcb_profile(root: String, entry: String, descriptor_end: int) -> Dictionary:
    return {
        "launchFile": entry,
        "rfvpEncoding": "gbk" if _hcb_has_gbk_overlay(root.path_join(entry), descriptor_end) else "sjis",
    }


static func _hcb_has_gbk_overlay(path: String, descriptor_end: int) -> bool:
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null or file.get_length() <= descriptor_end:
        return false
    file.seek(descriptor_end)
    var bytes := file.get_buffer(mini(256 * 1024, file.get_length() - descriptor_end))
    var common := 0
    var kana := 0
    var multibyte := 0
    var strings := 0
    var cursor := 0
    while cursor + 3 < bytes.size():
        if bytes[cursor] != 0x0e: # VM push_string: opcode, length, NUL-terminated bytes
            cursor += 1
            continue
        var length: int = bytes[cursor + 1]
        var end := cursor + 2 + length
        if length < 5 or end > bytes.size() or bytes[end - 1] != 0:
            cursor += 1
            continue
        var text := bytes.slice(cursor + 2, end - 1)
        var hits := 0
        var pairs := 0
        var hiragana := 0
        var index := 0
        var valid := true
        while index < text.size():
            var lead: int = text[index]
            if lead < 0x80:
                index += 1
                continue
            if index + 1 >= text.size():
                valid = false
                break
            var trail: int = text[index + 1]
            if lead < 0x81 or lead > 0xfe or trail < 0x40 or trail > 0xfe or trail == 0x7f:
                valid = false
                break
            # Common simplified Chinese characters: 的 是 不 我 了 在 有 人.
            if ((lead << 8) | trail) in GBK_COMMON_PAIRS:
                hits += 1
            if lead == 0x82 and trail >= 0x9f and trail <= 0xf1:
                hiragana += 1
            pairs += 1
            index += 2
        if valid:
            common += hits
            kana += hiragana
            multibyte += pairs
            strings += 1
        cursor = end
    return strings >= 4 and multibyte >= 32 and common >= 12 and kana * 4 < common


static func _hcb_descriptor_end(path: String) -> int:
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null or file.get_length() < 17 or file.get_length() > 64 * 1024 * 1024:
        return -1
    var descriptor := file.get_32()
    if descriptor < 4 or descriptor > file.get_length() - 13:
        return -1
    file.seek(descriptor)
    var start := file.get_32()
    if start < 4 or start >= descriptor:
        return -1
    file.get_16() # nonvolatile globals
    file.get_16() # volatile globals
    if file.get_8() > 15:
        return -1
    file.get_8() # reserved mode byte
    var title_length := file.get_8()
    if file.get_position() + title_length + 4 > file.get_length():
        return -1
    file.seek(file.get_position() + title_length)
    var syscall_count := file.get_16()
    var valid := true
    for _index in range(syscall_count):
        if file.get_position() + 2 > file.get_length():
            valid = false
            break
        file.get_8() # argument count
        var name_length := file.get_8()
        if file.get_position() + name_length + 2 > file.get_length():
            valid = false
            break
        file.seek(file.get_position() + name_length)
    if not valid or file.get_position() + 2 > file.get_length():
        return -1
    return file.get_position() + 2


static func _file_names(root: String) -> PackedStringArray:
    var result: PackedStringArray = []
    var dir := DirAccess.open(root)
    if dir == null:
        return result
    dir.list_dir_begin()
    var entry := dir.get_next()
    while not entry.is_empty():
        if not dir.current_is_dir():
            result.append(entry.to_lower())
        entry = dir.get_next()
    dir.list_dir_end()
    return result

static func _first_file(root: String, extensions: Array) -> String:
    var dir := DirAccess.open(root)
    if dir == null:
        return ""
    var executable_fallback := ""
    var archive_fallback := ""
    dir.list_dir_begin()
    var entry := dir.get_next()
    while not entry.is_empty():
        if not dir.current_is_dir():
            var lower := entry.to_lower()
            if extensions.has("." + lower.get_extension()):
                # A KiriKiri Windows executable is not a readable storage
                # file on macOS/iOS. Prefer the game's data archive whenever
                # both a launcher and an XP3 archive are present.
                if lower == "data.xp3":
                    dir.list_dir_end()
                    return entry
                if lower.ends_with(".xp3"):
                    if archive_fallback.is_empty():
                        archive_fallback = entry
                elif executable_fallback.is_empty():
                    executable_fallback = entry
        entry = dir.get_next()
    dir.list_dir_end()
    if not archive_fallback.is_empty():
        return archive_fallback
    return executable_fallback

static func _has_prefix(values: PackedStringArray, prefix: String) -> bool:
    for value in values:
        if value.begins_with(prefix):
            return true
    return false

static func _has_extension(values: PackedStringArray, extension: String) -> bool:
    var normalized := extension.to_lower().trim_prefix(".")
    for value in values:
        if value.get_extension() == normalized:
            return true
    return false

static func _is_artemis_package(files: PackedStringArray, ini: String) -> bool:
    if ini.findn("Artemis") >= 0:
        return true
    var boot := _value_after(ini, "BOOT").replace("\\", "/")
    return _has_extension(files, "pfs") and boot.to_lower().ends_with(".iet")

static func _is_catsystem2_package(files: PackedStringArray) -> bool:
    var has_int := _has_extension(files, "int")
    var has_cs2_executable := files.has("cs2.exe")
    var has_cs2_config := files.has("cs2confx.dll")
    var has_boot_descriptor := files.has("boot.dfn")
    var has_kcs_script := files.has("kcs.int")
    if has_cs2_executable and (has_int or has_boot_descriptor):
        return true
    if has_cs2_config and has_boot_descriptor and has_kcs_script:
        return true
    return has_boot_descriptor and has_kcs_script and has_int

static func _read_text(path: String) -> String:
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null or file.get_length() > 1024 * 1024:
        return ""
    return file.get_as_text()

static func _value_after(text: String, key: String) -> String:
    for line in text.split("\n"):
        var trimmed := line.strip_edges()
        var equals := trimmed.find("=")
        if equals >= 0 and trimmed.left(equals).strip_edges().to_upper() == key.to_upper():
            return trimmed.substr(equals + 1).strip_edges()
    return ""

static func _extract_title_candidates(text: String) -> PackedStringArray:
    var result: PackedStringArray = []
    for line in text.split("\n"):
        var value := line.strip_edges()
        if value.begins_with("#") or value.begins_with(";") or value.length() < 3:
            continue
        for key in ["title", "name", "game", "product"]:
            if value.to_lower().begins_with(key + "="):
                var candidate := value.substr(value.find("=") + 1).strip_edges()
                if candidate.length() >= 3 and candidate.length() <= 160:
                    result.append(candidate)
    return result

static func _title_from_path(root: String) -> PackedStringArray:
    var result: PackedStringArray = []
    var name := root.get_file().replace("_aetherkiri", "").strip_edges()
    if not name.is_empty():
        result.append(name)
    return result

static func _unique_nonempty(values: PackedStringArray) -> PackedStringArray:
    var result: PackedStringArray = []
    var seen := {}
    for value in values:
        var normalized := value.strip_edges()
        if normalized.is_empty() or seen.has(normalized):
            continue
        seen[normalized] = true
        result.append(normalized)
    return result
