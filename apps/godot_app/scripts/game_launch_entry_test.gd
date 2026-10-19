extends SceneTree

const GameLaunchEntry = preload("res://scripts/game_launch_entry.gd")

var failures := 0

func _init() -> void:
    var root := "/Users/test/游戏/NOBLE☆WORKS"
    var exe_path := root.path_join("开始游戏.exe")
    var archive_path := root.path_join("patch/data.xp3")

    _expect_equal(GameLaunchEntry.rfvp_encoding({}), "sjis", "Japanese default")
    var chinese := {GameLaunchEntry.RFVP_ENCODING_FIELD: "gbk"}
    _expect_equal(GameLaunchEntry.rfvp_encoding(chinese), "gbk", "per-game GBK")
    var reloaded: Dictionary = JSON.parse_string(JSON.stringify(chinese))
    _expect_equal(GameLaunchEntry.rfvp_encoding(reloaded), "gbk", "persisted encoding")
    _expect_equal(GameLaunchEntry.rfvp_encoding({}), "sjis", "no cross-game leakage")
    _expect_equal(GameLaunchEntry.rfvp_encoding(chinese, " UTF8 "), "utf8", "environment override")
    _expect_equal(GameLaunchEntry.rfvp_encoding({GameLaunchEntry.RFVP_ENCODING_FIELD: "bad"}), "sjis", "invalid saved value")
    var configured := {GameLaunchEntry.FIELD: "Selected.hcb"}
    var detected := {GameLaunchEntry.FIELD: "Other.hcb"}
    GameLaunchEntry.backfill(configured, detected)
    _expect_equal(configured[GameLaunchEntry.FIELD], "Selected.hcb", "metadata preserves selection")
    configured[GameLaunchEntry.FIELD] = ""
    GameLaunchEntry.backfill(configured, detected)
    _expect_equal(configured[GameLaunchEntry.FIELD], "", "metadata preserves automatic choice")
    configured.clear()
    GameLaunchEntry.backfill(configured, detected)
    _expect_equal(configured[GameLaunchEntry.FIELD], "Other.hcb", "legacy metadata backfill")

    var translated_metadata := {GameLaunchEntry.FIELD: ".Story.hcb", GameLaunchEntry.RFVP_ENCODING_FIELD: "gbk"}
    var fresh := {}
    GameLaunchEntry.backfill(fresh, translated_metadata)
    _expect_equal(fresh[GameLaunchEntry.FIELD], ".Story.hcb", "fresh translated entry")
    _expect_equal(fresh[GameLaunchEntry.RFVP_ENCODING_FIELD], "gbk", "fresh translated encoding")
    var manual := {GameLaunchEntry.FIELD: "Story.hcb", GameLaunchEntry.RFVP_ENCODING_FIELD: "utf8"}
    GameLaunchEntry.backfill(manual, translated_metadata)
    _expect_equal(manual[GameLaunchEntry.FIELD], "Story.hcb", "manual script retained")
    _expect_equal(manual[GameLaunchEntry.RFVP_ENCODING_FIELD], "utf8", "manual encoding retained")
    var original_without_encoding := {GameLaunchEntry.FIELD: "Story.hcb"}
    GameLaunchEntry.backfill(original_without_encoding, translated_metadata)
    _expect_equal(GameLaunchEntry.rfvp_encoding(original_without_encoding), "sjis", "no unrelated script encoding copied")

    _expect_equal(GameLaunchEntry.resolve({"path": root}), root, "default directory entry")
    _expect_equal(
        GameLaunchEntry.resolve({"path": root, GameLaunchEntry.FIELD: "Script.HCB"}),
        root.path_join("Script.HCB"),
        "FVP script launch path"
    )
    _expect_equal(
        GameLaunchEntry.resolve_for_runtime(
            {"path": root, GameLaunchEntry.FIELD: "Script.HCB"},
            "rfvp"
        ),
        root.path_join("Script.HCB"),
        "RFVP configured script launch path"
    )
    _expect_equal(
        GameLaunchEntry.relative_path_for_selection(root, exe_path),
        "开始游戏.exe",
        "EXE selection"
    )
    _expect_equal(
        GameLaunchEntry.resolve({"path": root, GameLaunchEntry.FIELD: "开始游戏.exe"}),
        exe_path,
        "EXE launch path"
    )
    _expect_equal(
        GameLaunchEntry.resolve_for_runtime(
            {"path": root, GameLaunchEntry.FIELD: "开始游戏.exe"},
            "artemis"
        ),
        root,
        "Artemis directory launch path"
    )
    _expect_equal(
        GameLaunchEntry.resolve_for_runtime(
            {"path": root, GameLaunchEntry.FIELD: "开始游戏.exe"},
            "softpal"
        ),
        root,
        "SoftPal directory launch path"
    )
    _expect_equal(
        GameLaunchEntry.resolve_for_runtime(
            {"path": root, GameLaunchEntry.FIELD: "开始游戏.exe"},
            "mages"
        ),
        root,
        "MAGES directory launch path"
    )
    _expect_equal(
        GameLaunchEntry.resolve_for_runtime(
            {"path": root, GameLaunchEntry.FIELD: "开始游戏.exe"},
            "kirikiri"
        ),
        exe_path,
        "KiriKiri configured launch path"
    )
    _expect_equal(
        GameLaunchEntry.resolve_for_runtime(
            {"path": root, GameLaunchEntry.FIELD: "开始游戏.exe"},
            "kirikiri",
            true
        ),
        root,
        "provider runtime keeps directory root"
    )
    _expect_equal(
        GameLaunchEntry.relative_path_for_selection(root, archive_path),
        "patch/data.xp3",
        "nested XP3 selection"
    )
    _expect_equal(
        GameLaunchEntry.resolve({"path": root, GameLaunchEntry.FIELD: "patch/data.xp3"}),
        archive_path,
        "nested XP3 launch path"
    )
    _expect_equal(
        GameLaunchEntry.relative_path_for_selection(root, "/Users/test/other/game.exe"),
        "",
        "outside selection"
    )
    _expect_equal(
        GameLaunchEntry.relative_path_for_selection(root, root.path_join("readme.txt")),
        "",
        "unsupported selection"
    )

    var yuris_root := ProjectSettings.globalize_path(
        "user://game_launch_entry_yuris_%d" % Time.get_ticks_usec()
    )
    DirAccess.make_dir_recursive_absolute(yuris_root.path_join("data/script/UserScript"))
    _expect_equal(
        GameLaunchEntry.default_yuris_startup_script(yuris_root),
        "",
        "YU-RIS startup absent"
    )
    var yuris_start := yuris_root.path_join("data/script/UserScript/start.txt")
    var yuris_file := FileAccess.open(yuris_start, FileAccess.WRITE)
    if yuris_file != null:
        yuris_file.store_string("#START\n")
    yuris_file = null
    _expect_equal(
        GameLaunchEntry.default_yuris_startup_script(yuris_root),
        yuris_start,
        "YU-RIS UserScript startup"
    )
    var yuris_scenario_start := yuris_root.path_join(
        "data/script/UserScript/SCENARIO_START.txt"
    )
    yuris_file = FileAccess.open(yuris_scenario_start, FileAccess.WRITE)
    if yuris_file != null:
        yuris_file.store_string("#SCENARIO_START\n")
    yuris_file = null
    _expect_equal(
        GameLaunchEntry.default_yuris_startup_script(yuris_root),
        yuris_scenario_start,
        "YU-RIS official scenario startup"
    )
    _remove_tree(yuris_root)
    _expect_equal(
        GameLaunchEntry.configured_relative_path({
            "path": root,
            GameLaunchEntry.FIELD: "../other/game.exe",
        }),
        "",
        "parent traversal"
    )
    _expect_equal(
        GameLaunchEntry.configured_relative_path({
            "path": root,
            GameLaunchEntry.FIELD: "C:\\Games\\other.exe",
        }),
        "",
        "absolute Windows path"
    )
    _expect_equal(
        GameLaunchEntry.configured_relative_path({
            "path": root,
            GameLaunchEntry.FIELD: "readme.txt",
        }),
        "",
        "unsupported configured entry"
    )
    _expect_equal(
        GameLaunchEntry.relative_path_for_selection(
            "C:\\Games\\Noble Works",
            "C:\\Games\\Noble Works\\game.exe"
        ),
        "game.exe",
        "Windows separators"
    )
    var spaced_root := "/Users/test/游戏/Visual Novel+ "
    _expect_equal(
        GameLaunchEntry.resolve({"path": spaced_root}),
        spaced_root,
        "trailing-space directory"
    )
    _expect_equal(
        GameLaunchEntry.resolve({
            "path": spaced_root,
            GameLaunchEntry.FIELD: "cs2.exe",
        }),
        spaced_root.path_join("cs2.exe"),
        "launch file inside trailing-space directory"
    )
    if failures == 0:
        print("game_launch_entry_test: PASS")
        quit(0)
    else:
        quit(1)


func _expect_equal(actual: String, expected: String, label: String) -> void:
    if actual == expected:
        return
    push_error(
        "game_launch_entry_test: %s: expected %s, got %s" % [label, expected, actual]
    )
    failures += 1


func _remove_tree(path: String) -> void:
    var dir := DirAccess.open(path)
    if dir == null:
        return
    dir.list_dir_begin()
    var entry := dir.get_next()
    while not entry.is_empty():
        var child := path.path_join(entry)
        if dir.current_is_dir():
            _remove_tree(child)
        else:
            DirAccess.remove_absolute(child)
        entry = dir.get_next()
    dir.list_dir_end()
    DirAccess.remove_absolute(path)
