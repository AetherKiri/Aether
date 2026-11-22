extends SceneTree

const Locations := preload("res://scripts/game_save_locations.gd")
const Storage := preload("res://scripts/game_save_storage.gd")

var failures := 0

func _expect(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        printerr(message)

func _write(path: String, data: String) -> void:
    _expect(DirAccess.make_dir_recursive_absolute(path.get_base_dir()) == OK, "Create fixture parent: " + path)
    var file := FileAccess.open(path, FileAccess.WRITE)
    _expect(file != null, "Create fixture file: " + path)
    if file != null:
        file.store_string(data)
        file.close()

func _check_native(base: String, app: String) -> void:
    var fixtures := {"system3": "ADISK.DAT", "xsystem35": "ADISK.ALD", "xsystem4": "test.AIN"}
    var native_keys := {"system3": "804d8907e2eaf130", "xsystem35": "aebfa565b5a5d2c5", "xsystem4": "df7747fda48dd815"}
    _expect(Locations._hex64(-1) == "ffffffffffffffff" and Locations._hex64(1, false) == "1", "Use native unsigned hex for save identities")
    for engine: String in fixtures:
        var game := base.path_join(engine)
        _write(game.path_join(String(fixtures[engine])), engine + " synthetic script")
        var key := Locations._script_identity(game, engine)
        _expect(key == native_keys[engine], engine + " matches the native legacy script identity")
        var legacy := app.path_join(engine).path_join(key)
        _write(legacy.path_join("slot.sav"), engine + " legacy slot")
        _write(legacy.path_join("cache/disposable"), "not a save")
        var prepared := Locations.prepare_native_writable_root(game, engine, app)
        var bank := game.path_join("savedata").path_join(engine).path_join(key)
        _expect(prepared.error == "" and prepared.path == game.path_join("savedata"), engine + " native writable root")
        _expect(Locations.resolve(game, engine, {}, app).get("main", {}).get("path") == bank, engine + " export uses local bank")
        _expect(FileAccess.get_file_as_string(bank.path_join("slot.sav")) == engine + " legacy slot", engine + " migrated bytes")
        _expect(not FileAccess.file_exists(bank.path_join("cache/disposable")), engine + " cache excluded")
        _expect(FileAccess.get_file_as_string(legacy.path_join("slot.sav")) == engine + " legacy slot", engine + " original retained")
        _write(bank.path_join("slot.sav"), "local progress")
        _write(legacy.path_join("slot.sav"), "newer app copy")
        Locations.prepare_native_writable_root(game, engine, app)
        _expect(FileAccess.get_file_as_string(bank.path_join("slot.sav")) == "local progress", engine + " reopen preserves local progress")

    var mages := base.path_join("mages")
    for name in ["script.mpk", "system.mpk", "bg1.mpk"]:
        _write(mages.path_join(String(name)), "fixture")
    _write(app.path_join("saves/mo8/slot.sav"), "mo8")
    _write(app.path_join("saves/mo6tw/other.sav"), "other profile")
    var prepared := Locations.prepare_native_writable_root(mages, "mages", app)
    _expect(prepared.error == "" and prepared.path == mages.path_join("savedata/mages"), "MAGES scoped writable root")
    _expect(FileAccess.get_file_as_string(mages.path_join("savedata/mages/saves/mo8/slot.sav")) == "mo8", "MAGES selected profile migrated")
    _expect(not FileAccess.file_exists(mages.path_join("savedata/mages/saves/mo6tw/other.sav")), "MAGES does not copy another title")

    var minori := base.path_join("minori")
    _write(minori.path_join("game.txt"), "fixture")
    _write(app.path_join("save/slot-01.sav"), "unattributed slot")
    _write(app.path_join("system.dat"), "unattributed global")
    prepared = Locations.prepare_native_writable_root(minori, "minori", app)
    _expect(prepared.error == "" and prepared.path == minori.path_join("savedata/minori"), "Minori starts an isolated local bank")
    _expect(not FileAccess.file_exists(String(prepared.path).path_join("save/slot-01.sav")), "Minori shared old slot not auto-assigned")
    _expect(FileAccess.get_file_as_string(app.path_join("system.dat")) == "unattributed global", "Minori preserves shared legacy files")
    _write(app.path_join("save/slot-02.sav"), "MINORISV recognized slot")
    _write(app.path_join("save/unrelated.dat"), "unrelated file")
    var recovered := Locations.recover_minori_legacy(minori, app)
    _expect(recovered.error == "", "Confirmed Minori recovery can fill an empty bank")
    var bank := minori.path_join("savedata/minori")
    _expect(FileAccess.get_file_as_string(bank.path_join("save/slot-02.sav")) == "MINORISV recognized slot", "Recover the confirmed legacy slot")
    _expect(not FileAccess.file_exists(bank.path_join("save/slot-01.sav")) and not FileAccess.file_exists(bank.path_join("save/unrelated.dat")), "Do not copy unrecognized files from the shared store")
    _write(bank.path_join("save/slot-02.sav"), "current progress")
    _expect(Locations.recover_minori_legacy(minori, app).error != "", "Recovery refuses to merge an existing bank")
    _expect(FileAccess.get_file_as_string(bank.path_join("save/slot-02.sav")) == "current progress", "Recovery does not overwrite local progress")

func _check_tyrano(base: String, app: String) -> void:
    var game := app.path_join("games/tyrano")
    var old := app.path_join("tyrano_saves").path_join("user://games/tyrano".sha256_text())
    _write(game.path_join("index.html"), "fixture")
    _write(old.path_join("local_storage.json.bak"), '{"slot":"committed"}')
    _write(old.path_join("local_storage.json"), '{"slot":"replacement"}')
    _write(old.path_join("local_storage.json.new"), 'incomplete')
    var prepared := Locations.prepare_tyrano(game, app)
    var path := game.path_join("savedata/tyranoscript/local_storage.json")
    _expect(prepared.error == "" and FileAccess.get_file_as_string(path) == '{"slot":"committed"}', "Tyrano recovers the committed Android AtomicFile value")
    _expect(not FileAccess.file_exists(path + ".new") and FileAccess.file_exists(old.path_join("local_storage.json.new")), "Tyrano leaves unfinished legacy writes alone")
    var moved := base.path_join("moved")
    _expect(DirAccess.rename_absolute(game, moved) == OK, "Move the whole game directory")
    prepared = Locations.prepare_tyrano(moved, app)
    _expect(prepared.error == "" and FileAccess.get_file_as_string(String(prepared.path).path_join("local_storage.json")) == '{"slot":"committed"}', "Tyrano can load after the game moves")

func _check_blocked_and_wa2(base: String, app: String) -> void:
    var game := base.path_join("wa2")
    _write(game.path_join("savedata"), "block the directory")
    _write(game.path_join("save_Q.sav"), "native slot")
    _write(app.path_join("wa2/sysflags.bin"), "legacy flags")
    _write(app.path_join("wa2/audio-cache/track.pcm"), "cache")
    var blocked := Locations.prepare_wa2_flags(game, app)
    _expect(blocked.path == "" and blocked.error != "", "A blocked destination never becomes a legacy write target")
    _expect(FileAccess.get_file_as_string(app.path_join("wa2/sysflags.bin")) == "legacy flags", "Migration failure keeps the source")
    _expect(DirAccess.remove_absolute(game.path_join("savedata")) == OK, "Remove migration obstruction")
    var prepared := Locations.prepare_wa2_flags(game, app)
    var flags := game.path_join("savedata/wa2/sysflags.bin")
    _expect(prepared.error == "" and FileAccess.get_file_as_string(flags) == "legacy flags", "WA2 migration retries")
    _expect(not DirAccess.dir_exists_absolute(game.path_join("savedata/wa2/audio-cache")), "Audio cache stays out of game-local saves")
    _expect(FileAccess.get_file_as_string(game.path_join("save_Q.sav")) == "native slot", "Native WA2 slot remains unchanged")
    _expect(DirAccess.remove_absolute(flags) == OK, "Simulate deleted local flags")
    Locations.prepare_wa2_flags(game, app)
    _expect(not FileAccess.file_exists(flags), "A completed bank does not resurrect deleted saves")

func _initialize() -> void:
    var temp := DirAccess.create_temp("aether-game-local-saves")
    if temp == null:
        printerr("Could not create save test fixture")
        quit(1)
        return
    var base := temp.get_current_dir()
    var app := base.path_join("app")
    _check_native(base, app)
    _check_tyrano(base, app)
    _check_blocked_and_wa2(base, app)
    if failures == 0:
        print("Game-local save migration checks passed")
    quit(0 if failures == 0 else 1)
