extends Node

## Cross-platform controller adapter.
## Godot normalizes XInput, SDL, DualShock, Switch and mobile controller
## devices into Joypad events, so the UI does not depend on vendor labels.

signal device_changed(device_id: int, connected: bool, name: String)
signal navigation_vector_changed(vector: Vector2)
signal pointer_vector_changed(vector: Vector2)
signal confirm_pressed
signal cancel_pressed
signal menu_pressed
signal page_previous_pressed
signal page_next_pressed
signal input_activity

const DEAD_ZONE_MIN := 0.04
const DEAD_ZONE_MAX := 0.45
const DEFAULT_DEAD_ZONE := 0.16
const DEFAULT_SENSITIVITY := 1.0
const DEFAULT_CURSOR_SPEED := 860.0
const REPEAT_DELAY := 0.34
const REPEAT_INTERVAL := 0.085
const ACTION_BUTTONS := [
    JOY_BUTTON_A,
    JOY_BUTTON_B,
    JOY_BUTTON_START,
    JOY_BUTTON_LEFT_SHOULDER,
    JOY_BUTTON_RIGHT_SHOULDER,
]
const TRACKED_BUTTONS := [
    JOY_BUTTON_A,
    JOY_BUTTON_B,
    JOY_BUTTON_START,
    JOY_BUTTON_LEFT_SHOULDER,
    JOY_BUTTON_RIGHT_SHOULDER,
    JOY_BUTTON_DPAD_UP,
    JOY_BUTTON_DPAD_DOWN,
    JOY_BUTTON_DPAD_LEFT,
    JOY_BUTTON_DPAD_RIGHT,
]

var enabled := true:
    set(value):
        enabled = value
        if not value:
            _repeat_direction = Vector2.ZERO
            _repeat_time = 0.0
var dead_zone := DEFAULT_DEAD_ZONE
var sensitivity := DEFAULT_SENSITIVITY
var cursor_speed := DEFAULT_CURSOR_SPEED
var active_device := -1
var _repeat_time := 0.0
var _repeat_direction := Vector2.ZERO
var _last_device_names: Dictionary = {}
var _button_states: Dictionary = {}

func has_device() -> bool:
    return active_device >= 0

func configure(next_dead_zone: float, next_sensitivity: float, next_cursor_speed: float) -> void:
    dead_zone = clampf(next_dead_zone, DEAD_ZONE_MIN, DEAD_ZONE_MAX)
    sensitivity = clampf(next_sensitivity, 0.25, 2.5)
    cursor_speed = clampf(next_cursor_speed, 120.0, 2400.0)

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    if not Input.joy_connection_changed.is_connected(_on_joy_connection_changed):
        Input.joy_connection_changed.connect(_on_joy_connection_changed)
    refresh_devices()

func refresh_devices() -> void:
    var connected := Input.get_connected_joypads()
    if active_device >= 0 and not connected.has(active_device):
        active_device = -1
    for device in connected:
        var name := Input.get_joy_name(device)
        if not _last_device_names.has(device) or String(_last_device_names[device]) != name:
            _announce_device(device, true, name)
        if active_device < 0:
            active_device = device
    for device_variant in _last_device_names.keys().duplicate():
        var device := int(device_variant)
        if not connected.has(device):
            _announce_device(device, false, String(_last_device_names[device]))
            _last_device_names.erase(device)
            _clear_button_states(device)
    _reset_repeat_if_no_device()

func _on_joy_connection_changed(device: int, connected: bool) -> void:
    if connected:
        _announce_device(device, true, Input.get_joy_name(device))
        if active_device < 0:
            active_device = device
        input_activity.emit()
    else:
        var name := String(_last_device_names.get(device, Input.get_joy_name(device)))
        if _last_device_names.has(device):
            _announce_device(device, false, name)
            _last_device_names.erase(device)
        _clear_button_states(device)
        if active_device == device:
            active_device = -1
        refresh_devices()

func _clear_button_states(device: int) -> void:
    for button in TRACKED_BUTTONS:
        _button_states.erase(_button_key(device, button))

func _button_key(device: int, button: int) -> String:
    return "%d:%d" % [device, button]

func _reset_repeat_if_no_device() -> void:
    if active_device < 0:
        _repeat_direction = Vector2.ZERO
        _repeat_time = 0.0

