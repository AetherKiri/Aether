extends SceneTree

const Main = preload("res://scripts/main.gd")
const Metadata = preload("res://scripts/game_metadata.gd")
const FileLibrary = preload("res://scripts/video_library.gd")

class ScoredProvider extends RefCounted:
    var scores: Dictionary
    var calls := 0

    func probe_runtime(id: String, _root: String) -> int:
        calls += 1
        return int(scores.get(id, -1))

var fixture: DirAccess
var failures := 0
var checked := 0
var player: Node


func _initialize() -> void:
    if not ClassDB.class_exists("AetherRuntimePlayer"):
        printerr("game detection parity requires the native extension")
        quit(1)
        return
    player = ClassDB.instantiate("AetherRuntimePlayer") as Node
    fixture = DirAccess.create_temp("aether-game-detection")
    if fixture == null:
        printerr("cannot create detection fixtures")
        player.free()
        quit(1)
        return

    var cases := [
        ["empty", "kirikiri", {}],
        ["launcher-only", "kirikiri", {"Game.EXE": ""}],
        ["xp3-enumeration", "kirikiri", {"last.xp3": "", "first.xp3": "", "launcher.exe": ""}],
        ["xp3-preference", "kirikiri", {"launch.exe": "", "patch.xp3": "", "DATA.XP3": ""}],
        ["loose-scripts", "kirikiri", {"data/Startup.tjs": "", "data.xp3": "", "README.md": "title=Loose fixture"}],
        ["systemnnn", "systemnnn", {"spt/sys.spt": "", "game.exe": ""}],
        ["systemnnn-case", "systemnnn", {"SpT/SYS.SPT": "", "game.exe": ""}, "game.exe"],
        ["systemnnn-unrelated-script", "kirikiri", {"spt/intro.spt": ""}],
        ["ons-plain", "onscripter", {"0.txt": ""}],
        ["ons-alt", "onscripter", {"00.txt": ""}],
        ["ons-sec", "onscripter", {"NSCR_SEC.DAT": ""}],
        ["ons-encoded", "onscripter", {"nscript.___": ""}],
        ["ons-data", "onscripter", {"nscript.dat": "", "data.xp3": ""}],
        ["ons-prefix", "onscripter", {"OnScript.NT3": "", "Gameexe.ini": ""}],
        ["system4", "xsystem4", {"SYSTEM40.INI": "", "game.AIN": "", "somethingSA.ALD": "", "0.txt": ""}],
        ["system4-chs", "xsystem4", {"AliceStart.CHS": "", "CHS.TBL": "", "story.CHS": ""}],
        ["system4-haru", "xsystem4", {"AliceStart2.ini": "", "haru_c.ain": ""}],
        ["system4-ali", "xsystem4", {"AliceStart.INI": "", "game.AIN": ""}],
        ["system4-incomplete", "kirikiri", {"game.AIN": ""}],
        ["system35-scenario", "xsystem35", {"packSA.ALD": "", "adisk.dat": "", "acg.dat": ""}],
        ["system35-adisk", "xsystem35", {"ADISK.ALD": ""}],
        ["system3", "system3", {"ADISK.DAT": "", "ACG.DAT": "", "0.txt": ""}],
        ["system3-gdisk", "system3", {"gdisk.dat": "", "gcg.dat": ""}],
        ["system3-agame", "system3", {"agame.dat": "", "acg.dat": ""}],
        ["system3-pat", "system3", {"adisk.pat": "", "acg.dat": ""}],
        ["system3-incomplete", "kirikiri", {"adisk.dat": ""}],
        ["cmvs", "cmvs", {"data/pack/script.cpz": "CPZ6", "data/pack/start.ps3": "PS2A", "0.txt": ""}],
        ["cmvs-ps2", "cmvs", {"data/pack/script.cpz": "CPZ6", "data/pack/start.ps2": "PS2A"}],
        ["cmvs-invalid", "kirikiri", {"data/pack/script.cpz": "bad", "data/pack/start.ps3": "PS2A"}],
        ["exhibit", "exhibit", {"EXHIBIT.INI": "", "rld/scenario.RLD": "", "0.txt": ""}],
        ["exhibit-flat", "exhibit", {"EXHIBIT.INI": "", "scenario.RLD": ""}],
        ["exhibit-incomplete", "kirikiri", {"EXHIBIT.INI": ""}],
        ["catsystem2", "catsystem2", {"CS2.EXE": "", "pack.Int": ""}],
        ["catsystem2-boot", "catsystem2", {"cs2.exe": "", "boot.dfn": ""}],
        ["catsystem2-packed", "catsystem2", {"boot.dfn": "", "kcs.int": ""}],
        ["catsystem2-incomplete", "kirikiri", {"cs2.exe": ""}],
        ["yuris-exe", "yuris", {"YU-RIS.EXE": ""}],
        ["yuris-script", "yuris", {"data/script/system_start.yst": ""}],
        ["yuris-script-text", "yuris", {"data/script/system_start.txt": ""}],
        ["yuris-compiled", "yuris", {"ysbin/yscfg.ybn": "YSCF000000000000"}],
        ["yuris-truncated", "kirikiri", {"yscfg.ybn": "YSCF0000"}],
        ["yuris-pack", "yuris", {"pac/script.ypf": _ypf()}],
        ["yuris-pack-folding", "same", {"pac/SCRIPT.YPF": _ypf()}],
        ["yuris-hidden-file", "kirikiri", {".hidden.ypf": _ypf()}],
        ["artemis-ini", "artemis", {"system.ini": "Engine = Artemis\nSAVEPATH = games\\\\Title", "root.pfs": "", "data.xp3": ""}],
        ["artemis-iet", "artemis", {"system.ini": " BOOT = system/boot.IET\r\n", "root.pfs": "", "data.xp3": ""}],
        ["artemis-pfs", "artemis", {"root.pfs": ""}],
        ["artemis-pfs-plus-xp3", "kirikiri", {"root.pfs": "", "data.xp3": ""}],
        ["siglus-ini", "siglus", {"GameExe.INI": ""}],
        ["siglus-data", "siglus", {"GameExe.DAT": ""}],
        ["siglus-scene", "siglus", {"Scene.pck": ""}],
        ["mages", "mages", {"Script.MPK": "", "SYSTEM.MPK": "", "chara.mpk": ""}],
        ["mages-incomplete", "kirikiri", {"script.mpk": "", "system.mpk": ""}],
        ["n2-explicit", "n2system", {"AETHER-N2SYSTEM.JSON": "", "0.txt": ""}],
        ["n2-profile", "n2system", {"profiles.json": '{"activeProfile":"jp","profiles":{"jp":{"product.name":"Game","designResolution":"640x480"}}}'}],
        ["n2-trailing-comma", "n2system", {"profiles.json": '{"activeProfile":null,"product.name":"Game","designResolution":"640x480",}'}],
        ["n2-generic-profile", "kirikiri", {"profiles.json": '{"activeProfile":"jp"}'}],
        ["n2-npa", "n2system", {"NSS.NPA": _npa(), "system.npa": _npa()}],
        ["n2-pak", "n2system", {"script.pak": _pak(), "SYSTEM.PAK": _pak(), "SYS_CN.INI": "", "game.ini": ""}],
        ["n2-pak-incomplete", "kirikiri", {"script.pak": _pak(), "SYSTEM.PAK": _pak(), "game.ini": ""}],
        ["renpy-loose", "renpy", {"game/options.rpy": 'define config.name = _("RenPy title")', "0.txt": ""}],
        ["renpy-compiled", "renpy", {"Contents/Resources/autorun/game/sub/scenario.RPYC": "RENPY RPC2"}],
        ["renpy-packed", "renpy", {"game/story.rpa": "RPA-3.0 " }],
        ["renpy-packed-rpa2", "renpy", {"story.rpa": "RPA-2.0 " }],
        ["renpy-invalid", "kirikiri", {"game/fake.rpyc": "bad", "game/cache/ignored.rpy": "", "game/a/b/c/d/too-deep.rpy": ""}],
        ["renpy-game-root", "renpy", {"game/tree/inside.rpy": ""}, "game"],
        ["tyrano-html", "tyranoscript", _tyrano_files("")],
        ["tyrano-electron", "tyranoscript", _tyrano_files("resources/app/")],
        ["tyrano-app", "tyranoscript", _tyrano_files("app/")],
        ["tyrano-case-sensitive-path", "same", {"INDEX.HTML": "", "tyrano/tyrano.js": "", "tyrano/plugins/kag/kag.js": "", "data/system/Config.tjs": ""}],
        ["tyrano-html-priority", "tyranoscript", _tyrano_files("").merged(_tyrano_files("resources/app/"))],
        ["not-tyrano", "kirikiri", {"index.html": ""}],
    ]
    var app = Main.new()
    app.player = player
    for row in cases:
        var directory := _make_case(row[0], row[2])
        var path := directory.path_join(row[3]) if row.size() == 4 else directory
        _compare(app, path, row[1], row[0])

    var hcb := _make_case("rfvp", {"0.txt": ""})
    _write_hcb(hcb.path_join("Visible.HCB"), 7)
    _write_hcb(hcb.path_join(".Hidden.hcb"), 7)
    _write_hcb(hcb.path_join("Invalid.hcb"), 16)
    _compare(app, hcb, "rfvp", "RFVP visible preference")
    _compare(app, hcb.path_join(".Hidden.hcb"), "rfvp", "RFVP explicit hidden entry")
    var hidden_hcb := _make_case("hidden-hcb-only", {})
    _write_hcb(hidden_hcb.path_join(".Story.hcb"), 7)
    _compare(app, hidden_hcb, "rfvp", "RFVP hidden-only fallback")
    for mode in ["legacy", "native"]:
        app.game_detection_override = mode
        var game := {"path": hcb, "launchFile": ".Hidden.hcb"}
        var games: Array[Dictionary] = [game]
        app._backfill_game_metadata(games)
        _expect(game.launchFile == ".Hidden.hcb", mode + " metadata backfill preserves the chosen HCB")
    _compare(app, _make_case("invalid-hcb", {"script.hcb": "not bytecode"}), "kirikiri", "RFVP invalid header")

    var asar := _make_case("tyrano-asar", {"game/script.rpy": ""})
    _write(asar.path_join("resources/app.asar"), _asar(false))
    _compare(app, asar, "tyranoscript", "ASAR beats Ren'Py")
    _write(asar.path_join("resources/app.asar"), _asar(true))
    _compare(app, asar, "renpy", "ASAR rejects index containing a link")
    _write(asar.path_join("resources/app.asar"), "invalid".to_utf8_buffer())
    _compare(app, asar, "renpy", "ASAR rejects invalid Pickle")
    _write(asar.path_join("app.asar"), _asar(false))
    _compare(app, asar, "tyranoscript", "root ASAR")

    var outside := _make_case("renpy-link-target", {"linked.rpy": ""})
    var renpy_link := _make_case("renpy-link", {"game/placeholder": ""})
    var scripts := DirAccess.open(renpy_link.path_join("game"))
    if scripts.create_link(outside, "linked") == OK:
        _compare(app, renpy_link, "kirikiri", "RenPy ignores directory symlinks")

    var flash := _make_case("flash", {"movie.SwF": "placeholder", "movie.swc": "placeholder"})
    var swf := flash.path_join("movie.SwF")
    _compare(app, swf, "kirikiri", "SWF in the visual-novel context")
    for mode in ["legacy", "native"]:
        app.game_detection_override = mode
        var matches := FileLibrary.list_directory(flash, ["swf"], app._is_flash_game_file)
        _expect(matches.size() == 1 and String(matches[0].path) == swf, mode + " Flash library selection")
        _expect(not app._is_flash_game_file(flash.path_join("movie.swc")), mode + " excludes SWC")
    _compare(app, fixture.get_current_dir().path_join("missing"), "kirikiri", "unknown path")
    _compare(app, "", "kirikiri", "empty path")

    var matrix: Array = JSON.parse_string(FileAccess.get_file_as_string("res://tests/game_detection_probes.json"))
    var mock := ScoredProvider.new()
    app.player = mock
    for test in matrix:
        mock.scores = test.scores
        mock.calls = 0
        var direct := String(test.get("direct", "kirikiri"))
        var result: String = app._probe_game_runtime_kind(fixture.get_current_dir(), direct)
        _expect(result == test.engine, "%s legacy probe expected=%s actual=%s" % [test.name, test.engine, result])
        if direct != "kirikiri":
            _expect(mock.calls == 0, "legacy does not probe a recognized runtime")
    app.player = null
    _check_detection_settings(app)
    app.ui_motion.free()
    app.free()
    player.free()
    fixture = null
    print("game_detection_parity_test: %d filesystem cases, %d provider cases, %d failures" % [checked, matrix.size(), failures])
    quit(0 if failures == 0 else 1)


