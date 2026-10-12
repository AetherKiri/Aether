extends Control

signal closed

const VirtualControls := preload("res://scripts/game_virtual_controls.gd")

var host
var native
var surface: TextureRect
var controls
var header: PanelContainer
var toolbar: HBoxContainer
var refresh_button: Button
var entry: Dictionary
var paused := false
var lifecycle_paused := false
var primary_touch := -1
var held_keys := {}
var held_buttons := {}
var last_pointer := Vector2.ZERO

func setup(app) -> void:
    host = app
    name = "FlashPlayerView"
    set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    mouse_filter = Control.MOUSE_FILTER_IGNORE
    var background := ColorRect.new()
    background.color = Color(0.025, 0.025, 0.03)
    background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    background.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(background)
    surface = TextureRect.new()
    surface.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    surface.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
    surface.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
    surface.mouse_filter = Control.MOUSE_FILTER_STOP
    surface.gui_input.connect(_surface_input)
    add_child(surface)
    header = PanelContainer.new()
    header.name = "Header"
    var header_style := StyleBoxFlat.new()
    header_style.bg_color = Color(0.025, 0.025, 0.03, 0.9)
    header_style.content_margin_left = 12
    header_style.content_margin_right = 12
    header_style.content_margin_top = 4
    header_style.content_margin_bottom = 4
    header.add_theme_stylebox_override("panel", header_style)
    header.hide()
    add_child(header)
    toolbar = HBoxContainer.new()
    toolbar.add_theme_constant_override("separation", 12)
    header.add_child(toolbar)
    var back := _button("‹", host._t("flash.back"))
    back.pressed.connect(close)
    var title := Label.new()
    title.name = "Title"
    title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
    title.add_theme_color_override("font_color", Color.WHITE)
    toolbar.add_child(title)
    refresh_button = _button("↻", host._t("flash.refresh"))
    refresh_button.pressed.connect(_restart)
    controls = VirtualControls.new()
    add_child(controls)
    controls.setup(host.ui_tokens)
    controls.set_input_mode(host.game_virtual_input_mode)
    controls.set_menu_button_enabled(host.game_virtual_menu_enabled)
    controls.set_keyboard_controls_opacity(host.game_virtual_keyboard_opacity)
    controls.menu_open_changed.connect(header.set_visible)
    controls.key_event_requested.connect(_virtual_key)
    controls.pointer_move_requested.connect(func(position: Vector2, _delta: Vector2): _send(3, _map(position)))
    controls.pointer_button_requested.connect(func(pressed: bool, button: int, _modifiers: int, position: Vector2):
        _send(4 if pressed else 5, _map(position), button))
    controls.pointer_scroll_requested.connect(func(delta: float, _position: Vector2): _send(6, Vector2(0, delta)))
    controls.input_mode_changed.connect(host._on_game_virtual_input_mode_changed)
    controls.keyboard_requested.connect(func():
        if DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD):
            DisplayServer.virtual_keyboard_show("")
    )
    controls.w_button.text = "↑"
    controls.a_button.text = "←"
    controls.s_button.text = "↓"
    controls.d_button.text = "→"
    resized.connect(_layout)
    _layout()

func _button(text: String, label: String) -> Button:
    var button := Button.new()
    button.text = text
    button.tooltip_text = label
    button.accessibility_name = label
    button.custom_minimum_size = Vector2(44, 44)
    host.ui_widgets.toolbar_button(button)
    button.add_theme_color_override("font_color", Color.WHITE)
    toolbar.add_child(button)
    return button

func _layout() -> void:
    if surface == null:
        return
    var safe: Rect2 = host._ui_safe_rect(size)
    header.position = safe.position
    header.size = Vector2(safe.size.x, 56)
    surface.position = safe.position
    surface.size = safe.size
    # Overlay the header without resizing the movie or moving the virtual menu.
    controls.layout(size, Rect2(safe.position + Vector2(0, 56), Vector2(safe.size.x, maxf(0, safe.size.y - 56))))

func open_entry(value: Dictionary) -> String:
    entry = value.duplicate(true)
    toolbar.get_node("Title").text = String(entry.get("name", "Flash"))
    if not ClassDB.class_exists("AetherFlashPlayer"):
        return host._t("flash.unavailable")
    native = ClassDB.instantiate("AetherFlashPlayer")
    add_child(native)
    if not native.is_supported():
        return host._t("flash.unavailable")
    native.playback_error.connect(_playback_error)
    if not native.open(String(entry.path), ProjectSettings.globalize_path("user://flash_saves")):
        return host._t("flash.open_failed", [native.get_error()])
    if host.runtime_default_font_path.is_empty():
        host._stage_runtime_fonts()
    if not host.runtime_default_font_path.is_empty():
        native.set_default_font(host.runtime_default_font_path)
    surface.texture = native.get_texture()
    controls.set_enabled(true)
    return ""

func _restart() -> void:
    _release_inputs()
    if native != null:
        native.close()
        native.queue_free()
        native = null
    var error := open_entry(entry)
    set_paused(false)
    if not error.is_empty():
        _playback_error(error)

func _virtual_key(pressed: bool, code: int, modifiers: int) -> void:
    var arrows := {87: 38, 65: 37, 83: 40, 68: 39}
    if arrows.has(code):
        _send(1 if pressed else 2, Vector2.ZERO, int(arrows[code]))
    else:
        _send(1 if pressed else 2, Vector2.ZERO, code, host._virtual_key_unicode(pressed, code, modifiers))

