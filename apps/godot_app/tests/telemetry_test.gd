extends SceneTree

const Telemetry = preload("res://scripts/telemetry.gd")
const ENDPOINT := "https://telemetry.example/v1/events"
const PUBLIC_GAME := "世界の物語"
const COMMON_FIELDS := ["event_id", "install_id", "kind", "os", "arch", "ram_bucket", "gpu_family", "app_version", "build", "channel"]

class TestCollector extends "res://scripts/telemetry.gd":
    var now := 1_000
    var drawn := 100
    var memory := 0
    var identity_path := ""
    var fail_write := false
    var fail_remove := false
    var post_error: Error = OK
    var posts: Array[Dictionary] = []
    var cancellations := 0

    func _now_ms() -> int:
        return now

    func _drawn_frames() -> int:
        return drawn

    func _sample_memory_bytes() -> int:
        return memory

    func _install_id_path() -> String:
        return identity_path

    func _write_install_id(id: String) -> bool:
        return not fail_write and super._write_install_id(id)

    func _remove_install_id() -> bool:
        return not fail_remove and super._remove_install_id()

    func _device_dimensions() -> Dictionary:
        return {"os": "Linux", "arch": "x86_64", "ram_bucket": "8_15_gb", "gpu_family": "unknown"}

    func _start_post(body: String, generation: int, token: int) -> Error:
        posts.append({"body": body, "generation": generation, "token": token})
        return post_error

    func _cancel_post() -> void:
        if _in_flight > 0:
            cancellations += 1
        super._cancel_post()

    func complete(index: int, result: int, code: int, headers := PackedStringArray()) -> void:
        var post := posts[index]
        _post_completed(result, code, headers, PackedByteArray(), post["generation"], post["token"])

    func advance(ms: int, frames := 0) -> void:
        now += ms
        drawn += frames


var failures := 0


func _initialize() -> void:
    _run.call_deferred()


func _run() -> void:
    _test_uuid_and_endpoint()
    _test_default_and_consent()
    _test_lifecycle_and_shape()
    _test_retry_and_bounded_queue()
    _test_partial_batch_retry()
    print("TELEMETRY_TEST failures=", failures)
    quit(1 if failures else 0)


func _expect(ok: bool, message: String) -> void:
    if not ok:
        failures += 1
        push_error(message)


func _new_collector(path := "", endpoint := ENDPOINT) -> TestCollector:
    var collector := TestCollector.new()
    collector.identity_path = path if not path.is_empty() else "user://telemetry-test-" + Telemetry._new_uuid()
    collector.configure(endpoint, "1.2.2-alpha.3", "build+42", "beta")
    root.add_child(collector)
    return collector


func _test_uuid_and_endpoint() -> void:
    var uuid := RegEx.create_from_string("\\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\\z")
    var generated: Dictionary = {}
    for i in 64:
        var id := Telemetry._new_uuid()
        _expect(uuid.search(id) != null and not generated.has(id), "UUIDs are unique lowercase version 4 with the RFC variant")
        generated[id] = true
    _expect(not Telemetry._is_uuid("0b5044b8-1be0-13ef-877b-418a89d061f7"), "Non-version-4 identity is rejected")
    _expect(not Telemetry._is_uuid("0B5044B8-1BE0-43EF-877B-418A89D061F7"), "Uppercase identity is rejected")
    _expect(Telemetry._normalized_endpoint("https://telemetry.example/", false) == ENDPOINT, "An HTTPS origin gets the canonical POST path")
    _expect(Telemetry._normalized_endpoint(ENDPOINT, false) == ENDPOINT, "A complete HTTPS endpoint is preserved")
    for bad_url in ["", "http://127.0.0.1:8787", "http://telemetry.example/", "https://user@telemetry.example/", "https://telemetry.example/?token=1", "https://telemetry.example/#fragment", "https://telemetry.example/other", "https://telemetry.example:65536"]:
        _expect(Telemetry._normalized_endpoint(bad_url, false).is_empty(), "Production rejects invalid or HTTP endpoints")
    _expect(Telemetry._normalized_endpoint("http://127.0.0.1:8787", true) == "http://127.0.0.1:8787/v1/events", "Debug transport permits local HTTP")
    _expect(Telemetry._normalized_endpoint("http://telemetry.example", true).is_empty(), "Debug transport rejects remote HTTP")
    _expect(Telemetry._gpu_family("NVIDIA Corporation", "GeForce RTX 4080") == "geforce_rtx", "GPU strings map to a coarse family")
    _expect(Telemetry._gpu_family("Google Inc.", "ANGLE (Intel, Intel(R) Iris Xe Graphics)") == "intel_iris", "Wrapped browser renderer strings preserve the coarse family")
    _expect(Telemetry._gpu_family("Intel", "LLVMpipe 12.0") == "software", "Software rendering wins over vendor strings")
    _expect(Telemetry._gpu_family("Unrecognized", "Device 123") == "unknown", "Unknown hardware has a constant fallback")
    _expect(Telemetry._ram_bucket(-1) == "unknown" and Telemetry._ram_bucket(8 * Telemetry.GIB - 1) == "8_15_gb", "RAM uses a coarse tier and unknown fallback")


