extends SubViewport

# Native surfaces cover Godot's main canvas. Render the existing controls in a
# transparent viewport and hand that layer to the native compositor. Engines
# only present pixels and return pointer events; they never implement buttons.
signal frame_ready(frame: Dictionary)

const VirtualControls = preload("res://scripts/game_virtual_controls.gd")
var controls
var compositor
var frame: Dictionary = {}
var view_size := Vector2.ONE
var _render_scale := Vector2.ONE
var _draw_pending := 0
var _previous_pixels := 0
var _hovering := false

func setup(host) -> void:
    name = "NativeGameControls"
    transparent_bg = true
    disable_3d = true
    handle_input_locally = true
    render_target_update_mode = SubViewport.UPDATE_ALWAYS
    var theme_root := Control.new()
    theme_root.theme = host.theme
    theme_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(theme_root)
    controls = VirtualControls.new()
    theme_root.add_child(controls)
    controls.setup(host.ui_tokens)
    controls.set_enabled(false)
    controls.set_input_mode(host.game_virtual_input_mode)
    controls.set_menu_button_enabled(host.game_virtual_menu_enabled)
    controls.set_keyboard_controls_opacity(host.game_virtual_keyboard_opacity)
    controls.menu_open_changed.connect(func(_open): invalidate())
    controls.virtual_controls_requested.connect(invalidate)
    controls.input_mode_changed.connect(func(mode):
        host._on_game_virtual_input_mode_changed(mode)
        invalidate())
    if ClassDB.class_exists("AetherNativeControls"):
        var candidate = ClassDB.instantiate("AetherNativeControls")
        if candidate.is_supported():
            compositor = candidate
            add_child(compositor)
        else:
            candidate.free()
    RenderingServer.frame_post_draw.connect(_present)

func layout(rect: Rect2, window_size: Vector2) -> void:
    # Match the main canvas' backing resolution, including content scale on
    # Retina displays. Layout/input remain in the original logical units.
    var ratio := Vector2(get_window().size) / window_size.max(Vector2.ONE)
    var pixels := Vector2i((rect.size * ratio).ceil()).max(Vector2i.ONE)
    if size != pixels or not view_size.is_equal_approx(rect.size):
        view_size = rect.size.max(Vector2.ONE)
        size = pixels
        _render_scale = Vector2(size) / view_size
        controls.scale = _render_scale
        controls.layout(view_size, Rect2(Vector2.ZERO, view_size))
        invalidate()
    if compositor != null:
        compositor.set_rect(rect, window_size)

func set_enabled(value: bool) -> void:
    controls.set_enabled(value)
    if compositor != null:
        compositor.set_visible(value and not controls.pointer_regions().is_empty())
    _previous_pixels = 0
    invalidate()

func set_virtual_controls(value: bool) -> void:
    if value:
        controls.show_virtual_controls()
    else:
        controls.hide_virtual_controls()
    invalidate()

func invalidate() -> void:
    _draw_pending = 2

func route_input(event: InputEvent) -> bool:
    var routed: bool = controls.routes_pointer(event)
    # Even leaving a control must reach GUI dispatch to clear its hover state.
    var rendered := event.duplicate() as InputEvent
    rendered.position *= _render_scale
    if rendered is InputEventMouse:
        rendered.global_position *= _render_scale
    push_input(rendered, true)
    if routed or _hovering:
        invalidate()
    _hovering = routed
    return routed

func pointer_input(value: Dictionary) -> void:
    var event: InputEvent
    var point := Vector2(float(value.get("x", 0)), float(value.get("y", 0))) * view_size
    if String(value.get("type", "")) == "move":
        var motion := InputEventMouseMotion.new()
        motion.position = point
        motion.global_position = point
        motion.button_mask = int(value.get("buttons", 0))
        event = motion
    else:
        var button := InputEventMouseButton.new()
        button.position = point
        button.global_position = point
        button.button_index = int(value.get("button", 1))
        button.pressed = bool(value.get("pressed", false))
        event = button
    route_input(event)

func _present() -> void:
    if _draw_pending <= 0 or DisplayServer.get_name() == "headless":
        return
    _draw_pending -= 1
    var image := get_texture().get_image()
    if image == null or image.is_empty():
        return
    var regions: Array = []
    for rect in controls.pointer_regions():
        regions.append([rect.position.x / view_size.x, rect.position.y / view_size.y,
            rect.size.x / view_size.x, rect.size.y / view_size.y])
    var pixels := hash([image.get_data(), regions])
    if pixels == _previous_pixels and not frame.is_empty():
        return
    _previous_pixels = pixels
    frame = {"width": size.x, "height": size.y, "regions": regions,
        "menu": controls.is_menu_open(), "controls": controls.is_panel_open()}
    if compositor != null:
        compositor.present(image, regions)
    else:
        frame.image = Marshalls.raw_to_base64(image.save_png_to_buffer())
    frame_ready.emit(frame)

func _exit_tree() -> void:
    if RenderingServer.frame_post_draw.is_connected(_present):
        RenderingServer.frame_post_draw.disconnect(_present)
