extends SceneTree
# Run: Godot --headless --audio-driver Dummy --path apps/godot_app \
#   --script res://scripts/wa2_playability_probe.gd
# AETHERKIRI_WA2_CONFIG names a JSON file; AETHERKIRI_TEST_CONFIG is fallback.
# Required: game_path, output_dir. Optional: user_data_dir (default output/userdata),
# mode="smoke"|"route"|"chapter", startup_script="3013" (chapter entry),
# choice_plan=<UTF8 file of script group original_raw_row, # comments>,
# expect_flag=20, max_frames=300000, capture_every=500, log_every=1000,
# ordinary_smoke=true, pending_choice_roundtrip=true, save_slot=8,
# stop_after_choices=0, chapter_frames=1200, finish_movies=true.
# route requires a plan and expect_flag; chapter may use a partial plan plus
# stop_after_choices. Smoke always starts from title and uses real NEW GAME input.

const STARTUP_SUCCEEDED := 2
const STARTUP_FAILED := 3
var player
var config: Dictionary = {}
var output_dir := ""
var profile_dir := ""
var frames := 0
var max_frames := 300000
var failure := ""
var checks: Array = []
var checkpoint_differences: Array = []
var frame_comparisons: Array = []
var save_ready_waits: Array = []
var plan: Array = []
var consumed := 0
var capture_index := 0
var roundtrip_done := false
var disabled_checked := false
var movies_finished := 0
var audio_acks := 0
var last_debug: Dictionary = {}
var last_runtime: Dictionary = {}

func _initialize() -> void:
    _run.call_deferred()

func _run() -> void:
    if not _load_config() or not _load_plan():
        _finish()
        return
    if not ClassDB.class_exists("AetherRuntimePlayer"):
        _fail("AetherRuntimePlayer is unavailable; load the compiled GDExtension")
        _finish()
        return
    player = ClassDB.instantiate("AetherRuntimePlayer")
    root.add_child(player as Node)
    var engine_user := output_dir.path_join("host-user")
    DirAccess.make_dir_recursive_absolute(engine_user.path_join("cache"))
    if not player.initialize_engine(engine_user, engine_user.path_join("cache")):
        _fail("initialize_engine: %s" % player.get_last_error())
        _finish()
        return
    if int(player.set_render_backend("DebugCPU")) != 0:
        _fail("CPU render backend selection failed: %s" % player.get_last_error())
        _finish()
        return
    player.set_surface_size(1280, 720)
    if not _option("wa2.audio.silent", "1") or not _option("wa2.user_data_dir", profile_dir):
        _finish()
        return
    var entry := String(config.get("startup_script", "")).strip_edges()
    var opened: int = int(player.open_game(String(config["game_path"]), true, entry))
    if opened != 0:
        _fail("open_game_async result=%d: %s" % [opened, player.get_last_error()])
        _finish()
        return
    var started := false
    var deadline := Time.get_ticks_msec() + int(config.get("startup_timeout_ms", 120000))
    while Time.get_ticks_msec() < deadline:
        var startup: int = int(player.get_startup_state())
        if startup == STARTUP_SUCCEEDED:
            started = true
            break
        if startup == STARTUP_FAILED:
            _fail("startup failed: %s" % player.get_last_error())
            break
        await process_frame
    if not started:
        _fail("asynchronous startup did not succeed before deadline")
        _finish()
        return
    var state := _state()
    if not _healthy(state):
        _finish()
        return
    _check("silent", bool(state.get("audioSilent", false)), "runtime audioSilent=true")
    _check("isolated-profile", String(state.get("userDataDirectory", "")).replace("\\", "/").simplify_path() == profile_dir.replace("\\", "/").simplify_path(), profile_dir)
    if entry.is_empty():
        if not _check("title", state.get("state") == "title", JSON.stringify(state)) or not _capture("title"):
            _finish()
            return
        var trigger := String(config.get("new_game_input", "enter"))
        if trigger == "pointer":
            _click(640, 360)
        else:
            player.send_key_event(true, 13, 0, 0)
            player.send_key_event(false, 13, 0, 0)
        await _advance(1)
        state = _state()
        _check("new-game-input", state.get("state") == "story", "actual %s input entered story" % trigger)
        _capture("new-game")
    else:
        _check("chapter-entry", state.get("state") == "story" and state.get("script") == entry, entry)
        _capture("chapter-start")
    if failure.is_empty() and bool(config.get("ordinary_smoke", entry.is_empty())):
        await _ordinary_smoke()
    if failure.is_empty() and String(config.get("mode", "smoke")) != "smoke":
        await _drive()
    if failure.is_empty():
        _check("all-plan-consumed", consumed == plan.size(), "%d/%d" % [consumed, plan.size()])
        if bool(config.get("pending_choice_roundtrip", false)):
            _check("pending-roundtrip-performed", roundtrip_done, "requires a choice with two enabled rows")
        if bool(config.get("require_disabled_rejection", false)):
            _check("disabled-rejection-performed", disabled_checked, "requires a displayed disabled row")
        if config.has("expect_flag"):
            state = _state()
            var flag := int(config["expect_flag"])
            _check("ending", state.get("state") == "title" and int(state.get("gameFlags", {}).get(str(flag), 0)) == 1, "title with flag%d=1" % flag)
    _finish()

