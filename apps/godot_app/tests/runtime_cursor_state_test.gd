extends SceneTree

const CursorState := preload("res://scripts/runtime_cursor_state.gd")

func _initialize() -> void:
    var cursor := CursorState.new()
    assert(cursor.mouse_mode(true) == Input.MOUSE_MODE_VISIBLE)
    cursor.request(false)
    assert(cursor.mouse_mode(true) == Input.MOUSE_MODE_HIDDEN)
    # Leaving the play surface/focus or opening a host modal releases the
    # cursor, even when the game never sends a corresponding show request.
    assert(cursor.mouse_mode(false) == Input.MOUSE_MODE_VISIBLE)
    assert(cursor.mouse_mode(true) == Input.MOUSE_MODE_HIDDEN)
    cursor.request(true)
    assert(cursor.mouse_mode(true) == Input.MOUSE_MODE_VISIBLE)
    cursor.request(false)
    cursor.reset()
    assert(cursor.mouse_mode(true) == Input.MOUSE_MODE_VISIBLE)
    assert(not cursor.active)
    print("Runtime cursor ownership PASS")
    quit()
