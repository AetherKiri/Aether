extends Node

const INSTALL_ID_PATH := "user://telemetry_install_id_v1"
const CHECKPOINT_MS := 60_000
const SAMPLE_MS := 5_000
const QUEUE_LIMIT := 128
const BATCH_LIMIT := 16
const RETRY_MIN_MS := 2_000
const RETRY_MAX_MS := 300_000
const REQUEST_TIMEOUT_MS := 12_000
const MAX_DURATION_MS := 86_400_000
const ENDPOINT_PATH := "/v1/events"
const MIB := 1_048_576
const GIB := 1_073_741_824
const OS_FAMILIES := ["Windows", "macOS", "Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD", "Android", "iOS", "Web"]

## Optional platform process-memory sampler. Return bytes, or zero if unavailable.
var memory_sampler: Callable

var _endpoint := ""
var _app_version := "unknown"
var _build := "unknown"
var _channel := "unknown"
var _consent := false
var _foreground := true
# This stays set across consent cycles (and collector recreation) in the same process.
static var _app_start_recorded := false
var _install_id := ""
var _can_reuse_saved_id := true
var _dimensions: Dictionary = {}
var _events: Array[Dictionary] = []

var _engine := ""
var _game_name := ""
var _app_since := -1
var _engine_since := -1
var _app_drawn := 0
var _engine_drawn := 0
var _app_memory_peak := 0
var _engine_memory_peak := 0
var _checkpoint_at := 0
var _sample_at := 0
var _timer: Timer

var _generation := 0
var _request_token := 0
var _in_flight := 0
var _retry_batch_size := 0
var _request: HTTPRequest
var _web_controller: JavaScriptObject
var _web_success_callback: JavaScriptObject
var _web_failure_callback: JavaScriptObject
var _web_timeout_callback: JavaScriptObject
var _web_timeout_id := -1
var _retry_delay := 0
var _retry_at := 0


func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    _timer = Timer.new()
    _timer.name = "TelemetryTick"
    _timer.wait_time = 1.0
    _timer.ignore_time_scale = true
    _timer.timeout.connect(_tick)
    add_child(_timer)
    if _consent:
        _timer.start()


func _exit_tree() -> void:
    _generation += 1
    _cancel_post()


## A blank or invalid endpoint disables transmission. Configure while consent is off
## so pending events cannot be reassigned to a different recipient.
func configure(endpoint: String, app_version: String, build: String, channel: String) -> void:
    if _consent:
        return
    _endpoint = _normalized_endpoint(endpoint, OS.is_debug_build())
    _app_version = _safe_build_value(app_version)
    _build = _safe_build_value(build)
    _channel = _safe_token(channel)


## Opt-out always stops collection and requests, even if disk removal fails.
## Opt-in fails closed if the dedicated identity cannot be stored.
func set_consent(enabled: bool) -> bool:
    if not enabled:
        _consent = false
        _generation += 1
        _cancel_post()
        if is_instance_valid(_timer):
            _timer.stop()
        _events.clear()
        _dimensions.clear()
        _install_id = ""
        _can_reuse_saved_id = false
        _engine = ""
        _game_name = ""
        _app_since = -1
        _engine_since = -1
        _app_drawn = 0
        _engine_drawn = 0
        _app_memory_peak = 0
        _engine_memory_peak = 0
        _checkpoint_at = 0
        _sample_at = 0
        return _remove_install_id()
    if _consent:
        return true
    if OS.get_name() == "Web" and not OS.is_userfs_persistent():
        return false
    var install_id := _read_install_id() if _can_reuse_saved_id else ""
    if install_id.is_empty():
        install_id = _new_uuid()
        if install_id.is_empty() or not _write_install_id(install_id):
            return false
    _install_id = install_id
    _dimensions = _device_dimensions()
    _consent = true
    if not _app_start_recorded:
        _app_start_recorded = _enqueue("app_start", {"launch_count": 1})
    if _foreground:
        _begin_foreground(_now_ms())
    if is_instance_valid(_timer):
        _timer.start()
    return true