func set_paused(value: bool) -> void:
    if value:
        _release_inputs()
    paused = value
    if native != null:
        native.set_paused(paused or lifecycle_paused)
    controls.set_enabled(not paused and not lifecycle_paused)

func close() -> void:
    _release_inputs()
    controls.set_enabled(false)
    if DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD):
        DisplayServer.virtual_keyboard_hide()
    surface.texture = null
    if native != null:
        native.close()
        native.queue_free()
        native = null
    visible = false
    closed.emit()
    queue_free()

func _playback_error(message: String) -> void:
    close()
    host._show_message(message)

func _content_rect() -> Rect2:
    if surface.texture == null:
        return Rect2()
    var image_size := surface.texture.get_size()
    var scale := minf(surface.size.x / image_size.x, surface.size.y / image_size.y)
    var drawn := image_size * scale
    return Rect2(surface.global_position + (surface.size - drawn) * 0.5, drawn)

func _map(position: Vector2) -> Vector2:
    var rect := _content_rect()
    if rect.size.x <= 0 or rect.size.y <= 0:
        return Vector2.ZERO
    return ((position - rect.position) / rect.size * surface.texture.get_size()).clamp(Vector2.ZERO, surface.texture.get_size())

func _send(kind: int, position: Vector2 = Vector2.ZERO, code: int = 0, unicode: int = 0) -> void:
    if native != null and not paused and not lifecycle_paused:
        if kind == 1:
            held_keys[code] = true
        elif kind == 2:
            held_keys.erase(code)
        elif kind == 4:
            held_buttons[code] = true
        elif kind == 5:
            held_buttons.erase(code)
        if kind in [3, 4, 5]:
            last_pointer = position
        native.send_input(kind, position.x, position.y, code, unicode)
        if kind == 1 and unicode >= 32 and unicode != 127:
            native.send_input(7, 0, 0, 0, unicode)

func _release_inputs() -> void:
    controls.release_all()
    for code in held_keys.keys():
        _send(2, Vector2.ZERO, int(code))
    for button in held_buttons.keys():
        _send(5, last_pointer, int(button))
    primary_touch = -1

func _input(event: InputEvent) -> void:
    if not visible or native == null:
        return
    if controls.routes_pointer(event):
        return
    if event is InputEventKey:
        var unicode: int = event.unicode if event.pressed and not event.ctrl_pressed and not event.meta_pressed else 0
        var code: int = host._kirikiri_virtual_key(event)
        var physical: int = event.keycode if event.keycode != KEY_NONE else event.physical_keycode
        # Godot's printable key codes are Unicode; Flash uses Windows VK codes.
        var punctuation := {59: 186, 61: 187, 44: 188, 45: 189, 46: 190, 47: 191,
            96: 192, 91: 219, 92: 220, 93: 221, 39: 222}
        if punctuation.has(physical):
            code = int(punctuation[physical])
        elif physical == KEY_META:
            code = 15
        _send(1 if event.pressed else 2, Vector2.ZERO, code, unicode)
        get_viewport().set_input_as_handled()

func _surface_input(event: InputEvent) -> void:
    if paused or lifecycle_paused or controls.owns_viewport_pointer(event):
        return
    # GUI pointer positions are local to the image; the overlay uses viewport
    # positions, including when its touch joystick overlaps the image.
    var pointer: InputEvent = event.duplicate()
    if pointer is InputEventMouse or pointer is InputEventScreenTouch or pointer is InputEventScreenDrag:
        pointer.position += surface.global_position
    if controls.routes_pointer(pointer):
        return
    if event is InputEventMouse:
        if host._is_touch_platform() and event.device == -1:
            return
        var screen: Vector2 = surface.global_position + event.position
        if event is InputEventMouseButton and event.pressed and not _content_rect().has_point(screen):
            return
        if event is InputEventMouseMotion:
            _send(3, _map(screen))
        elif event is InputEventMouseButton:
            if event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
                if event.pressed:
                    _send(6, Vector2(0, event.factor if event.button_index == MOUSE_BUTTON_WHEEL_UP else -event.factor))
            elif event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
                var button := 0 if event.button_index == MOUSE_BUTTON_LEFT else (1 if event.button_index == MOUSE_BUTTON_RIGHT else 2)
                _send(3, _map(screen))
                _send(4 if event.pressed else 5, _map(screen), button)
        accept_event()
    elif event is InputEventScreenTouch:
        if event.pressed and primary_touch == -1:
            if not _content_rect().has_point(surface.global_position + event.position):
                return
            primary_touch = event.index
            _send(3, _map(surface.global_position + event.position))
            _send(4, _map(surface.global_position + event.position))
        elif not event.pressed and primary_touch == event.index:
            _send(5, _map(surface.global_position + event.position))
            primary_touch = -1
        accept_event()
    elif event is InputEventScreenDrag and event.index == primary_touch:
        _send(3, _map(surface.global_position + event.position))
        accept_event()

func _notification(what: int) -> void:
    if native == null or controls == null:
        return
    if what in [NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_APPLICATION_FOCUS_OUT]:
        _release_inputs()
        lifecycle_paused = true
        native.set_paused(true)
        controls.set_enabled(false)
    elif what in [NOTIFICATION_APPLICATION_RESUMED, NOTIFICATION_APPLICATION_FOCUS_IN]:
        lifecycle_paused = false
        native.set_paused(paused)
        controls.set_enabled(not paused)