func _load_config() -> bool:
    var path := OS.get_environment("AETHERKIRI_WA2_CONFIG")
    if path.is_empty():
        path = OS.get_environment("AETHERKIRI_TEST_CONFIG")
    if path.is_empty() or not FileAccess.file_exists(path):
        return _fail("set AETHERKIRI_WA2_CONFIG to an existing JSON configuration")
    var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
    if not parsed is Dictionary:
        return _fail("configuration must be a JSON object: %s" % path)
    config = parsed
    if String(config.get("game_path", "")).is_empty() or String(config.get("output_dir", "")).is_empty():
        return _fail("game_path and output_dir are required")
    output_dir = ProjectSettings.globalize_path(String(config["output_dir"]))
    profile_dir = ProjectSettings.globalize_path(String(config.get("user_data_dir", output_dir.path_join("userdata"))))
    if DirAccess.make_dir_recursive_absolute(output_dir) != OK or DirAccess.make_dir_recursive_absolute(profile_dir) != OK:
        return _fail("cannot create output/profile directories")
    max_frames = int(config.get("max_frames", 300000))
    if max_frames <= 0 or int(config.get("save_slot", 8)) < 0 or int(config.get("save_slot", 8)) > 9:
        return _fail("max_frames must be positive and save_slot must be 0..9")
    var mode := String(config.get("mode", "smoke"))
    if not mode in ["smoke", "route", "chapter"]:
        return _fail("mode must be smoke, route or chapter")
    if mode == "smoke" and not String(config.get("startup_script", "")).is_empty():
        return _fail("smoke must open title; use chapter for startup_script")
    if mode == "chapter" and String(config.get("startup_script", "")).is_empty():
        return _fail("chapter requires startup_script")
    if mode == "route" and (not config.has("expect_flag") or String(config.get("choice_plan", "")).is_empty()):
        return _fail("route requires choice_plan and expect_flag")
    if config.has("expect_flag") and (int(config["expect_flag"]) < 0 or int(config["expect_flag"]) > 33):
        return _fail("expect_flag must be a debug-visible flag 0..33")
    return true

func _load_plan() -> bool:
    var path := String(config.get("choice_plan", ""))
    if path.is_empty():
        return true
    if not FileAccess.file_exists(path):
        return _fail("choice plan not found: %s" % path)
    var bytes := FileAccess.get_file_as_bytes(path)
    var text := bytes.get_string_from_utf8()
    if text.to_utf8_buffer() != bytes or text.contains(String.chr(0)):
        return _fail("choice plan must be valid UTF8 without NUL: %s" % path)
    text = text.trim_prefix(String.chr(0xfeff))
    var columns := RegEx.new()
    columns.compile("^([A-Za-z0-9_]+)\\s+([0-9]+)\\s+([0-9]+)$")
    var line := 0
    for raw_line in text.split("\n"):
        line += 1
        var body := String(raw_line).split("#", true, 1)[0].strip_edges()
        if body.is_empty():
            continue
        var match_line := columns.search(body)
        if match_line == null:
            return _fail("%s:%d: expected script group raw_row" % [path, line])
        var group := match_line.get_string(2)
        var row := match_line.get_string(3)
        if group.length() > 10 or row.length() > 10 or group.to_int() > 2147483647 or row.to_int() > 2147483647:
            return _fail("%s:%d: group/raw_row overflow" % [path, line])
        plan.append({"script": match_line.get_string(1), "group": group.to_int(), "raw_row": row.to_int(), "line": line})
    if plan.is_empty():
        return _fail("choice plan is empty: %s" % path)
    return true