func _check_detection_settings(app) -> void:
    var user_dir_name := fixture.get_current_dir().get_file()
    var settings_key := "application/config/custom_user_dir_name"
    ProjectSettings.set_setting(settings_key, user_dir_name)
    ProjectSettings.set_setting(settings_key + "." + OS.get_name().to_lower(), user_dir_name)
    var user_dir := OS.get_user_data_dir()
    _expect(user_dir.get_file() == user_dir_name, "Isolate game detection preferences")
    if user_dir.get_file() != user_dir_name:
        return
    DirAccess.make_dir_recursive_absolute(user_dir)

    var version_env := "AETHERKIRI_SIMULATE_VERSION"
    OS.set_environment(version_env, "1.2.2-alpha.1")
    app._load_shell_settings()
    _expect(app._game_detection_mode() == "native", "Automatic uses native detection on Alpha")
    app._begin_settings_edit()
    app._set_settings_draft_value("mock_enabled", not app.mock_enabled)
    app._save_settings_draft()

    var config := ConfigFile.new()
    _expect(config.load(app.SETTINGS_FILE) == OK, "Save the unrelated settings change")
    _expect(not config.has_section_key("compatibility", "game_detection_override"), "Unrelated saves omit the automatic default")
    config.set_value("compatibility", "game_detection_mode", "native")
    _expect(config.save(app.SETTINGS_FILE) == OK, "Stage an old draft's saved detection default")

    OS.set_environment(version_env, "1.2.2")
    app._load_shell_settings()
    _expect(app._game_detection_mode() == "legacy", "A stable release uses legacy detection after an automatic Alpha default")
    _save_detection_override(app, "legacy")

    OS.set_environment(version_env, "1.2.3-alpha.1")
    app._load_shell_settings()
    _expect(app._game_detection_mode() == "legacy", "An explicit legacy choice survives an upgrade to Alpha")
    _save_detection_override(app, "native")

    OS.set_environment(version_env, "1.2.3")
    app._load_shell_settings()
    _expect(app._game_detection_mode() == "native", "An explicit native choice survives an upgrade to stable")
    _save_detection_override(app, "auto")
    app._load_shell_settings()
    _expect(app._game_detection_mode() == "legacy", "Returning to Automatic clears the override after reload")
    config = ConfigFile.new()
    _expect(config.load(app.SETTINGS_FILE) == OK, "Reload the settings after resetting the override")
    _expect(not config.has_section_key("compatibility", "game_detection_override"), "Automatic removes the saved override")
    DirAccess.remove_absolute(ProjectSettings.globalize_path(app.SETTINGS_FILE))
    DirAccess.remove_absolute(user_dir)