func _process(delta: float) -> void:
    if not enabled or get_tree().paused:
        return
    refresh_devices()
    var navigation := Vector2.ZERO
    var pointer := Vector2.ZERO
    if active_device >= 0:
        navigation = _axis(Input.get_joy_axis(active_device, JOY_AXIS_LEFT_X), Input.get_joy_axis(active_device, JOY_AXIS_LEFT_Y))
        pointer = _axis(Input.get_joy_axis(active_device, JOY_AXIS_RIGHT_X), Input.get_joy_axis(active_device, JOY_AXIS_RIGHT_Y))
        var dpad := Vector2(
            float(Input.is_joy_button_pressed(active_device, JOY_BUTTON_DPAD_RIGHT)) - float(Input.is_joy_button_pressed(active_device, JOY_BUTTON_DPAD_LEFT)),
            float(Input.is_joy_button_pressed(active_device, JOY_BUTTON_DPAD_DOWN)) - float(Input.is_joy_button_pressed(active_device, JOY_BUTTON_DPAD_UP))
        )
        if dpad != Vector2.ZERO:
            navigation = dpad
        _poll_action_buttons(active_device)
    _update_navigation(navigation, delta)
    if pointer.length_squared() > 0.0:
        input_activity.emit()
        pointer_vector_changed.emit(pointer * sensitivity * delta)

func _update_navigation(navigation: Vector2, delta: float) -> void:
    if navigation != Vector2.ZERO:
        input_activity.emit()
        _repeat_time += delta
        var direction := _cardinal(navigation)
        if _repeat_direction != direction:
            _repeat_direction = direction
            _repeat_time = 0.0
            navigation_vector_changed.emit(_repeat_direction)
        elif _repeat_time >= REPEAT_DELAY:
            _repeat_time -= REPEAT_INTERVAL
            navigation_vector_changed.emit(_repeat_direction)
    else:
        _repeat_direction = Vector2.ZERO
        _repeat_time = 0.0

func _input(event: InputEvent) -> void:
    if event is InputEventJoypadMotion:
        var axis_event := event as InputEventJoypadMotion
        if enabled and not get_tree().paused and absf(axis_event.axis_value) > dead_zone:
            _mark_device_active(axis_event.device)
        if axis_event.axis in [JOY_AXIS_LEFT_X, JOY_AXIS_LEFT_Y, JOY_AXIS_RIGHT_X, JOY_AXIS_RIGHT_Y]:
            get_viewport().set_input_as_handled()
        return
    if not event is InputEventJoypadButton:
        return
    var button := event as InputEventJoypadButton
    _mark_device_active(button.device)
    var key := _button_key(button.device, button.button_index)
    var was_pressed := bool(_button_states.get(key, false))
    _button_states[key] = button.pressed
    # Consume both edges so Godot's default ui_accept/ui_direction bindings
    # cannot activate the same Control again after our adapter handles it.
    if button.button_index in TRACKED_BUTTONS:
        get_viewport().set_input_as_handled()
    if not enabled or get_tree().paused or not button.pressed or was_pressed or not button.button_index in ACTION_BUTTONS:
        return
    _emit_action_button(button.button_index)

func _mark_device_active(device: int) -> void:
    if active_device == device:
        return
    active_device = device
    if not _last_device_names.has(device):
        _announce_device(device, true, Input.get_joy_name(device))
    input_activity.emit()

func _poll_action_buttons(device: int) -> void:
    for button in ACTION_BUTTONS:
        var key := _button_key(device, button)
        var pressed := Input.is_joy_button_pressed(device, button)
        var previous := bool(_button_states.get(key, false))
        if pressed and not previous:
            _emit_action_button(button)
        _button_states[key] = pressed

func _emit_action_button(button: int) -> void:
    input_activity.emit()
    match button:
        JOY_BUTTON_A:
            confirm_pressed.emit()
        JOY_BUTTON_B:
            cancel_pressed.emit()
        JOY_BUTTON_START:
            menu_pressed.emit()
        JOY_BUTTON_LEFT_SHOULDER:
            page_previous_pressed.emit()
        JOY_BUTTON_RIGHT_SHOULDER:
            page_next_pressed.emit()

func _axis(x: float, y: float) -> Vector2:
    var raw := Vector2(x, y)
    var magnitude := raw.length()
    if magnitude <= dead_zone:
        return Vector2.ZERO
    var normalized := clampf((magnitude - dead_zone) / (1.0 - dead_zone), 0.0, 1.0)
    return raw / magnitude * pow(normalized, 1.35)

func _cardinal(vector: Vector2) -> Vector2:
    return Vector2(signf(vector.x), 0.0) if absf(vector.x) >= absf(vector.y) else Vector2(0.0, signf(vector.y))

func _poll_devices() -> void:
    refresh_devices()

func _announce_device(device: int, connected: bool, name: String) -> void:
    if connected:
        _last_device_names[device] = name
    device_changed.emit(device, connected, name)