## Pass the combined application foreground/focus state. Duplicate notifications are safe.
func set_foreground(foreground: bool) -> void:
    if foreground == _foreground:
        return
    _foreground = foreground
    if not _consent:
        return
    var now := _now_ms()
    if foreground:
        _begin_foreground(now)
    else:
        _record_usage(now, true, true)
        _app_since = -1
        _engine_since = -1
        _pump(now)


## Pass only a display name allowed by the application's consent notice, and
## always exclude paths. error_code is a stable application code, never runtime text.
func engine_started(engine: String, game_name: String, success: bool, load_ms: int, error_code: String = "") -> void:
    if not _consent:
        return
    var event := _engine_fields(_safe_token(engine), _safe_game_name(game_name))
    event["success"] = success
    event["load_ms"] = clampi(load_ms, 0, MAX_DURATION_MS)
    if not success:
        event["error_code"] = _safe_token(error_code)
    _enqueue("engine_start", event)
    if success:
        set_running_engine(engine, game_name)


## Begin usage for an already running engine when consent is enabled mid-session.
func set_running_engine(engine: String, game_name: String) -> void:
    if not _consent:
        return
    engine_stopped()
    _engine = _safe_token(engine)
    _game_name = _safe_game_name(game_name)
    if _foreground:
        _engine_since = _now_ms()
        _engine_drawn = _drawn_frames()
        _engine_memory_peak = _sample_memory_bytes()


func engine_stopped() -> void:
    if not _consent or _engine.is_empty():
        return
    _record_usage(_now_ms(), false, true)
    _engine_since = -1
    _engine_drawn = 0
    _engine_memory_peak = 0
    _engine = ""
    _game_name = ""


func engine_error(engine: String, game_name: String, error_code: String) -> void:
    if not _consent:
        return
    var event := _engine_fields(_safe_token(engine), _safe_game_name(game_name))
    event["error_code"] = _safe_token(error_code)
    _enqueue("engine_error", event)


## Periodic and lifecycle checkpoints report only the delta since the last checkpoint.
## Upload is asynchronous. At process exit delivery is best effort.
func checkpoint() -> void:
    if _consent:
        _checkpoint_at_time(_now_ms())


func _tick() -> void:
    if not _consent:
        return
    var now := _now_ms()
    if _foreground and now >= _checkpoint_at:
        _checkpoint_at_time(now)
        return
    if _foreground and now >= _sample_at:
        _sample_memory(now)
    _pump(now)


func _checkpoint_at_time(now: int) -> void:
    if _foreground:
        _record_usage(now, true, true)
        _checkpoint_at = now + CHECKPOINT_MS
    _pump(now)


func _begin_foreground(now: int) -> void:
    var drawn := _drawn_frames()
    _app_since = now
    _app_drawn = drawn
    _app_memory_peak = 0
    if not _engine.is_empty():
        _engine_since = now
        _engine_drawn = drawn
        _engine_memory_peak = 0
    _checkpoint_at = now + CHECKPOINT_MS
    _sample_memory(now)


func _sample_memory(now: int) -> int:
    var bytes := _sample_memory_bytes()
    if _app_since >= 0:
        _app_memory_peak = maxi(_app_memory_peak, bytes)
    if _engine_since >= 0:
        _engine_memory_peak = maxi(_engine_memory_peak, bytes)
    _sample_at = now + SAMPLE_MS
    return bytes