func _save_detection_override(app, choice: String) -> void:
    app._begin_settings_edit()
    app._set_settings_draft_value("game_detection_override", choice)
    app._save_settings_draft()


func _compare(app, path: String, expected: String, label: String) -> void:
    checked += 1
    app.game_detection_override = "legacy"
    var legacy: Dictionary = app._inspect_game_metadata(path)
    var root_path: String = app._game_runtime_root(path)
    var legacy_kind: String = app._game_runtime_kind(path)
    var legacy_tyrano = app._tyrano_entry_file(root_path)
    var legacy_renpy = app._renpy_game_directory(root_path)
    app.game_detection_override = "native"
    var native: Dictionary = app._inspect_game_metadata(path)
    if expected != "same":
        _expect(legacy.engine == expected, "%s legacy expected=%s actual=%s" % [label, expected, legacy.engine])
    for field: String in ["engine", "signals", "launchFile", "titleCandidates", "title"]:
        _expect(legacy[field] == native[field], "%s (%s) %s legacy=%s native=%s" % [label, path, field, legacy[field], native[field]])
    _expect(legacy_kind == app._game_runtime_kind(path), label + " installed Provider fallback")
    _expect(legacy_tyrano == app._tyrano_entry_file(root_path), label + " dedicated Tyrano path")
    _expect(legacy_renpy == app._renpy_game_directory(root_path), label + " dedicated RenPy path")


