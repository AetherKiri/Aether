extends Node

# Run as the main scene in a disposable copy of apps/godot_app using a real
# Godot binary. This checks the production row helpers and request consumption;
# it does not initialize a native engine or manufacture mobile startup phases.
const Main = preload("res://scripts/main.gd")
const ProbeConfig = preload("res://scripts/probe_config.gd")
const RUN_ID := "0123456789abcdef0123456789abcdef"
const PHASES := [
    "main_ready_entered", "ui_build_entered", "ui_build_ready",
    "player_create_entered", "player_create_ready", "player_create_failed",
    "ready_frame_pending", "ready_frame_entered",
    "engine_initialize_entered", "engine_initialize_ready", "engine_initialize_failed",
    "observer_create_entered", "observer_create_ready",
    "observer_start_entered", "observer_start_returned",
]

var checks := 0
var failures := 0

func _check(condition: bool, label: String) -> void:
    checks += 1
    if not condition:
        failures += 1
        push_error("startup diagnostic regression failed: " + label)

func _ready() -> void:
    var request := {"probe_script": "res://scripts/renpy_mobile_acceptance.gd",
        "run_id": RUN_ID, "game_path": "user://request-fixture", "timeout_seconds": 600}
    _check(Main._renpy_startup_request_run_id(request) == RUN_ID, "acceptance request identity")
    for candidate in [null, 123, "", RUN_ID.to_upper(), RUN_ID + "0", "../private/path", "g".repeat(32)]:
        var invalid := request.duplicate()
        invalid["run_id"] = candidate
        _check(Main._renpy_startup_request_run_id(invalid).is_empty(), "invalid identity is refused")
    var unrelated := request.duplicate()
    unrelated["probe_script"] = "res://scripts/smoke_test.gd"
    _check(Main._renpy_startup_request_run_id(unrelated).is_empty(), "other probe identity is refused")
    _check(Main.RENPY_STARTUP_PHASES == PHASES, "fixed phase whitelist")

    # These are protocol rows, not evidence that any runtime phase executed.
    for index in range(PHASES.size()):
        var row: Dictionary = Main._renpy_startup_phase_row(RUN_ID, index + 1, PHASES[index], 1000 + index)
        _check(row.size() == 4 and row.run_id == RUN_ID and row.seq == index + 1 \
            and row.phase == PHASES[index] and row.ticks_msec == 1000 + index, "fixed row sequence")
    var result_row: Dictionary = Main._renpy_startup_phase_row(RUN_ID, 1, PHASES[0], 0, -2147483648)
    _check(result_row.size() == 5 and result_row.result == -2147483648, "signed result lower boundary")
    _check(not Main._renpy_startup_phase_row(RUN_ID, 64, PHASES[0], Main.RENPY_STARTUP_TRACE_MAX_TICKS, 2147483647).is_empty(), "upper boundaries")
    for value in [0, 65, true, 1.0, "1"]:
        _check(Main._renpy_startup_phase_row(RUN_ID, value, PHASES[0], 0).is_empty(), "invalid sequence is refused")
    for value in [-1, Main.RENPY_STARTUP_TRACE_MAX_TICKS + 1, true, 1.0, "1"]:
        _check(Main._renpy_startup_phase_row(RUN_ID, 1, PHASES[0], value).is_empty(), "invalid clock is refused")
    for value in [-2147483649, 2147483648, true, 1.0, "1"]:
        _check(Main._renpy_startup_phase_row(RUN_ID, 1, PHASES[0], 0, value).is_empty(), "invalid result is refused")
    _check(Main._renpy_startup_phase_row(RUN_ID, 1, "private arbitrary message", 0).is_empty(), "unknown phase is refused")

    var main := Main.new()
    var trace_path := ProjectSettings.globalize_path(Main.RENPY_STARTUP_TRACE_PATH)
    _check(not FileAccess.file_exists(trace_path), "disposable trace initially absent")
    main._record_renpy_startup_phase(PHASES[0])
    _check(not FileAccess.file_exists(trace_path), "no request produces no trace")
    var file := FileAccess.open(ProbeConfig.debug_request_path(), FileAccess.WRITE)
    _check(file != null, "real debug request opened")
    if file != null:
        file.store_string(JSON.stringify(request))
        file.close()
        _check(main._detect_cli_probe_script() == request.probe_script, "production Main detects acceptance")
        _check(not FileAccess.file_exists(ProbeConfig.debug_request_path()), "request consumed once")
        var parsed: Dictionary = JSON.parse_string(JSON.stringify(request))
        _check(ProbeConfig.load() == parsed and ProbeConfig.load() == parsed, "cached request survives repeated reads")
    if not OS.is_debug_build() or OS.get_name() not in ["Android", "iOS"]:
        _check(main.renpy_startup_trace_run_id.is_empty(), "actual nonmobile platform does not enable trace")
        main._configure_renpy_startup_trace(request)
        main._record_renpy_startup_phase(PHASES[0])
        _check(not FileAccess.file_exists(trace_path), "actual nonmobile writer is a no-op")
    main.ui_motion.free()
    main.free()

    var evidence := {"status": "passed" if failures == 0 else "failed", "checks": checks,
        "failures": failures, "godot_version": Engine.get_version_info().string,
        "platform": OS.get_name(), "protocol_rows_only": true,
        "native_runtime_executed": false, "mobile_gameplay_executed": false}
    print(JSON.stringify(evidence))
    var output := FileAccess.open("res://startup-diagnostics-test.json", FileAccess.WRITE)
    if output != null:
        output.store_string(JSON.stringify(evidence))
        output.close()
    get_tree().quit(0 if failures == 0 else 1)
