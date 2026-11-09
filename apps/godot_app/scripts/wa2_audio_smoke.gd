extends SceneTree

# Bounded, audible integration check through the normal main scene and launch
# path. Run with a real audio driver (no --headless / Dummy) and SILENT unset.
# -- --wa2-audio-game-root <install> --wa2-audio-output <dir>
const AudioHost = preload("res://scripts/wa2_audio_host.gd")
var app
var output_dir := ""
var failure := ""
var checks: Array[Dictionary] = []
var original_library := PackedByteArray()
var had_library := false
var library_changed := false
var capture: AudioEffectCapture
var capture_index := -1
var peak_left := 0.0
var peak_right := 0.0
var energy_left := 0.0
var energy_right := 0.0
var mixed_frames := 0
var seen_channels: Dictionary = {}
var source_pcm: Dictionary = {}
var snapshots: Array = []
var final_state: Dictionary = {}
var voice_seq := 0
var voice_pending_while_playing := false
var driver := "unknown"

func _initialize() -> void:
    _run.call_deferred()

func _argument(name: String, fallback: String = "") -> String:
    var args := OS.get_cmdline_user_args()
    for index in range(args.size() - 1):
        if args[index] == name:
            return args[index + 1]
    return fallback

func _run() -> void:
    output_dir = _argument("--wa2-audio-output", ProjectSettings.globalize_path("user://wa2-audio-smoke"))
    DirAccess.make_dir_recursive_absolute(output_dir)
    var game_root := _argument("--wa2-audio-game-root", OS.get_environment("AETHER_WA2_GAME_ROOT"))
    if AudioServer.has_method("get_driver_name"):
        driver = String(AudioServer.call("get_driver_name"))
    if not _check("real-audio-driver", driver != "Dummy" and DisplayServer.get_name() != "headless" and OS.get_environment("AETHER_WA2_SILENT") != "1", driver):
        _finish()
        return
    capture = AudioEffectCapture.new()
    capture.buffer_length = 1.0
    capture_index = AudioServer.get_bus_effect_count(0)
    AudioServer.add_bus_effect(0, capture)
    if not _check("master-output-enabled", not AudioServer.is_bus_mute(0) and AudioServer.get_bus_volume_db(0) > -60.0, "device=%s rate=%s master_db=%s" % [AudioServer.output_device, AudioServer.get_mix_rate(), AudioServer.get_bus_volume_db(0)]):
        _finish()
        return
    had_library = FileAccess.file_exists("user://aetherkiri_games.json")
    if had_library:
        original_library = FileAccess.get_file_as_bytes("user://aetherkiri_games.json")
    var empty := FileAccess.open("user://aetherkiri_games.json", FileAccess.WRITE)
    empty.store_string("[]")
    empty.close()
    library_changed = true
    app = load("res://scenes/main.tscn").instantiate()
    root.add_child(app)
    app.legal_accepted_version = app.LEGAL_AGREEMENT_VERSION
    app.ios_statement_accepted_version = app.IOS_STATEMENT_VERSION
    app.wa2_import_root = ""
    app.wa2_auto_launch = false
    app.debug_overlay_mode = "off"
    app.show_perf_monitor = false
    app.announcement_state.dismiss(app.NOTICE_ID, app.NOTICE_VERSION)
    var deadline := Time.get_ticks_msec() + 15000
    while Time.get_ticks_msec() < deadline:
        if app.player != null and app.player.is_initialized() and app.legal_gate_completed:
            break
        await process_frame
    if not _check("official-main-ready", app.player != null and app.player.is_initialized(), "res://scenes/main.tscn"):
        _finish()
        return
    if not _check("real-import", app._add_game_path(game_root), game_root):
        _finish()
        return
    app._show_home()
    for _index in range(3):
        await process_frame
    app.selected_game = app._find_known_game_by_path(game_root).duplicate(true)
    app._show_detail(app.selected_game)
    for _index in range(4):
        await process_frame
    app._start_selected_game()
    deadline = Time.get_ticks_msec() + 45000
    while Time.get_ticks_msec() < deadline:
        _collect()
        if app.game_running and app.cached_startup_state == app.STARTUP_SUCCEEDED:
            break
        if app.cached_startup_state == app.STARTUP_FAILED:
            break
        await process_frame
    if not _check("normal-wa2-session", app.game_running and app.active_runtime_kind == "wa2" and is_instance_valid(app.wa2_audio_host), String(app.player.get_last_error())):
        _finish()
        return
    final_state = AudioHost.runtime_state(app.player.get_plugin_debug_info())
    if not _check("native-nonsilent", not bool(final_state.get("audioSilent", true)), "audioSilent=%s" % final_state.get("audioSilent")):
        _finish()
        return
    var input_deadline := Time.get_ticks_msec() + 5000
    while Time.get_ticks_msec() < input_deadline and not app._can_forward_game_input():
        await process_frame
    print("[wa2-audio-smoke] inputReady=%s modal=%s viewport=%s" % [app._can_forward_game_input(), app.modal_layer.visible, app.viewport.get_global_rect()])
    if String(final_state.get("state", "")) == "title":
        await _click(app._map_surface_point_to_viewport(Vector2(640, 380)))
    var audio_deadline := Time.get_ticks_msec() + 40000
    var skip_enabled := false
    var next_advance := Time.get_ticks_msec() + 500
    var finished_voice := false
    while Time.get_ticks_msec() < audio_deadline:
        _collect()
        final_state = AudioHost.runtime_state(app.player.get_plugin_debug_info())
        if String(final_state.get("script", "")) == "1001" and not skip_enabled:
            app.player.set_engine_option("wa2.skip", "1")
            skip_enabled = true
        elif skip_enabled and String(final_state.get("script", "")) != "1001":
            app.player.set_engine_option("wa2.skip", "0")
            skip_enabled = false
        var host = app.wa2_audio_host
        if not app.game_running or host.players.is_empty():
            _check("session-remains-active", false, String(app.player.get_last_error()))
            break
        var snapshot: Dictionary = host.debug_snapshot()
        if snapshots.is_empty() or Time.get_ticks_msec() - int(snapshots.back()["ms"]) >= 1000:
            snapshots.append({"ms": Time.get_ticks_msec(), "audio": snapshot, "script": final_state.get("script"), "pc": final_state.get("pc"), "wait": final_state.get("waitLatch")})
        for output: AudioStreamPlayer in host._all_players():
            if output.playing and output.stream != null:
                var state: Dictionary = host.states.get(output.get_instance_id(), {})
                var channel := String(state.get("channel", ""))
                seen_channels[channel] = true
                if channel == "voice0":
                    voice_seq = int(state.get("seq", 0))
                    for event in final_state.get("pendingAudio", []):
                        if int(event.get("id", 0)) == voice_seq:
                            voice_pending_while_playing = true
                if not source_pcm.has(channel):
                    source_pcm[channel] = _decoded_pcm(output.stream)
        finished_voice = seen_channels.has("voice0") and not host.players["voice0"].playing and int(snapshot["completionCount"]) > 0
        if finished_voice and (seen_channels.has("bgm0") or seen_channels.has("bgm1")) and peak_left > 0.001 and peak_right > 0.001:
            # Leave several frames for the finite completion ACK to drain.
            for _index in range(5):
                await process_frame
                _collect()
            break
        if Time.get_ticks_msec() >= next_advance:
            # Leave speech alone until it reaches ENDED. Advance a revealed
            # non-voiced page using the same Window input route as a real click.
            var voice: AudioStreamPlayer = host.players["voice0"]
            if not voice.playing:
                await _click(app._map_surface_point_to_viewport(Vector2(640, 620)))
            if bool(final_state.get("movieWaiting", false)):
                app.player.set_engine_option("wa2.movie.finish", "seen")
            next_advance = Time.get_ticks_msec() + 750
        await process_frame
    _check("bgm-playing", seen_channels.has("bgm0") or seen_channels.has("bgm1"), JSON.stringify(seen_channels))
    _check("voice-playing-and-completed", finished_voice, JSON.stringify(app.wa2_audio_host.debug_snapshot()))
    final_state = AudioHost.runtime_state(app.player.get_plugin_debug_info())
    var voice_still_pending := false
    for event in final_state.get("pendingAudio", []):
        if int(event.get("id", 0)) == voice_seq:
            voice_still_pending = true
    _check("voice-ack-after-finished", voice_pending_while_playing and not voice_still_pending, "seq=%d pending_while_playing=%s pending_after=%s" % [voice_seq, voice_pending_while_playing, voice_still_pending])
    _check("stereo-master-samples", mixed_frames > 0 and peak_left > 0.001 and peak_right > 0.001, "frames=%d peak=(%.6f, %.6f) energy=(%.6f, %.6f)" % [mixed_frames, peak_left, peak_right, energy_left, energy_right])
    var final_audio: Dictionary = app.wa2_audio_host.debug_snapshot()
    _check("bounded-audio-queue", int(final_audio["maxPending"]) < 32 and int(final_audio["pendingGuards"]) < 16 and int(final_audio["pendingAcks"]) < 16 and int(final_audio["loadFailures"]) == 0, JSON.stringify(final_audio))
    _finish()