func _find_runtime(value, depth: int = 0) -> Dictionary:
    if depth > 8:
        return {}
    if value is String:
        return _find_runtime(JSON.parse_string(value), depth + 1)
    if value is Dictionary:
        if value.has("choicePending") and value.has("scriptGlobals"):
            return value
        for key in ["backendDebug", "runtimeDebug", "providerDebug", "debug", "runtime"]:
            if value.has(key):
                var found := _find_runtime(value[key], depth + 1)
                if not found.is_empty():
                    return found
        for child in value.values():
            if child is Dictionary or child is String:
                var found := _find_runtime(child, depth + 1)
                if not found.is_empty():
                    return found
    return {}

func _state() -> Dictionary:
    var raw: String = String(player.get_plugin_debug_info())
    var parsed = JSON.parse_string(raw)
    last_debug = parsed if parsed is Dictionary else {"raw": raw}
    last_runtime = _find_runtime(parsed)
    if last_runtime.is_empty():
        _fail("WA2 debug state absent in get_plugin_debug_info: %s" % raw.left(1200))
    return last_runtime

func _healthy(state: Dictionary) -> bool:
    if state.is_empty():
        return false
    for key in ["error", "scriptError", "providerError"]:
        if not String(state.get(key, "")).is_empty():
            return _fail("runtime %s=%s at %s:%s" % [key, state[key], state.get("script"), state.get("pc")])
    if not bool(state.get("audioSilent", false)):
        return _fail("silent contract violated: audioSilent=false")
    # Silent movie completion may enqueue lifecycle STOP events. It must never
    # enqueue a PLAY event or initialize a sound output path.
    for event in state.get("pendingAudio", []):
        if event.get("action") == "play":
            return _fail("silent contract violated: pending PLAY event %s" % JSON.stringify(event))
    return true

func _option(key: String, value: String) -> bool:
    var result: int = int(player.set_engine_option(key, value))
    if result != 0:
        return _fail("option %s=%s result=%d error=%s" % [key, value, result, player.get_last_error()])
    return true

func _tick() -> bool:
    if not failure.is_empty():
        return false
    if frames >= max_frames:
        return _fail("frame cap %d reached; plan=%d/%d state=%s" % [max_frames, consumed, plan.size(), JSON.stringify(last_runtime)])
    var result: int = int(player.tick(0.016))
    frames += 1
    if result != 0:
        return _fail("tick failed result=%d error=%s" % [result, player.get_last_error()])
    var state := _state()
    if not _healthy(state):
        return false
    # A silent host still owns the audio transport: known lifecycle STOP and
    # VOLUME commands require acknowledgements or their queue grows indefinitely.
    # _healthy already rejected PLAY; preserve unfamiliar actions for diagnosis.
    for event in state.get("pendingAudio", []):
        if event.get("action") in ["stop", "volume"]:
            if not _option("wa2.audio.finished", str(int(event.get("id", -1)))):
                return false
            audio_acks += 1
    if bool(state.get("movieWaiting", false)):
        if not bool(config.get("finish_movies", true)):
            return _fail("movie pending; configure finish_movies for this headless run")
        if not _capture("movie-%02d-before-finish" % movies_finished) or not _option("wa2.movie.finish", "seen"):
            return false
        movies_finished += 1
    var log_every := maxi(1, int(config.get("log_every", 1000)))
    if frames % log_every == 0:
        print("[wa2-godot] tick=%d script=%s pc=%s logic=%s wait=%s plan=%d/%d" % [frames, state.get("script"), state.get("pc"), state.get("logicTicks"), state.get("waitLatch"), consumed, plan.size()])
        _drain_logs()
    var capture_every := int(config.get("capture_every", 500))
    if capture_every > 0 and frames % capture_every == 0:
        return _capture("frame-%08d" % frames)
    return true