func _test_default_and_consent() -> void:
    var collector := _new_collector()
    var path := collector.identity_path
    collector.engine_started("kirikiri", PUBLIC_GAME, true, 40)
    collector.engine_error("kirikiri", PUBLIC_GAME, "runtime_error")
    collector.advance(70_000)
    collector._tick()
    _expect(not FileAccess.file_exists(path) and collector._events.is_empty() and collector.posts.is_empty() and collector._engine.is_empty(), "Default-off creates no identity, events, traffic or engine context")
    _expect(collector._timer.is_stopped(), "Default-off stops periodic telemetry work")

    collector.fail_write = true
    _expect(not collector.set_consent(true) and not collector._consent and collector._events.is_empty(), "Identity persistence failure keeps opt-in disabled")
    collector.fail_write = false
    _expect(collector.set_consent(true), "Opt-in succeeds with persistent storage")
    var first_id := collector._install_id
    _expect(Telemetry._is_uuid(first_id) and FileAccess.get_file_as_string(path) == first_id, "Opt-in generates and persists one v4 installation identity")
    _expect(collector.set_consent(true) and collector._events.size() == 1, "Duplicate opt-in records one launch")
    collector.configure("https://different-recipient.example", "1.0.0", "42", "stable")
    _expect(collector._endpoint == ENDPOINT, "Queued events cannot be reassigned to a different recipient while opted in")
    _expect(not collector._timer.is_stopped(), "Opt-in starts the periodic timer")
    collector._tick()
    _expect(collector.posts.size() == 1 and collector._in_flight == 1, "The opted-in launch is sent asynchronously")
    collector.engine_started("kirikiri", PUBLIC_GAME, true, 40)
    collector.fail_remove = true
    _expect(not collector.set_consent(false), "Disk removal failure is reported")
    _expect(collector._events.is_empty() and collector._install_id.is_empty() and collector._engine.is_empty() and collector._game_name.is_empty(), "Opt-out clears queue, ID and engine context even on disk failure")
    _expect(collector.cancellations == 1 and collector._in_flight == 0 and collector._timer.is_stopped(), "Opt-out cancels the request and stops the timer")
    collector.fail_remove = false
    _expect(collector.set_consent(true), "Re-enabling collection succeeds")
    var second_id := collector._install_id
    _expect(second_id != first_id and FileAccess.get_file_as_string(path) == second_id, "Re-enabling rotates the identity even if the old file remained")
    _expect(collector._events.is_empty(), "Re-enabling in the same process does not record a second app_start")
    collector.engine_error("kirikiri", "", "runtime_error")
    collector._tick()
    collector.complete(0, HTTPRequest.RESULT_SUCCESS, 202)
    _expect(collector._in_flight == 1 and collector._events.size() == 1, "A stale callback cannot drain a new consent generation")
    collector.complete(1, HTTPRequest.RESULT_SUCCESS, 202)
    _expect(collector._events.is_empty(), "Only the current request drains the pending batch")
    collector.free()

    var recreated := _new_collector(path)
    _expect(recreated.set_consent(true) and recreated._install_id == second_id, "Persisted consent reuses the dedicated ID across collector recreation")
    _expect(recreated._events.is_empty(), "Collector recreation in the same process does not record a second launch")
    _expect(recreated.set_consent(false) and not FileAccess.file_exists(path), "Opt-out removes the persisted identity")
    recreated.free()