func _make_case(name: String, entries: Dictionary) -> String:
    var path := fixture.get_current_dir().path_join(name)
    DirAccess.make_dir_recursive_absolute(path)
    for relative: String in entries:
        var bytes: PackedByteArray = entries[relative].to_utf8_buffer() if entries[relative] is String else entries[relative]
        _write(path.path_join(relative), bytes)
    return path


func _write(path: String, bytes: PackedByteArray) -> void:
    DirAccess.make_dir_recursive_absolute(path.get_base_dir())
    var file := FileAccess.open(path, FileAccess.WRITE)
    if file == null:
        _expect(false, "could not write " + path)
        return
    file.store_buffer(bytes)


func _write_hcb(path: String, mode: int) -> void:
    var file := FileAccess.open(path, FileAccess.WRITE)
    file.store_32(8)
    file.store_32(0)
    file.store_32(4)
    file.store_32(0)
    file.store_8(mode)
    file.store_8(0)
    file.store_8(0)
    file.store_16(0)
    file.store_16(0)


func _npa() -> PackedByteArray:
    return PackedByteArray([0x4e, 0x50, 0x41, 1, 0, 0, 0])


func _pak() -> PackedByteArray:
    var buffer := PackedByteArray()
    buffer.resize(0x108)
    buffer.encode_u32(0, 3)
    buffer.encode_u32(0x104, 100)
    return buffer