func _decoded_pcm(stream: AudioStream) -> Dictionary:
    var result := {"length": stream.get_length(), "class": stream.get_class()}
    var playback := stream.instantiate_playback()
    if playback != null and playback.has_method("mix_audio"):
        playback.start()
        var samples: PackedVector2Array = playback.call("mix_audio", 1.0, 16384)
        var peak := 0.0
        for sample in samples:
            peak = maxf(peak, maxf(absf(sample.x), absf(sample.y)))
        playback.stop()
        result["decodedFrames"] = samples.size()
        result["peak"] = peak
    return result

func _collect() -> void:
    if capture == null:
        return
    var samples := capture.get_buffer(capture.get_frames_available())
    mixed_frames += samples.size()
    for sample in samples:
        peak_left = maxf(peak_left, absf(sample.x))
        peak_right = maxf(peak_right, absf(sample.y))
        energy_left += sample.x * sample.x
        energy_right += sample.y * sample.y

func _click(position: Vector2) -> void:
    var motion := InputEventMouseMotion.new()
    motion.position = position
    motion.global_position = position
    root.push_input(motion, true)
    await process_frame
    for pressed: bool in [true, false]:
        var event := InputEventMouseButton.new()
        event.button_index = MOUSE_BUTTON_LEFT
        event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
        event.pressed = pressed
        event.position = position
        event.global_position = position
        root.push_input(event, true)
        await process_frame