func _advance(count: int) -> bool:
    for i in range(count):
        if not _tick():
            return false
        if frames % 16 == 0:
            await process_frame
    return failure.is_empty()

func _click(x: int = 640, y: int = 560) -> void:
    player.send_pointer_event(2, 0, float(x), float(y), 0.0, 0.0, 0)
    player.send_pointer_event(1, 0, float(x), float(y), 0.0, 0.0, 0)
    player.send_pointer_event(3, 0, float(x), float(y), 0.0, 0.0, 0)

func _page_signature(state: Dictionary) -> Array:
    return [state.get("script"), state.get("pc"), state.get("pageIndex"), state.get("pageText")]

func _checkpoint(state: Dictionary) -> Dictionary:
    var exact: Dictionary = {}
    for key in ["state", "script", "pc", "scriptWaiting", "scriptEnded", "waitLatch", "choicePending", "choiceGroup", "scriptGlobals", "pageIndex", "pageText"]:
        exact[key] = state.get(key)
    var rows: Array = []
    for choice in state.get("choices", []):
        rows.append([choice.get("displayRow"), choice.get("rawRow"), choice.get("enabled"), choice.get("text")])
    exact["choices"] = rows
    return exact

func _compare_checkpoint(name: String, before: Dictionary, after: Dictionary, detail: String) -> bool:
    var expected := _checkpoint(before)
    var actual := _checkpoint(after)
    var differences: Array = []
    for key in expected.keys():
        if expected[key] != actual.get(key):
            differences.append({"field": key, "expected": expected[key], "actual": actual.get(key)})
    if not differences.is_empty():
        var evidence := {"check": name, "driverFrames": frames, "differences": differences, "expectedCheckpoint": expected, "actualCheckpoint": actual}
        checkpoint_differences.append(evidence)
        _write_json(output_dir.path_join("checkpoint-%s-diff.json" % name), evidence)
        printerr("[wa2-godot] checkpoint-diff %s" % JSON.stringify(evidence))
    return _check(name, differences.is_empty(), detail if differences.is_empty() else "%s; differences=%s" % [detail, JSON.stringify(differences)])

func _wait_save_ready(label: String) -> Dictionary:
    var before := _state()
    if not before.has("saveReady"):
        _fail("native saveReady debug field is required before saving")
        return {}
    var checkpoint := _checkpoint(before)
    var began := frames
    var limit := int(config.get("save_ready_timeout_frames", 2000))
    if limit <= 0:
        _fail("save_ready_timeout_frames must be positive")
        return {}
    for i in range(limit + 1):
        var state := _state()
        if _checkpoint(state) != checkpoint:
            _compare_checkpoint("%s-save-ready-wait" % label, before, state, "VM/globals/choice must remain parked while native busy animations settle")
            return {}
        if bool(state.get("saveReady", false)):
            var evidence := {"label": label, "waitedFrames": frames - began, "driverFrames": frames, "script": state.get("script"), "pc": state.get("pc"), "choicePending": state.get("choicePending"), "choiceGroup": state.get("choiceGroup"), "saveReady": true}
            save_ready_waits.append(evidence)
            print("[wa2-godot] save-ready %s" % JSON.stringify(evidence))
            return state
        if i == limit:
            _fail("native saveReady timed out after%dframes at%s:%s group=%s" % [limit, state.get("script"), state.get("pc"), state.get("choiceGroup")])
            return {}
        if not await _advance(1):
            return {}
    return {}