func _record_usage(now: int, app: bool, engine: bool) -> void:
    var app_ms := now - _app_since if app and _app_since >= 0 else 0
    var engine_ms := now - _engine_since if engine and _engine_since >= 0 else 0
    if app_ms <= 0 and engine_ms <= 0:
        return
    var drawn := _drawn_frames()
    var current_memory := _sample_memory(now)
    if app_ms > 0:
        _enqueue("app_usage", _usage_fields(app_ms, drawn - _app_drawn, _app_memory_peak))
        _app_since = now
        _app_drawn = drawn
        _app_memory_peak = current_memory
    if engine_ms > 0:
        var event := _engine_fields(_engine, _game_name)
        event.merge(_usage_fields(engine_ms, drawn - _engine_drawn, _engine_memory_peak))
        _enqueue("engine_usage", event)
        _engine_since = now
        _engine_drawn = drawn
        _engine_memory_peak = current_memory


func _enqueue(kind: String, fields: Dictionary) -> bool:
    # Keep the pending/in-flight prefix stable across retries. Overflow drops new events.
    if not _consent or _events.size() >= QUEUE_LIMIT:
        return false
    var event_id := _new_uuid()
    if event_id.is_empty():
        return false
    var event := _dimensions.duplicate()
    event.merge({
        "event_id": event_id,
        "install_id": _install_id,
        "kind": kind,
        "app_version": _app_version,
        "build": _build,
        "channel": _channel,
    })
    event.merge(fields)
    _events.append(event)
    return true


func _pump(now: int) -> void:
    if not _consent or _endpoint.is_empty() or _events.is_empty() or _in_flight > 0 or now < _retry_at:
        return
    if _retry_batch_size == 0:
        _retry_batch_size = mini(_events.size(), BATCH_LIMIT)
    _in_flight = _retry_batch_size
    _request_token += 1
    var body := JSON.stringify({"schema_version": 1, "events": _events.slice(0, _in_flight)})
    if _start_post(body, _generation, _request_token) != OK:
        _in_flight = 0
        _schedule_retry(now)


func _start_post(body: String, generation: int, token: int) -> Error:
    if not is_inside_tree():
        return ERR_UNCONFIGURED
    if OS.get_name() == "Web":
        return _start_web_post(body, generation, token)
    var request := HTTPRequest.new()
    request.timeout = float(REQUEST_TIMEOUT_MS) / 1000.0
    request.body_size_limit = 8_192
    # Never forward telemetry through redirects or to a downgraded connection.
    request.max_redirects = 0
    add_child(request)
    _request = request
    request.request_completed.connect(_post_completed.bind(generation, token), CONNECT_ONE_SHOT)
    var err := request.request(_endpoint, ["Content-Type: application/json"], HTTPClient.METHOD_POST, body)
    if err != OK:
        request.queue_free()
        _request = null
    return err


func _start_web_post(body: String, generation: int, token: int) -> Error:
    # Godot's browser HTTPRequest uses the browser's default redirect behavior.
    # Build fetch options through the bridge so the request can be cancelled and
    # only the configured endpoint receives the body.
    var browser := JavaScriptBridge.get_interface("window")
    var controller: Variant = JavaScriptBridge.create_object("AbortController")
    var options: Variant = JavaScriptBridge.create_object("Object")
    var headers: Variant = JavaScriptBridge.create_object("Headers")
    if browser == null or controller == null or options == null or headers == null:
        return ERR_UNAVAILABLE
    headers.set("Content-Type", "application/json")
    options.method = "POST"
    options.headers = headers
    options.body = body
    options.signal = controller.signal
    options.credentials = "omit"
    options.redirect = "error"
    options.referrerPolicy = "no-referrer"
    _web_controller = controller
    _web_success_callback = JavaScriptBridge.create_callback(_web_post_success.bind(generation, token))
    _web_failure_callback = JavaScriptBridge.create_callback(_web_post_failure.bind(generation, token))
    _web_timeout_callback = JavaScriptBridge.create_callback(_web_post_timeout.bind(generation, token))
    var promise: Variant = browser.fetch(_endpoint, options)
    if promise == null:
        _clear_web_post(true)
        return ERR_CANT_CONNECT
    promise.then(_web_success_callback, _web_failure_callback)
    _web_timeout_id = int(browser.setTimeout(_web_timeout_callback, REQUEST_TIMEOUT_MS))
    return OK


