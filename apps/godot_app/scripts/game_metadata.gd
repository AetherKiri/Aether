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
const RUNTIME_MAGES := "mages"
const RUNTIME_XSYSTEM4 := "xsystem4"
const RUNTIME_YURIS := "yuris"

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
    var hcb := _hcb_launch_file(root, path)
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
    elif (files.has("system40.ini") or files.has("alicestart.ini")) and _has_extension(files, "ain"):
        result.engine = RUNTIME_XSYSTEM4
        result.signals.append("system4-ain-ini")
    elif not hcb.is_empty():
        result.engine = RUNTIME_RFVP
        result.signals.append("fvp-hcb")
        result.launchFile = hcb
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
    elif files.has("yu-ris.exe") \
        or FileAccess.file_exists(root.path_join("data/script/system_start.yst")) \
        or FileAccess.file_exists(root.path_join("data/script/system_start.txt")) \
        or _is_compiled_yuris_package(root, files):
        # YU-RIS projects keep the Windows launcher beside the project data;
        # the portable provider consumes the project directory, not the PE
        # file itself.
        result.engine = RUNTIME_YURIS
        result.signals.append("yuris-marker")
        result.launchFile = "yu-ris.exe" if files.has("yu-ris.exe") else ""
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
    elif _is_mages_package(files):
        # MAGES PC releases carry MPK archives and a Windows launcher. The
        # launcher is not a readable storage file on iOS/macOS; pass the
        # directory to the embedded MAGES provider instead.
        result.engine = RUNTIME_MAGES
        result.signals.append("mages-mpk-marker")
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

static func _is_compiled_yuris_package(root: String, files: PackedStringArray) -> bool:
    # Retail launchers are named after the game. Recognize the compiler's
    # file signatures instead of requiring the SDK's yu-ris.exe filename.
    for relative_path in ["ysbin/yscfg.ybn", "ysbin/ysc.ybn", "yscfg.ybn", "ysc.ybn"]:
        var file := FileAccess.open(root.path_join(relative_path), FileAccess.READ)
        if file == null or file.get_length() < 16:
            continue
        var magic := file.get_buffer(4).get_string_from_ascii()
        if magic == "YSCF" or magic == "YSCM":
            return true
    # Native compiled distributions can place their archives in pac/. Limit
    # discovery to these two roots so a parent never adopts a sibling game.
    for pack_root in [root, root.path_join("pac")]:
        var entries := files if pack_root == root else _file_names(pack_root)
        for entry in entries:
            if entry.get_extension().to_lower() != "ypf":
                continue
            var file := FileAccess.open(pack_root.path_join(entry), FileAccess.READ)
            if file != null and file.get_length() >= 32 \
                and file.get_buffer(4) == PackedByteArray([89, 80, 70, 0]):
                return true
    return false

static func _hcb_launch_file(root: String, requested: String) -> String:
    var entries := hcb_launch_files(root)
    if FileAccess.file_exists(requested) and entries.has(requested.get_file()):
        return requested.get_file()
    for entry in entries:
        if not entry.begins_with("."):
            return entry
    return entries[0] if not entries.is_empty() else ""


static func hcb_launch_files(root: String) -> PackedStringArray:
    var result := PackedStringArray()
    var dir := DirAccess.open(root)
    if dir == null:
        return result
    dir.include_hidden = true
    var entries := dir.get_files()
    entries.sort()
    for entry in entries:
        if entry.get_extension().to_lower() != "hcb":
            continue
        var file := FileAccess.open(root.path_join(entry), FileAccess.READ)
        if file == null or file.get_length() < 17 or file.get_length() > 64 * 1024 * 1024:
            continue
        var descriptor := file.get_32()
        if descriptor < 4 or descriptor > file.get_length() - 13:
            continue
        file.seek(descriptor)
        var start := file.get_32()
        if start < 4 or start >= descriptor:
            continue
        file.get_16() # nonvolatile globals
        file.get_16() # volatile globals
        if file.get_8() > 15:
            continue
        file.get_8() # reserved mode byte
        var title_length := file.get_8()
        if file.get_position() + title_length + 4 > file.get_length():
            continue
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
            continue
        result.append(entry)
    return result


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


static func _is_mages_package(files: PackedStringArray) -> bool:
    # Require a distinguishing content archive so unrelated MPK-only
    # directories are not sent to the MAGES VM.
    return files.has("script.mpk") and files.has("system.mpk") and (
        files.has("bg1.mpk")
        or files.has("chara.mpk")
        or files.has("model.mpk")
    )

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