func _ordinary_smoke() -> void:
    if not _option("wa2.skip", "0"):
        return
    for i in range(int(config.get("message_seek_frames", 10000))):
        var state := _state()
        if state.get("waitLatch") == "message" and not bool(state.get("choicePending", false)):
            break
        if not await _advance(1):
            return
    var before := _state()
    if not _check("ordinary-message", before.get("waitLatch") == "message" and not bool(before.get("choicePending", false)), "first message reached without SKIP"):
        return
    await _advance(180)
    before = _state()
    if not _check("skip-off-parks", not bool(before.get("skip", true)), "SKIP disabled while message remains interactive"):
        return
    var parked := _page_signature(before)
    await _advance(8)
    if not _check("no-autoadvance", _page_signature(_state()) == parked, "message remains parked with SKIP off"):
        return
    _capture("ordinary-before-click")
    _click()
    await _advance(1)
    if _page_signature(_state()) == parked:
        _click()
        await _advance(1)
    if not _check("ordinary-click", _page_signature(_state()) != parked, "real pointer click advances page/VM"):
        return
    # Seek a message parking point again before testing ordinary save/load.
    for i in range(3000):
        var state := _state()
        if state.get("waitLatch") == "message" and not bool(state.get("choicePending", false)):
            break
        if not await _advance(1):
            return
    before = _state()
    if not _check("ordinary-save-point", before.get("waitLatch") == "message" and not bool(before.get("choicePending", false)), "message point"):
        return
    before = await _wait_save_ready("ordinary")
    if before.is_empty():
        return
    _capture("ordinary-save-before")
    var slot := str(int(config.get("save_slot", 8)))
    if not _option("wa2.save.slot", slot):
        return
    _click()
    await _advance(1)
    _click()
    await _advance(1)
    _capture("ordinary-away")
    if not _option("wa2.load.slot", slot):
        return
    var loaded := _state()
    _capture("ordinary-load-after")
    _compare_checkpoint("ordinary-load", before, loaded, "script/PC/page/globals/wait restored exactly")

func _hold_choice(label: String) -> Dictionary:
    var before := _state()
    var parked := _checkpoint(before)
    for i in range(4):
        if not await _advance(1):
            return {}
        if _checkpoint(_state()) != parked:
            _fail("choice moved during four-tick hold: %s" % JSON.stringify(_state()))
            return {}
    if not _capture(label):
        return {}
    return _state()

func _answer(raw_row: int, label: String) -> Dictionary:
    var before := await _hold_choice(label)
    if before.is_empty():
        return {}
    var count := int(before.get("choicesAccepted", 0))
    if not _option("wa2.choice.raw_row", str(raw_row)):
        return {}
    var after := _state()
    if not _check("choice-accepted", int(after.get("choicesAccepted", -1)) == count + 1 and int(after.get("lastChoiceRawRow", -1)) == raw_row, "raw_row=%d" % raw_row):
        return {}
    return after

