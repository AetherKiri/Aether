extends RefCounted

# This entry explicitly identifies Godot keycodes for the Ren'Py provider.
# KiriKiri and the other runtimes keep their existing Windows-VK path.
static func send_key_event(player: Object, key: InputEventKey) -> int:
    var code := int(key.keycode)
    if key.keycode == KEY_NONE:
        code = int(key.physical_keycode)
    var modifiers := int(key.get_modifiers_mask())
    if key.echo:
        modifiers |= 0x80
    return player.send_renpy_key_event(key.pressed, code, modifiers, key.unicode)
