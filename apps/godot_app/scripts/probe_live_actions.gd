extends RefCounted

const REQUEST_FILE := "probe-actions.json"
const RESULT_FILE := "probe-actions-result.json"
const MAX_REQUEST_BYTES := 262144
const MAX_ACTIONS := 512

var last_sequence := 0

static func idle_timeout_msec(config: Dictionary) -> int:
    var frames := clampi(int(config.get("live_actions_timeout_frames", 36000)), 1, 60000)
    var seconds := float(config.get("live_actions_timeout_seconds", frames / 60.0))
    if not is_finite(seconds):
        seconds = 600.0
    return int(clampf(seconds * 1000.0, 1000.0, 14400000.0))

# Only the explicitly selected CLI step probe polls this local command file.
# Requests use the existing action whitelist; no script text is evaluated.
func poll(output_dir: String) -> Dictionary:
    var file := FileAccess.open(output_dir.path_join(REQUEST_FILE), FileAccess.READ)
    if file == null or file.get_length() > MAX_REQUEST_BYTES:
        return {}
    var parser := JSON.new()
    if parser.parse(file.get_as_text()) != OK:
        return {}
    var request = parser.data
    if not request is Dictionary:
        return {}
    var sequence = request.get("sequence", 0)
    if not (sequence is int or sequence is float):
        return {}
    if float(sequence) != floor(float(sequence)) or sequence <= last_sequence or sequence > 2147483647:
        return {}
    var actions = request.get("actions", [])
    if not actions is Array or actions.size() > MAX_ACTIONS:
        return {}
    for action in actions:
        if not action is Dictionary:
            return {}
    last_sequence = int(sequence)
    return {"sequence": last_sequence, "actions": actions, "stop": bool(request.get("stop", false))}

func acknowledge(output_dir: String, sequence: int, step: int, status := "complete") -> void:
    var file := FileAccess.open(output_dir.path_join(RESULT_FILE), FileAccess.WRITE)
    if file != null:
        file.store_string(JSON.stringify({"sequence": sequence, "step": step,
            "ok": step >= 0, "status": status}))