func _web_post_success(args: Array, generation: int, token: int) -> void:
    if args.is_empty() or not _is_current_request(generation, token):
        return
    var response: JavaScriptObject = args[0]
    var headers := PackedStringArray()
    # Use the iterator because JavaScriptObject already has Godot's Object.get().
    var entries: JavaScriptObject = response.headers.entries()
    for i in 64:
        var entry: JavaScriptObject = entries.next()
        if entry.done:
            break
        if entry.value[0] == "retry-after":
            headers.append("Retry-After: " + String(entry.value[1]))
            break
    # The server's status is sufficient. Stop downloading the unread response body.
    _post_completed(HTTPRequest.RESULT_SUCCESS, int(response.status), headers, PackedByteArray(), generation, token)


func _web_post_failure(_args: Array, generation: int, token: int) -> void:
    _post_completed(HTTPRequest.RESULT_CONNECTION_ERROR, 0, PackedStringArray(), PackedByteArray(), generation, token)


func _web_post_timeout(_args: Array, generation: int, token: int) -> void:
    _post_completed(HTTPRequest.RESULT_TIMEOUT, 0, PackedStringArray(), PackedByteArray(), generation, token)


func _clear_web_post(abort: bool) -> void:
    if _web_timeout_id != -1:
        JavaScriptBridge.get_interface("window").clearTimeout(_web_timeout_id)
        _web_timeout_id = -1
    if abort and _web_controller != null:
        _web_controller.abort()
    _web_controller = null
    _web_success_callback = null
    _web_failure_callback = null
    _web_timeout_callback = null


func _is_current_request(generation: int, token: int) -> bool:
    return _consent and generation == _generation and token == _request_token and _in_flight > 0


func _post_completed(result: int, status_code: int, headers: PackedStringArray, _body: PackedByteArray, generation: int, token: int) -> void:
    if not _is_current_request(generation, token):
        return
    _clear_web_post(true)
    if is_instance_valid(_request):
        _request.queue_free()
    _request = null
    var batch_size := _in_flight
    _in_flight = 0
    var accepted := status_code >= 200 and status_code < 300
    var rejected := status_code >= 400 and status_code < 500 and status_code not in [408, 425, 429]
    if result == HTTPRequest.RESULT_SUCCESS and (accepted or rejected):
        _events = _events.slice(batch_size)
        _retry_batch_size = 0
        _retry_delay = 0
        _retry_at = 0
        return
    _schedule_retry(_now_ms(), _retry_after_ms(headers))


func _schedule_retry(now: int, retry_after := 0) -> void:
    _retry_delay = clampi(_retry_delay * 2, RETRY_MIN_MS, RETRY_MAX_MS)
    _retry_at = now + maxi(_retry_delay, retry_after)


func _cancel_post() -> void:
    _clear_web_post(true)
    _retry_batch_size = 0
    if is_instance_valid(_request):
        _request.cancel_request()
        _request.queue_free()
    _request = null
    _in_flight = 0
    _retry_delay = 0
    _retry_at = 0


func _now_ms() -> int:
    return Time.get_ticks_msec()


func _drawn_frames() -> int:
    return Engine.get_frames_drawn()


func _sample_memory_bytes() -> int:
    if memory_sampler.is_valid():
        var bytes: Variant = memory_sampler.call()
        if bytes is int and bytes > 0:
            return bytes
    # Godot's static counter omits native runtime/driver allocations and may be
    # unavailable in release. Web has no portable process memory API.
    return 0 if OS.get_name() == "Web" else OS.get_static_memory_usage()


