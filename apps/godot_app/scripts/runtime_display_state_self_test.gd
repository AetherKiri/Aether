extends SceneTree

const DisplayState = preload("res://scripts/runtime_display_state.gd")

class FakeWindow:
    var mode := Window.MODE_MAXIMIZED

func _initialize() -> void:
    var state = DisplayState.new()
    var window = FakeWindow.new()
    assert(state.apply("runtime_window_mode", "fullscreen", window, true))
    assert(window.mode == Window.MODE_FULLSCREEN)
    state.apply("runtime_window_mode", "windowed", window, true)
    assert(window.mode == Window.MODE_WINDOWED)
    for mode in DisplayState.ASPECT_MODES:
        assert(state.apply("runtime_aspect_mode", mode, window, true))
        assert(state.aspect_mode == DisplayState.ASPECT_MODES[mode])
    state.apply("runtime_window_mode", "invalid", window, true)
    assert(window.mode == Window.MODE_WINDOWED)
    state.reset(window)
    assert(window.mode == Window.MODE_MAXIMIZED)
    assert(state.aspect_mode == 1)
    state.apply("runtime_window_mode", "fullscreen", window, false)
    assert(window.mode == Window.MODE_MAXIMIZED)
    assert(not state.apply("another_request", "", window, true))
    print("runtime display state self-test passed")
    quit(0)