func _check(label: String, passed: bool, detail: String) -> bool:
    checks.append({"name": label, "pass": passed, "detail": detail})
    print("[wa2-audio-smoke] %s %s %s" % [label, "PASS" if passed else "FAIL", detail])
    if not passed:
        failure = label + ": " + detail
    return passed

func _finish() -> void:
    var final_audio := {}
    if app != null:
        if is_instance_valid(app.wa2_audio_host):
            final_audio = app.wa2_audio_host.debug_snapshot()
        app.game_running = false
        app._stop_wa2_audio()
        if app.player != null:
            app.player.destroy_engine()
    if capture_index >= 0:
        AudioServer.remove_bus_effect(0, capture_index)
    if library_changed and had_library:
        var restore := FileAccess.open("user://aetherkiri_games.json", FileAccess.WRITE)
        restore.store_buffer(original_library)
        restore.close()
    elif library_changed:
        DirAccess.remove_absolute(ProjectSettings.globalize_path("user://aetherkiri_games.json"))
    var result := {"pass": failure.is_empty(), "failure": failure, "checks": checks,
        "scene": "res://scenes/main.tscn", "driver": driver,
        "outputDevice": AudioServer.output_device, "audioSilent": final_state.get("audioSilent"),
        "mixedFrames": mixed_frames, "peakLeft": peak_left, "peakRight": peak_right,
        "energyLeft": energy_left, "energyRight": energy_right, "sourcePCM": source_pcm,
        "audio": final_audio, "snapshots": snapshots}
    var file := FileAccess.open(output_dir.path_join("result.json"), FileAccess.WRITE)
    if file != null:
        file.store_string(JSON.stringify(result, "  "))
        file.close()
    print("[wa2-audio-smoke] RESULT " + JSON.stringify(result))
    quit(0 if failure.is_empty() else 1)
