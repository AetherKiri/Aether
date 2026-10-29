extends SceneTree

# Run each case in a separate process, for example:
# Godot --headless --path apps/godot_app --script \
#   res://tests/krkr_patch_startup_test.gd -- --case=encoding
# Repeat with --plugin-mode=krkrsdl3 to exercise the default core mode.
const CASES := ["order", "encoding", "helpers", "autopath", "error", "late", "explicit_late", "late_error", "partial_retry", "singleton_retry", "singleton_explicit_retry", "compiled", "preprocessor", "preprocessor_retry", "preprocessor_explicit_retry"]
const PREAMBLE := "if(typeof global.__patchTrace==\"undefined\") global.__patchTrace=[]; global.kag=%[]; global.KAGWindow=void;\n"
const SAVE_TRACE := "global.__patchTrace.save(System.exePath+\"trace.txt\");\n"

var player
var plugin_mode := "aether_all"

func _initialize() -> void:
    OS.set_environment("AETHERKIRI_SUPPRESS_NATIVE_ALERTS", "1")
    call_deferred("_run")

func _write(path: String, text: String) -> void:
    DirAccess.make_dir_recursive_absolute(path.get_base_dir())
    var file := FileAccess.open(path, FileAccess.WRITE)
    assert(file != null, "Could not write fixture: " + path)
    file.store_string(text)