func _test_lifecycle_and_shape() -> void:
    Telemetry._app_start_recorded = false
    var collector := _new_collector("", "")
    collector.set_foreground(false)
    _expect(collector.set_consent(true), "Opt-in succeeds with transmission disabled")
    collector.advance(65_000)
    collector._tick()
    _expect(collector._events.size() == 1 and collector.posts.is_empty(), "Opt-in while backgrounded only records launch, and blank endpoint never posts")
    var start_fields := {"launch_count": 1}
    _expect_event(collector._events[0], "app_start", start_fields)

    collector.set_foreground(true)
    collector.advance(59_000, 3_540)
    collector._tick()
    _expect(collector._events.size() == 1, "Idle foreground creates no usage event before the periodic checkpoint")
    collector.advance(1_000, 60)
    collector._tick()
    _expect_event(collector._events[1], "app_usage", {"duration_ms": 60_000, "fps": 60})
    collector._tick()
    _expect(collector._events.size() == 2, "An idle app checkpoint only counts the elapsed window once")

    collector.engine_started("kirikiri", PUBLIC_GAME, true, 90, "do_not_include")
    collector.engine_started("renpy", "/Users/private/game", false, -1, "launch_failed")
    collector.engine_error("kirikiri", "Game\u200fTitle", "Exception in /Users/private/Runtime")
    _expect_event(collector._events[2], "engine_start", {"engine": "kirikiri", "game_name": PUBLIC_GAME, "success": true, "load_ms": 90})
    _expect_event(collector._events[3], "engine_start", {"engine": "renpy", "success": false, "load_ms": 0, "error_code": "launch_failed"})
    _expect_event(collector._events[4], "engine_error", {"engine": "kirikiri", "error_code": "unknown"})
    _expect(Telemetry._safe_game_name("Game\\Title").is_empty(), "A Windows path separator is rejected")
    _expect(Telemetry._safe_game_name(" Game").is_empty() and Telemetry._safe_game_name("Game\u00a0").is_empty(), "Edge whitespace is rejected")
    _expect(Telemetry._safe_game_name("x".repeat(121)).is_empty(), "Overlong game names are rejected")
    _expect(Telemetry._safe_game_name(".").is_empty() and Telemetry._safe_game_name("..").is_empty(), "Dot path components are rejected")

    collector.memory = 80 * Telemetry.MIB
    collector.advance(5_000, 300)
    collector._tick()
    collector.memory = 60 * Telemetry.MIB
    collector.advance(7_000, 420)
    collector.set_foreground(false)
    collector.set_foreground(false)
    _expect_event(collector._events[5], "app_usage", {"duration_ms": 12_000, "fps": 60, "memory_peak_mb": 80})
    _expect_event(collector._events[6], "engine_usage", {"engine": "kirikiri", "game_name": PUBLIC_GAME, "duration_ms": 12_000, "fps": 60, "memory_peak_mb": 80})
    collector.advance(90_000, 100)
    collector._tick()
    collector.checkpoint()
    _expect(collector._events.size() == 7, "Background duration and duplicate pause do not create usage events")

    collector.set_foreground(true)
    collector.set_foreground(true)
    collector.advance(2_000, 90)
    collector.engine_stopped()
    collector.engine_stopped()
    _expect_event(collector._events[7], "engine_usage", {"engine": "kirikiri", "game_name": PUBLIC_GAME, "duration_ms": 2_000, "fps": 45, "memory_peak_mb": 60})
    collector.advance(1_000)
    collector.checkpoint()
    _expect_event(collector._events[8], "app_usage", {"duration_ms": 3_000, "fps": 30, "memory_peak_mb": 60})
    var ids := {}
    for event in collector._events:
        _expect(event["install_id"] == collector._install_id and not ids.has(event["event_id"]), "Events share one installation ID but have distinct event IDs")
        ids[event["event_id"]] = true
    _expect(collector.set_consent(false), "Lifecycle fixture clears its ID")
    collector.free()


func _expect_event(event: Dictionary, kind: String, fields: Dictionary) -> void:
    var keys := event.keys()
    keys.sort()
    var wanted_keys := COMMON_FIELDS + fields.keys()
    wanted_keys.sort()
    _expect(keys == wanted_keys, "%s has exactly the protocol dimensions and kind fields" % kind)
    _expect(event.get("kind") == kind, "Event has kind %s" % kind)
    _expect(Telemetry._is_uuid(event.get("event_id", "")) and Telemetry._is_uuid(event.get("install_id", "")), "Event IDs are lowercase UUID v4")
    _expect(event.get("app_version") == "1.2.2-alpha.3" and event.get("build") == "build+42" and event.get("channel") == "beta", "Event carries build metadata")
    for key in fields:
        _expect(event.get(key) == fields[key] and typeof(event.get(key)) == typeof(fields[key]), "%s has correctly typed %s" % [kind, key])