func _device_dimensions() -> Dictionary:
    var platform := OS.get_name()
    var ram := _ram_bucket(_physical_memory_bytes(platform))
    var gpu := "unknown"
    if DisplayServer.get_name() != "headless":
        gpu = _gpu_family(RenderingServer.get_video_adapter_vendor(), RenderingServer.get_video_adapter_name())
    return {
        "os": platform if platform in OS_FAMILIES else "Unknown",
        "arch": _arch_family(Engine.get_architecture_name()),
        "ram_bucket": ram,
        "gpu_family": gpu,
    }


static func _physical_memory_bytes(platform: String) -> int:
    if platform != "Web":
        return int(OS.get_memory_info().get("physical", -1))
    # Chromium exposes a browser-rounded and capped hint. Other browsers can omit it.
    var navigator := JavaScriptBridge.get_interface("navigator")
    if navigator != null:
        var gib: Variant = navigator.deviceMemory
        if (gib is float or gib is int) and is_finite(float(gib)) and float(gib) > 0.0:
            return roundi(float(gib) * GIB)
    return 0


func _install_id_path() -> String:
    return INSTALL_ID_PATH


func _read_install_id() -> String:
    var file := FileAccess.open(_install_id_path(), FileAccess.READ)
    if file == null or file.get_length() != 36:
        return ""
    var id := file.get_buffer(36).get_string_from_ascii()
    return id if _is_uuid(id) else ""


func _write_install_id(id: String) -> bool:
    var file := FileAccess.open(_install_id_path(), FileAccess.WRITE)
    if file == null:
        return false
    var stored := file.store_string(id)
    file.flush()
    var err := file.get_error()
    file.close()
    return stored and err == OK and _read_install_id() == id


func _remove_install_id() -> bool:
    var path := _install_id_path()
    if not FileAccess.file_exists(path):
        return true
    return DirAccess.remove_absolute(ProjectSettings.globalize_path(path)) == OK


static func _new_uuid() -> String:
    var bytes := _random_bytes()
    if bytes.size() != 16:
        return ""
    bytes[6] = (bytes[6] & 0x0f) | 0x40
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    var hex := bytes.hex_encode()
    return "%s-%s-%s-%s-%s" % [hex.substr(0, 8), hex.substr(8, 4), hex.substr(12, 4), hex.substr(16, 4), hex.substr(20, 12)]


static func _random_bytes() -> PackedByteArray:
    if OS.get_name() != "Web":
        return Crypto.new().generate_random_bytes(16)
    var crypto := JavaScriptBridge.get_interface("crypto")
    var buffer: Variant = JavaScriptBridge.create_object("Uint8Array", 16)
    if crypto == null or buffer == null:
        return PackedByteArray()
    var filled: Variant = crypto.getRandomValues(buffer)
    return JavaScriptBridge.js_buffer_to_packed_byte_array(filled) if filled is JavaScriptObject else PackedByteArray()


static func _is_uuid(id: String) -> bool:
    if id.length() != 36 or id[14] != "4" or not "89ab".contains(id[19]):
        return false
    for i in 36:
        if i in [8, 13, 18, 23]:
            if id[i] != "-":
                return false
        elif not "0123456789abcdef".contains(id[i]):
            return false
    return true


static func _usage_fields(duration_ms: int, drawn: int, memory_bytes: int) -> Dictionary:
    var result := {"duration_ms": mini(duration_ms, MAX_DURATION_MS)}
    if drawn > 0:
        result["fps"] = clampi(roundi(float(drawn) * 1000.0 / float(duration_ms)), 0, 1000)
    if memory_bytes > 0:
        result["memory_peak_mb"] = clampi(ceili(float(memory_bytes) / MIB), 1, 1_048_576)
    return result


static func _engine_fields(engine: String, game_name: String) -> Dictionary:
    var result := {"engine": engine}
    if not game_name.is_empty():
        result["game_name"] = game_name
    return result


static func _safe_token(value: String) -> String:
    var pattern := RegEx.create_from_string("\\A[a-z0-9][a-z0-9_-]{0,39}\\z")
    return value if value.length() <= 40 and pattern.search(value) != null else "unknown"