func _run() -> void:
    var test_case := "order"
    for argument in OS.get_cmdline_user_args():
        if argument.begins_with("--case="):
            test_case = argument.trim_prefix("--case=")
        elif argument.begins_with("--plugin-mode="):
            plugin_mode = argument.trim_prefix("--plugin-mode=")
    if plugin_mode not in ["krkrsdl3", "aether_all"]:
        printerr("Unknown plugin mode: ", plugin_mode)
        quit(2)
        return
    if test_case not in CASES:
        printerr("Unknown patch startup case: ", test_case)
        quit(2)
        return
    var base := OS.get_environment("AETHERKIRI_PATCH_TEST_ROOT")
    if base.is_empty():
        base = OS.get_user_data_dir().path_join("krkr-patch-startup-test")
    base = base.path_join(plugin_mode)
    var game := base.path_join(test_case)
    DirAccess.make_dir_recursive_absolute(game)
    var trace_path := game.path_join("trace.txt")
    if FileAccess.file_exists(trace_path):
        DirAccess.remove_absolute(trace_path)
    var expected: Array[String] = []
    var startup := PREAMBLE
    var patch := ""
    var after := SAVE_TRACE

    match test_case:
        "preprocessor", "preprocessor_retry", "preprocessor_explicit_retry":
            patch = "@set (patch_config_runs = patch_config_runs + 1)\n" + PREAMBLE
            if test_case != "preprocessor":
                patch += "var dependency = Action;\n"
                _write(game.path_join("system/Initialize.tjs"), "class Action {}\n")
            patch += "@if (patch_config_runs == 1)\nglobal.__patchTrace.add(\"patch\");\n@endif\n@if (patch_config_runs == 2)\nglobal.__patchTrace.add(\"reload\");\n@endif\n"
            startup += "@if (patch_config_runs != 1)\nthrow new Exception(\"PATCH_CONFIG_NOT_READY\");\n@endif\n"
            if test_case != "preprocessor":
                startup += "Scripts.execStorage(\"system/Initialize.tjs\");\n"
            if test_case == "preprocessor_explicit_retry":
                startup += "Scripts.execStorage(\"patch.tjs\");\n"
            startup += "global.__patchTrace.add(\"startup\");\n"
            expected.assign(["startup", "patch", "reload"] if test_case == "preprocessor_retry" else ["patch", "startup", "reload"])
            # A retry completes the initial load without repeating @set;
            # a later explicit reload must still execute the directive.
            after = "@if (patch_config_runs != 1)\nglobal.__patchTrace.add(\"config-replayed\");\n@endif\nScripts.execStorage(\"patch.tjs\");\n" + SAVE_TRACE
        "order":
            patch = PREAMBLE + "if(typeof global.__patchCounter==\"undefined\") global.__patchCounter=0; ++global.__patchCounter; global.__patchTrace.add(\"patch:\"+global.__patchCounter);\n"
            startup += "global.__patchTrace.add(\"startup:\"+global.__patchCounter); Scripts.execStorage(\"patch.tjs\"); global.__patchTrace.add(\"explicit:\"+global.__patchCounter);\n"
            after = "global.__patchTrace.add(\"after:\"+global.__patchCounter);\n" + SAVE_TRACE
            expected.assign(["patch:1", "startup:1", "patch:2", "explicit:2", "after:2"])
        "encoding":
            patch = PREAMBLE + "Storages.setTextEncoding(\"GBK\"); global.__patchTrace.add(\"patch:\"+Scripts.textEncoding);\n"
            startup += "Scripts.execStorage(\"payload.tjs\"); global.__patchTrace.add(global.__patchText);\n"
            var bytes := "global.__patchText=\"".to_ascii_buffer()
            bytes.append_array(PackedByteArray([0xd6, 0xd0, 0xce, 0xc4]))
            bytes.append_array("\";\n".to_ascii_buffer())
            var file := FileAccess.open(game.path_join("payload.tjs"), FileAccess.WRITE)
            file.store_buffer(bytes)
            file.close()
            expected.assign(["patch:GBK", "中文"])
        "autopath":
            _write(game.path_join("pack/patch.tjs"), "global.__patchTrace.add(\"autopath\");\n")
            startup += "Storages.addAutoPath(System.exePath+\"pack/\"); Scripts.execStorage(\"patch.tjs\"); global.__patchTrace.add(\"startup\");\n"
            expected.assign(["autopath", "startup"])
        "helpers":
            patch = PREAMBLE + "global.__patchTrace.add(String.decode(String.encode(\"ok\"))); var buffer=new BinaryReader(<%07%>); global.__patchTrace.add(buffer.readUInt8());\n"
            startup += "global.__patchTrace.add(\"startup\");\n"
            expected.assign(["ok", "7", "startup"])
        "error":
            patch = PREAMBLE + "global.__patchTrace.add(\"patch-error\"); throw new Exception(\"PATCH_ERROR_EXPECTED\");\n"
            startup += "global.__patchTrace.add(\"startup\");\n"
            expected.assign(["patch-error", "startup"])
        "partial_retry":
            patch = PREAMBLE + "global.__patchDepth=0; global.__patchOriginalExt=&Storages.extractStorageExt; Storages.extractStorageExt=function(path) { if(++global.__patchDepth>4) throw new Exception(\"PATCH_WRAPPER_REPLAYED\"); var result=global.__patchOriginalExt(path); --global.__patchDepth; return result; }; Plugins.link(\"DrawDeviceD2D.dll\"); var dependency=Action; global.__patchTrace.add(\"late:\"+(new Action()).value());\n"
            _write(game.path_join("system/Initialize.tjs"), "class Action { function value() { return 7; } }\n")
            startup += "Scripts.execStorage(\"system/Initialize.tjs\"); if(!(DrawDeviceD2D instanceof \"Class\")) throw new Exception(\"PATCH_PLUGIN_LOST\"); global.__patchTrace.add(\"startup\");\n"
            after = "global.__patchTrace.add(Storages.extractStorageExt(\"voice.ogg\"));\n" + SAVE_TRACE
            expected.assign(["startup", "late:7", ".ogg"])
        "singleton_retry", "singleton_explicit_retry":
            patch = "class Service { function value() { return 9; } }\n" + PREAMBLE + "var dependency=Action; global.__patchTrace.add(\"instance:\"+Service.instance.marker); Service.instance=new Service(); global.__patchTrace.add(\"new:\"+Service.instance.value());\n"
            _write(game.path_join("system/Initialize.tjs"), "class Action {} class Service {} Service.instance=%[marker:42];\n")
            startup += "Scripts.execStorage(\"system/Initialize.tjs\");\n"
            if test_case == "singleton_explicit_retry":
                startup += "Scripts.execStorage(\"patch.tjs\");\n"
                expected.assign(["instance:42", "new:9", "startup"])
            else:
                expected.assign(["startup", "instance:42", "new:9"])
            startup += "global.__patchTrace.add(\"startup\");\n"
        "late", "explicit_late", "late_error":
            patch = "class PatchAction extends Action {}\n" + PREAMBLE + "global.__patchTrace.add(\"late:\"+(new PatchAction()).value());\n"
            if test_case == "late_error":
                patch += "throw new Exception(\"PATCH_ERROR_EXPECTED\");\n"
            _write(game.path_join("system/Initialize.tjs"), "class Action { function value() { return 7; } }\n")
            _write(game.path_join("pack/patch.tjs"), "global.__patchTrace.add(\"qualified\");\n")
            startup += "Scripts.execStorage(\"patch.tjs\"); Scripts.execStorage(\"pack/patch.tjs\"); Scripts.execStorage(\"system/Initialize.tjs\");\n"
            if test_case == "explicit_late":
                startup += "Scripts.execStorage(\"patch.tjs\"); global.__patchTrace.add(\"startup\");\n"
                expected.assign(["qualified", "late:7", "startup"])
            else:
                startup += "global.__patchTrace.add(\"startup\");\n"
                expected.assign(["qualified", "startup", "late:7"])
        "compiled":
            # First boot compiles an authored patch; the second boot verifies
            # that the normal bytecode loader also participates in the early phase.
            _write(game.path_join("source.tjs"), PREAMBLE + "global.__patchTrace.add(\"bytecode\");\n")
            startup += "global.__patchTrace.add(\"startup\"); Scripts.compileStorage(\"source.tjs\", System.exePath+\"patch.tjs\");\n"
            expected.assign(["bytecode", "startup"])

    _write(game.path_join("startup.tjs"), startup)
    _write(game.path_join("AfterStartup.tjs"), after)
    if not patch.is_empty():
        _write(game.path_join("patch.tjs"), patch)
    elif FileAccess.file_exists(game.path_join("patch.tjs")):
        DirAccess.remove_absolute(game.path_join("patch.tjs"))

    if test_case == "compiled":
        if not await _boot(game, base.path_join("compile-user")):
            quit(1)
            return
        var raw := FileAccess.get_file_as_bytes(game.path_join("patch.tjs"))
        if raw.size() < 4 or raw.slice(0, 4).get_string_from_ascii() != "TJS2":
            printerr("Fixture compiler did not write TJS bytecode")
            quit(1)
            return
    if not await _boot(game, base.path_join(test_case + "-user")):
        quit(1)
        return
    var logs: String = player.drain_startup_logs()
    player.destroy_engine()
    var actual := FileAccess.get_file_as_bytes(trace_path).get_string_from_utf16().trim_prefix("\ufeff").strip_edges().replace("\r", "").split("\n")
    if actual != PackedStringArray(expected):
        printerr("PATCH_STARTUP_FAILED case=", test_case, " expected=", expected, " actual=", actual, " logs=", logs)
        quit(1)
        return
    var diagnostic := "Deferred startup patch error" if test_case == "late_error" else "Startup patch error"
    if test_case in ["error", "late_error"] and (not diagnostic in logs or not "PATCH_ERROR_EXPECTED" in logs or not "patch.tjs" in logs):
        printerr("Expected a patch diagnostic with message and script location: ", logs)
        quit(1)
        return
    print("KRKR_PATCH_STARTUP_OK case=", test_case, " plugin_mode=", plugin_mode, " trace=", actual)
    quit(0)

func _boot(game: String, user_path: String) -> bool:
    if player != null:
        player.queue_free()
        await process_frame
    player = ClassDB.instantiate("AetherRuntimePlayer")
    root.add_child(player as Node)
    DirAccess.make_dir_recursive_absolute(user_path.path_join("cache"))
    if not player.initialize_engine(user_path, user_path.path_join("cache")):
        printerr("Patch probe initialize failed: ", player.get_last_error())
        return false
    player.set_engine_option("mock_enabled", "0")
    player.set_engine_option("plugin_load_mode", plugin_mode)
    player.set_engine_option("error_dialog_logs", "1")
    if player.open_game(game, true) != 0:
        printerr("Patch probe open failed: ", player.get_last_error())
        return false
    var deadline := Time.get_ticks_msec() + 20000
    while Time.get_ticks_msec() < deadline:
        var state: int = player.get_startup_state()
        if state == 2:
            if game.ends_with("compiled") and user_path.ends_with("compile-user"):
                player.destroy_engine()
            return true
        if state == 3:
            printerr("Patch probe startup failed: ", player.get_last_error(), " logs=", player.drain_startup_logs())
            player.destroy_engine()
            return false
        await process_frame
    printerr("Patch probe startup timed out")
    player.destroy_engine()
    return false