func _test_retry_and_bounded_queue() -> void:
    Telemetry._app_start_recorded = false
    var collector := _new_collector()
    _expect(collector.set_consent(true), "Transport fixture opts in")
    for i in Telemetry.QUEUE_LIMIT + 20:
        collector.engine_error("kirikiri", "", "runtime_error")
    _expect(collector._events.size() == Telemetry.QUEUE_LIMIT, "Offline queue stays capped")
    collector._tick()
    _expect(collector.posts.size() == 1 and collector._in_flight == Telemetry.BATCH_LIMIT, "Transport takes one bounded batch")
    var raw: String = collector.posts[0]["body"]
    var envelope: Variant = JSON.parse_string(raw)
    _expect(envelope is Dictionary and envelope.keys().size() == 2 and envelope.get("schema_version") == 1, "Serialized payload is a v1 envelope")
    _expect(envelope.get("events", []).size() == Telemetry.BATCH_LIMIT and envelope["events"][0]["kind"] == "app_start", "Envelope includes the original queued events in order")
    _expect(raw.to_utf8_buffer().size() < 65_536, "Payload obeys the server body limit")
    collector._tick()
    _expect(collector.posts.size() == 1, "At most one request can be in flight")
    collector.complete(0, HTTPRequest.RESULT_TIMEOUT, 0)
    collector.advance(Telemetry.RETRY_MIN_MS - 1)
    collector._tick()
    _expect(collector.posts.size() == 1, "Timeout waits for retry backoff")
    collector.advance(1)
    collector._tick()
    _expect(collector.posts[1]["body"] == raw, "Retry preserves batch bytes and event IDs")
    collector.complete(0, HTTPRequest.RESULT_SUCCESS, 200)
    _expect(collector._events.size() == Telemetry.QUEUE_LIMIT, "A stale callback for an earlier request cannot acknowledge the retry")
    collector.complete(1, HTTPRequest.RESULT_SUCCESS, 429, PackedStringArray(["Retry-After: 12"]))
    var retry_due := collector.now + 12_000
    _expect(collector._retry_at == retry_due and collector._retry_delay == 2 * Telemetry.RETRY_MIN_MS, "Rate limit honors Retry-After and increases backoff")
    collector.advance(12_000)
    collector._tick()
    collector.complete(2, HTTPRequest.RESULT_SUCCESS, 200)
    _expect(collector._events.size() == Telemetry.QUEUE_LIMIT - Telemetry.BATCH_LIMIT and collector._retry_at == 0, "Success drains just the accepted batch and resets backoff")
    collector._tick()
    collector.complete(3, HTTPRequest.RESULT_SUCCESS, 400)
    _expect(collector._events.size() == Telemetry.QUEUE_LIMIT - 2 * Telemetry.BATCH_LIMIT, "Permanent client rejection drops only that batch")
    collector.post_error = ERR_CANT_CONNECT
    collector._tick()
    _expect(collector._in_flight == 0 and collector._retry_delay == Telemetry.RETRY_MIN_MS, "Immediate request error waits for retry")
    _expect(collector.set_consent(false), "Transport fixture clears its ID")
    collector.free()


func _test_partial_batch_retry() -> void:
    var collector := _new_collector()
    _expect(collector.set_consent(true), "Partial batch fixture opts in")
    collector.engine_error("kirikiri", "", "runtime_error")
    collector._tick()
    collector.complete(0, HTTPRequest.RESULT_SUCCESS, 503)
    collector.engine_error("renpy", "", "runtime_error")
    collector.advance(Telemetry.RETRY_MIN_MS)
    collector._tick()
    _expect(collector.posts[1]["body"] == collector.posts[0]["body"], "New events do not modify a partially filled retry batch")
    collector.complete(1, HTTPRequest.RESULT_SUCCESS, 200)
    _expect(collector._events.size() == 1 and collector._events[0]["engine"] == "renpy", "Retry success preserves events queued after the first attempt")
    _expect(collector.set_consent(false), "Partial batch fixture clears its ID")
    collector.free()