func _ypf() -> PackedByteArray:
    var buffer := PackedByteArray()
    buffer.resize(32)
    buffer[0] = 89
    buffer[1] = 80
    buffer[2] = 70
    return buffer


func _tyrano_files(prefix: String) -> Dictionary:
    return {
        prefix + "index.html": "",
        prefix + "tyrano/tyrano.js": "",
        prefix + "tyrano/plugins/kag/kag.js": "",
        prefix + "data/system/Config.tjs": 'System.title = "Tyrano title"',
    }


func _asar(invalid_link: bool) -> PackedByteArray:
    var index := {"files": {}}
    for path: String in _tyrano_files(""):
        var parts := path.split("/")
        var node: Dictionary = index.files
        for i in range(parts.size() - 1):
            if not node.has(parts[i]):
                node[parts[i]] = {"files": {}}
            node = node[parts[i]].files
        node[parts[-1]] = {"size": 0, "offset": "0"}
    if invalid_link:
        index.files["link"] = {"link": "index.html"}
    var json := JSON.stringify(index).to_utf8_buffer()
    var padded := (json.size() + 3) & ~3
    var bytes := PackedByteArray()
    bytes.resize(16 + padded)
    bytes.encode_u32(0, 4)
    bytes.encode_u32(4, 8 + padded)
    bytes.encode_u32(8, 4 + padded)
    bytes.encode_u32(12, json.size())
    for i in range(json.size()):
        bytes[16 + i] = json[i]
    return bytes


func _expect(ok: bool, message: String) -> void:
    if not ok:
        failures += 1
        printerr(message)