func _pending_roundtrip(correct: int, wrong: int) -> bool:
    if not _option("wa2.skip", "0"):
        return false
    var baseline := await _wait_save_ready("pending")
    if baseline.is_empty():
        return false
    var slot := str(int(config.get("save_slot", 8)))
    var baseline_rgba := _read_rgba()
    if baseline_rgba.is_empty() or not _capture("pending-save-before", baseline_rgba):
        return false
    if not _option("wa2.save.slot", slot):
        return false
    # No tick, await or input occurs across this save comparison.
    var saved_rgba := _read_rgba()
    if saved_rgba.is_empty() or not _capture("pending-save-after", saved_rgba):
        return false
    if not _compare_frame("pending-save-preserves-frame", baseline_rgba, saved_rgba, false):
        return false
    # Reference answer establishes the exact once-only affection/global result.
    var reference := await _answer(correct, "pending-reference-before")
    if reference.is_empty() or not _option("wa2.load.slot", slot):
        return false
    var reference_loaded_rgba := _read_rgba()
    if reference_loaded_rgba.is_empty() or not _capture("pending-reference-load-after", reference_loaded_rgba):
        return false
    if not _compare_frame("pending-reference-load-stage", saved_rgba, reference_loaded_rgba, true):
        return false
    if not _compare_checkpoint("pending-reference-load", baseline, _state(), "pending VM/choice/globals restored"):
        return false
    var wrong_result := await _answer(wrong, "pending-wrong-before")
    if wrong_result.is_empty():
        return false
    _capture("pending-wrong-after")
    if not _option("wa2.load.slot", slot):
        return false
    var loaded := _state()
    var loaded_rgba := _read_rgba()
    if loaded_rgba.is_empty() or not _capture("pending-load-after", loaded_rgba):
        return false
    if not _compare_frame("pending-load-stage", saved_rgba, loaded_rgba, true):
        return false
    if not _compare_checkpoint("pending-exact-load", baseline, loaded, "same script/PC/group/page/globals/visible original rows"):
        return false
    var flags_kept := true
    for flag in wrong_result.get("gameFlags", {}).keys():
        if int(wrong_result["gameFlags"][flag]) != int(loaded.get("gameFlags", {}).get(flag, -1)):
            flags_kept = false
    if not _check("pending-system-flags-kept", flags_kept, "system flags survive load"):
        return false
    # Pending entries retain their saved chosen decoration; the live system
    # history bitmask must be inspected separately from that cached UI field.
    var history_bits := _history_bits(baseline)
    var tested_bits := (1 << correct) | (1 << wrong)
    if not _check("pending-history-kept", history_bits >= 0 and (history_bits & tested_bits) == tested_bits, "live history bitmask retains both tested original rows after load"):
        return false
    var answered := await _answer(correct, "pending-reanswer-before")
    _capture("pending-reanswer-after")
    if answered.is_empty():
        return false
    if not _check("pending-affection-once", answered.get("scriptGlobals") == reference.get("scriptGlobals") and _page_signature(answered) == _page_signature(reference), "wrong-branch effects removed; reanswer equals one clean answer"):
        return false
    roundtrip_done = true
    return true

func _history_bits(state: Dictionary) -> int:
    # Same fixed native script-table index used by Wa2Runtime::OpenChoice.
    var scripts := [2003, 2004, 2005, 2007, 2009, 2011, 2013, 2014, 2015, 2016, 2017, 2018, 2019, 2024, 2503, 3003, 3005, 3009, 3012, 3013, 3014, 3016, 3904]
    var index := scripts.find(String(state.get("script", "")).to_int())
    var flag := 992 if index < 0 else 900 + 4 * index + int(state.get("choiceGroup", 0))
    var path := profile_dir.path_join("sysflags.bin")
    if not FileAccess.file_exists(path):
        _fail("persisted history file missing: %s" % path)
        return -1
    var data := FileAccess.get_file_as_bytes(path)
    if data.size() != 4116 or data.slice(0, 8).get_string_from_ascii() != "LTTTSYS1" or data.decode_u32(8) != 1 or data.decode_u32(12) != 1024:
        _fail("invalid persisted system flag header/size")
        return -1
    var checksum: int = 2166136261
    for i in range(data.size() - 4):
        checksum = ((checksum ^ int(data[i])) * 16777619) & 0xffffffff
    if checksum != data.decode_u32(data.size() - 4):
        _fail("persisted system flag checksum mismatch")
        return -1
    var bits: int = int(data.decode_u32(16 + 4 * flag))
    print("[wa2-godot] persisted-history flag=%d bits=%d file=%s" % [flag, bits, path])
    return bits

