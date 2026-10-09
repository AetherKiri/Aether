extends SceneTree

const RenpyKeyInput = preload("res://scripts/renpy_key_input.gd")

class Recorder extends RefCounted:
    var events: Array = []
    var result := 0

    func send_renpy_key_event(pressed: bool, code: int, modifiers: int, unicode: int) -> int:
        events.append([pressed, code, modifiers, unicode])
        return result

func _init() -> void:
    var recorder := Recorder.new()
    # Actual Godot InputEventKey objects preserve characters that the legacy
    # VK path would treat as Delete, Help, arrows, keypad or function keys.
    for code in range(32, 127):
        var key := InputEventKey.new()
        key.pressed = true
        key.keycode = code
        key.unicode = code
        assert(RenpyKeyInput.send_key_event(recorder, key) == 0)
        assert(recorder.events.back() == [true, code, 0, code])
    for code in [KEY_DELETE, KEY_ENTER, KEY_KP_ENTER, KEY_BACKSPACE, KEY_ESCAPE,
            KEY_TAB, KEY_BACKTAB, KEY_HOME, KEY_END, KEY_LEFT, KEY_RIGHT,
            KEY_UP, KEY_DOWN, KEY_PAGEUP, KEY_PAGEDOWN, KEY_INSERT, KEY_F1, KEY_F24]:
        var key := InputEventKey.new()
        key.keycode = code
        key.pressed = false
        assert(RenpyKeyInput.send_key_event(recorder, key) == 0)
        assert(recorder.events.back() == [false, code, 0, 0])
    var shortcut := InputEventKey.new()
    shortcut.pressed = true
    shortcut.keycode = KEY_A
    shortcut.unicode = 65
    shortcut.shift_pressed = true
    shortcut.ctrl_pressed = true
    shortcut.meta_pressed = true
    shortcut.echo = true
    RenpyKeyInput.send_key_event(recorder, shortcut)
    var modifiers := int(shortcut.get_modifiers_mask()) | 0x80
    assert(recorder.events.back() == [true, KEY_A, modifiers, 65])
    assert(modifiers & KEY_MASK_CTRL and modifiers & KEY_MASK_SHIFT and modifiers & KEY_MASK_META)
    var physical := InputEventKey.new()
    physical.keycode = KEY_NONE
    physical.physical_keycode = KEY_DELETE
    physical.pressed = true
    RenpyKeyInput.send_key_event(recorder, physical)
    assert(recorder.events.back() == [true, KEY_DELETE, 0, 0])
    var committed := InputEventKey.new()
    committed.pressed = true
    committed.unicode = 0x1f642
    RenpyKeyInput.send_key_event(recorder, committed)
    assert(recorder.events.back() == [true, KEY_NONE, 0, 0x1f642])
    recorder.result = -4
    assert(RenpyKeyInput.send_key_event(recorder, committed) == -4)
    print("Ren'Py Godot key forwarding passed: printable/special/physical keys, modifiers, repeat and Unicode")
    print("Recorder boundary only; no GDExtension, SDL or gameplay execution")
    quit(0)
