extends SceneTree

const Main = preload("res://scripts/main.gd")
const Metadata = preload("res://scripts/game_metadata.gd")
const Launch = preload("res://scripts/game_launch_entry.gd")
class SelectionApp:
    extends "res://scripts/main.gd"

    func _update_game(_path: String, values: Dictionary) -> void:
        selected_game.merge(values, true)

    func _show_detail(_game: Dictionary, _source: Control = null) -> void:
        pass

    func _dismiss_modal(after: Callable = Callable()) -> void:
        if after.is_valid():
            after.call()

var failures := 0

func _expect(value: bool) -> void:
    if not value:
        failures += 1
        push_error("RFVP import configuration regression")

func _init() -> void:
    var root := ProjectSettings.globalize_path("user://rfvp_import_%d" % Time.get_ticks_usec())
    DirAccess.make_dir_recursive_absolute(root)
    for name in ["Story.hcb", ".Story.hcb"]:
        var file := FileAccess.open(root.path_join(name), FileAccess.WRITE)
        file.store_32(8)
        file.store_buffer(PackedByteArray([1, 0, 0, 4]))
        file.store_32(4)
        file.store_16(0)
        file.store_16(0)
        file.store_buffer(PackedByteArray([7, 0, 1, 0, 0, 0, 0, 0]))
        file.close()
    var app = SelectionApp.new()
    var imported: Dictionary = app._game_info_from_path(root)
    _expect(imported.launchFile == "Story.hcb")
    _expect(Launch.rfvp_encoding(imported) == "sjis")
    _expect(Metadata.hcb_launch_files(root).has(".Story.hcb"))
    imported.launchFile = ".Story.hcb"
    imported.rfvpEncoding = "gbk"
    var persisted: Dictionary = JSON.parse_string(JSON.stringify(imported))
    var games: Array[Dictionary] = [persisted]
    app._backfill_game_metadata(games)
    _expect(persisted.launchFile == ".Story.hcb" and persisted.rfvpEncoding == "gbk")
    for script in ["Story.hcb", ""]:
        var manual := {"path": root, "engine": "rfvp", "launchFile": script, "rfvpEncoding": "utf8"}
        games = [manual]
        app._backfill_game_metadata(games)
        _expect(manual.launchFile == script and manual.rfvpEncoding == "utf8")
        var merged: Dictionary = app._merge_game_dictionary(manual, imported)
        _expect(merged.launchFile == script and merged.rfvpEncoding == "utf8")
    var legacy := {"path": root, "engine": "rfvp", "launchFile": "Story.hcb"}
    var legacy_merged: Dictionary = app._merge_game_dictionary(legacy, imported)
    _expect(legacy_merged.launchFile == "Story.hcb")
    _expect(Launch.rfvp_encoding(legacy_merged) == "sjis")
    games = [legacy]
    app._backfill_game_metadata(games)
    _expect(legacy.launchFile == "Story.hcb" and Launch.rfvp_encoding(legacy) == "sjis")
    var missing := {"path": root, "engine": "rfvp"}
    games = [missing]
    app._backfill_game_metadata(games)
    _expect(missing.launchFile == "Story.hcb" and Launch.rfvp_encoding(missing) == "sjis")
    app.selected_game = {"path": root}
    app._select_rfvp_launch_file(root, ".Story.hcb")
    app._set_rfvp_encoding_for_selected(root, "gbk")
    _expect(app.selected_game.launchFile == ".Story.hcb")
    _expect(app.selected_game.rfvpEncoding == "gbk")
    app.ui_motion.free()
    app.free()
    for name in ["Story.hcb", ".Story.hcb"]:
        DirAccess.remove_absolute(root.path_join(name))
    DirAccess.remove_absolute(root)
    if failures == 0:
        print("RFVP_IMPORT_OK")
    quit(0 if failures == 0 else 1)