func _drive() -> void:
    if not _option("wa2.skip", "1"):
        return
    var chapter_end := frames + int(config.get("chapter_frames", 1200))
    while failure.is_empty():
        var state := _state()
        if not _healthy(state):
            return
        if state.get("state") == "title":
            return
        if bool(state.get("choicePending", false)):
            if not _option("wa2.skip", "0"):
                return
            state = await _hold_choice("choice-%04d-before" % (consumed + 1))
            if state.is_empty():
                return
            if consumed >= plan.size():
                _fail("plan exhausted at %s group=%s pc=%s rows=%s consumed=%d/%d" % [state.get("script"), state.get("choiceGroup"), state.get("pc"), JSON.stringify(state.get("choices")), consumed, plan.size()])
                return
            var next: Dictionary = plan[consumed]
            if next["script"] != state.get("script") or int(next["group"]) != int(state.get("choiceGroup", -1)):
                _fail("plan line%d expected=%s actual=%s group=%s pc=%s rows=%s consumed=%d/%d" % [next["line"], JSON.stringify(next), state.get("script"), state.get("choiceGroup"), state.get("pc"), JSON.stringify(state.get("choices")), consumed, plan.size()])
                return
            var selected := false
            var wrong := -1
            for row in state.get("choices", []):
                if int(row.get("rawRow", -1)) == int(next["raw_row"]):
                    selected = bool(row.get("enabled", false))
                elif bool(row.get("enabled", false)):
                    wrong = int(row.get("rawRow", -1))
            if not selected:
                _fail("plan line%d absent/disabled raw_row=%d at%s group=%s pc=%s rows=%s" % [next["line"], next["raw_row"], state.get("script"), state.get("choiceGroup"), state.get("pc"), JSON.stringify(state.get("choices"))])
                return
            if not disabled_checked:
                for row in state.get("choices", []):
                    if not bool(row.get("enabled", false)):
                        var rejected: int = int(player.set_engine_option("wa2.choice.raw_row", str(int(row["rawRow"]))))
                        var unchanged := _state()
                        if not _check("disabled-row-rejected", rejected != 0 and _checkpoint(unchanged) == _checkpoint(state) and unchanged.get("choicesAccepted") == state.get("choicesAccepted"), "disabled original row refuses input without VM/global change"):
                            return
                        disabled_checked = true
                        if not _option("wa2.skip", "0"):
                            return
                        break
            if bool(config.get("pending_choice_roundtrip", false)) and not roundtrip_done and wrong >= 0:
                if not await _pending_roundtrip(int(next["raw_row"]), wrong):
                    return
            elif (await _answer(int(next["raw_row"]), "choice-%04d-select-before" % (consumed + 1))).is_empty():
                return
            consumed += 1
            print("[wa2-godot] choice script=%s group=%s pc=%s raw_row=%s consumed=%d/%d held_ticks=4" % [state.get("script"), state.get("choiceGroup"), state.get("pc"), next["raw_row"], consumed, plan.size()])
            var stop_after := int(config.get("stop_after_choices", 0))
            if stop_after > 0 and consumed >= stop_after:
                return
            if not _option("wa2.skip", "1"):
                return
        elif String(config.get("mode", "smoke")) == "chapter" and plan.is_empty() and frames >= chapter_end:
            return
        if not await _advance(1):
            return

func _read_rgba() -> PackedByteArray:
    var frame: Dictionary = player.read_frame_rgba()
    var rgba: PackedByteArray = frame.get("rgba", PackedByteArray())
    var width := int(frame.get("width", 0))
    var height := int(frame.get("height", 0))
    if width != 1280 or height != 720 or rgba.size() != width * height * 4:
        _fail("invalid actual engine RGBA frame: %s bytes=%d" % [frame.keys(), rgba.size()])
        return PackedByteArray()
    return rgba

func _rgba_hash(rgba: PackedByteArray) -> String:
    var context := HashingContext.new()
    context.start(HashingContext.HASH_SHA256)
    context.update(rgba)
    return context.finish().hex_encode()

func _stage_pixels(rgba: PackedByteArray) -> PackedByteArray:
    # Compare all RGBA channels of every pixel above the message window,
    # except the choice-card/history region (inclusive x330..1010,y290..410).
    var stage := PackedByteArray()
    stage.append_array(rgba.slice(0, 290 * 1280 * 4))
    for y in range(290, 411):
        stage.append_array(rgba.slice(y * 1280 * 4, (y * 1280 + 330) * 4))
        stage.append_array(rgba.slice((y * 1280 + 1011) * 4, (y + 1) * 1280 * 4))
    stage.append_array(rgba.slice(411 * 1280 * 4, 480 * 1280 * 4))
    return stage

func _compare_frame(name: String, before: PackedByteArray, after: PackedByteArray, mask_stage: bool) -> bool:
    var expected := _stage_pixels(before) if mask_stage else before
    var actual := _stage_pixels(after) if mask_stage else after
    var evidence := {"check": name, "driverFrames": frames, "maskStage": mask_stage, "comparedBytes": expected.size(), "expectedRgbaSha256": _rgba_hash(expected), "actualRgbaSha256": _rgba_hash(actual), "pass": expected == actual}
    frame_comparisons.append(evidence)
    print("[wa2-godot] frame-comparison %s" % JSON.stringify(evidence))
    _write_json(output_dir.path_join("frame-%s-comparison.json" % name), evidence)
    return _check(name, expected == actual, JSON.stringify(evidence))