static func _safe_build_value(value: String) -> String:
    var pattern := RegEx.create_from_string("\\A[A-Za-z0-9][A-Za-z0-9._+\\-]{0,63}\\z")
    return value if value.length() <= 64 and pattern.search(value) != null else "unknown"


static func _safe_game_name(value: String) -> String:
    if value.is_empty() or value in [".", ".."] or value.length() > 120:
        return ""
    var forbidden := RegEx.create_from_string("[\\p{Cc}\\p{Cf}\\p{Zl}\\p{Zp}/\\\\:]|\\A[\\p{Z}\\s]|[\\p{Z}\\s]\\z")
    return value if forbidden.search(value) == null else ""


static func _arch_family(name: String) -> String:
    match name:
        "x86_64", "x86_32", "arm64", "arm32", "wasm64", "wasm32":
            return name
        "rv64":
            return "riscv64"
        "rv32":
            return "riscv32"
        _:
            return "unknown"


static func _ram_bucket(bytes: int) -> String:
    # Godot excludes reserved memory, so round up to the next GiB near tier boundaries.
    if bytes <= 0:
        return "unknown"
    var gib := ceili(float(bytes) / GIB)
    if gib < 4:
        return "lt_4_gb"
    if gib < 8:
        return "4_7_gb"
    if gib < 16:
        return "8_15_gb"
    if gib < 32:
        return "16_31_gb"
    if gib < 64:
        return "32_63_gb"
    return "gte_64_gb"


static func _gpu_family(vendor: String, adapter: String) -> String:
    var hint := (vendor + " " + adapter).to_lower()
    for software in ["llvmpipe", "softpipe", "swiftshader", "software", "basic render"]:
        if hint.contains(software):
            return "software"
    for family in ["adreno", "mali", "powervr"]:
        if hint.contains(family):
            return family
    if hint.contains("nvidia") or hint.contains("geforce"):
        if hint.contains("rtx"):
            return "geforce_rtx" if hint.contains("geforce") else "nvidia_rtx"
        if hint.contains("gtx"):
            return "geforce_gtx"
        return "nvidia"
    if hint.contains("radeon rx"):
        return "radeon_rx"
    if hint.contains("amd") or hint.contains("radeon") or hint.contains("advanced micro devices"):
        return "amd"
    if hint.contains("intel"):
        if hint.contains("arc"):
            return "intel_arc"
        if hint.contains("iris"):
            return "intel_iris"
        if hint.contains("uhd"):
            return "intel_uhd"
        return "intel"
    if hint.contains("apple"):
        return "apple"
    return "unknown"


static func _normalized_endpoint(endpoint: String, allow_debug_loopback: bool) -> String:
    var url := endpoint.strip_edges()
    var parts := RegEx.create_from_string("\\A(https?)://(\\[[0-9A-Fa-f:]+\\]|[A-Za-z0-9.-]+)(?::([0-9]{1,5}))?(?:/v1/events)?/?\\z")
    var matched := parts.search(url) if url.length() <= 512 else null
    if matched == null:
        return ""
    var host := matched.get_string(2)
    var port := matched.get_string(3)
    if not port.is_empty() and (int(port) < 1 or int(port) > 65_535):
        return ""
    if matched.get_string(1) == "http" and (
        not allow_debug_loopback or host.to_lower() not in ["127.0.0.1", "[::1]", "localhost"]
    ):
        return ""
    return "%s://%s%s%s" % [matched.get_string(1), host, "" if port.is_empty() else ":" + port, ENDPOINT_PATH]


static func _retry_after_ms(headers: PackedStringArray) -> int:
    for header in headers:
        if header.to_lower().begins_with("retry-after:"):
            var seconds := header.get_slice(":", 1).strip_edges()
            if seconds.is_valid_int():
                return clampi(int(seconds), 0, RETRY_MAX_MS / 1000) * 1000
    return 0
