extends RefCounted

# Values match the host viewport's existing layout modes.
const ASPECT_MODES := {"stretch": 0, "contain": 1, "native": 2, "cover": 3}

var aspect_mode := 1
var original_window_mode := -1

func apply(operation: String, argument: String, window, allow_window_change: bool) -> bool:
    if operation == "runtime_aspect_mode":
        if ASPECT_MODES.has(argument):
            aspect_mode = ASPECT_MODES[argument]
        return true
    if operation == "runtime_window_mode":
        if allow_window_change and argument in ["fullscreen", "windowed"]:
            if original_window_mode < 0:
                original_window_mode = window.mode
            window.mode = Window.MODE_FULLSCREEN if argument == "fullscreen" else Window.MODE_WINDOWED
        return true
    return false

func reset(window) -> void:
    if original_window_mode >= 0:
        window.mode = original_window_mode
    original_window_mode = -1
    aspect_mode = 1