func _capture(label: String, captured_rgba: PackedByteArray = PackedByteArray()) -> bool:
    var state := _state()
    var rgba := captured_rgba if not captured_rgba.is_empty() else _read_rgba()
    if rgba.is_empty():
        return false
    var image := Image.create_from_data(1280, 720, false, Image.FORMAT_RGBA8, rgba)
    var path := output_dir.path_join(label)
    if image.save_png(path + ".png") != OK:
        return _fail("cannot write PNG: %s" % path)
    var metadata := {"label": label, "driverFrames": frames, "fixedDeltaMs": 16, "captureSource": "engineRGBA", "rgbaSha256": _rgba_hash(rgba), "stageRgbaSha256": _rgba_hash(_stage_pixels(rgba)), "stageMaskExcluded": [{"x": 0, "y": 480, "width": 1280, "height": 240}, {"x": 330, "y": 290, "width": 681, "height": 121}], "renderBackend": player.get_render_backend(), "textureBackend": player.get_frame_texture_backend(), "rendererInfo": player.get_renderer_info(), "choicePlan": config.get("choice_plan", ""), "planConsumed": consumed, "planTotal": plan.size(), "planComplete": consumed == plan.size(), "roundtripDone": roundtrip_done, "saveReadyWaits": save_ready_waits, "audioAcks": audio_acks, "nextPlan": plan[consumed] if consumed < plan.size() else null, "runtime": state, "debug": last_debug, "failure": failure}
    if not _write_json(path + ".json", metadata):
        return false
    capture_index += 1
    print("[wa2-godot] capture=%s script=%s pc=%s" % [label, state.get("script"), state.get("pc")])
    return true

func _write_json(path: String, data: Dictionary) -> bool:
    var file := FileAccess.open(path, FileAccess.WRITE)
    if file == null:
        return _fail("cannot write JSON: %s" % path)
    file.store_string(JSON.stringify(data, "  ") + "\n")
    file.close()
    return true

func _check(name: String, good: bool, detail: String) -> bool:
    checks.append({"name": name, "pass": good, "detail": detail})
    print("[wa2-godot] %s %s %s" % [name, "PASS" if good else "FAIL", detail])
    if not good:
        return _fail("%s: %s" % [name, detail])
    return true

func _fail(message: String) -> bool:
    if failure.is_empty():
        failure = message
        printerr("[wa2-godot] FAIL %s" % message)
    return false

func _drain_logs() -> void:
    var logs: String = String(player.drain_startup_logs())
    if logs.is_empty():
        return
    var file := FileAccess.open(output_dir.path_join("runtime.log"), FileAccess.READ_WRITE if FileAccess.file_exists(output_dir.path_join("runtime.log")) else FileAccess.WRITE)
    if file != null:
        file.seek_end()
        file.store_string(logs + "\n")
        file.close()

func _finish() -> void:
    if player != null and not last_runtime.is_empty():
        _capture("final")
        _drain_logs()
    var summary := {"pass": failure.is_empty(), "failure": failure, "mode": config.get("mode", "smoke"), "frames": frames, "captures": capture_index, "planConsumed": consumed, "planTotal": plan.size(), "roundtripDone": roundtrip_done, "disabledChecked": disabled_checked, "moviesFinished": movies_finished, "audioAcks": audio_acks, "checks": checks, "checkpointDifferences": checkpoint_differences, "frameComparisons": frame_comparisons, "saveReadyWaits": save_ready_waits, "runtime": last_runtime}
    if not output_dir.is_empty():
        _write_json(output_dir.path_join("report.json"), summary)
    print("[wa2-godot] RESULT %s" % JSON.stringify(summary))
    if player != null:
        player.release_frame_texture()
        player.destroy_engine()
    quit(0 if failure.is_empty() else 1)
