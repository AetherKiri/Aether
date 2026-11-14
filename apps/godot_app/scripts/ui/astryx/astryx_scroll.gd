extends ScrollContainer
## Keep the scrollbar's hit area and gutter stable while its ink fades out.
const IDLE_SECONDS := 0.65
const FADE_SECONDS := 0.2
const INPUT_DEVICE_ID_EMULATION := -1
var idle_timer: Timer
var fade: Tween
var pointer_over_bar := false
var mouse_dragging_bar := false
var bar_touch := -1
var scrolling := false

func _init() -> void:
    scroll_deadzone = 12

func _ready() -> void:
    idle_timer = Timer.new()
    idle_timer.one_shot = true
    idle_timer.wait_time = IDLE_SECONDS
    idle_timer.timeout.connect(_fade_scrollbar)
    add_child(idle_timer)
    get_v_scroll_bar().modulate.a = 0.0
    get_v_scroll_bar().value_changed.connect(func(_value: float): _show_scrollbar())
    get_v_scroll_bar().mouse_exited.connect(func():
        if pointer_over_bar:
            pointer_over_bar = false
            _show_scrollbar())
    scroll_started.connect(func():
        scrolling = true
        _show_scrollbar())
    scroll_ended.connect(func():
        scrolling = false
        _show_scrollbar())
    visibility_changed.connect(func():
        if not is_visible_in_tree():
            pointer_over_bar = false
            mouse_dragging_bar = false
            bar_touch = -1
            scrolling = false
            idle_timer.stop()
            if fade != null:
                fade.kill()
            get_v_scroll_bar().modulate.a = 0.0)

func _input(event: InputEvent) -> void:
    var bar := get_v_scroll_bar()
    if not is_visible_in_tree() or not bar.is_visible_in_tree():
        return
    if event is InputEventMouseMotion and event.device != INPUT_DEVICE_ID_EMULATION:
        var hovered := bar.get_global_rect().has_point(event.position)
        if hovered != pointer_over_bar:
            pointer_over_bar = hovered
            _show_scrollbar()
    elif event is InputEventMouseButton and event.device != INPUT_DEVICE_ID_EMULATION:
        if event.button_index == MOUSE_BUTTON_LEFT:
            if event.pressed and bar.get_global_rect().has_point(event.position):
                mouse_dragging_bar = true
                _show_scrollbar()
            elif not event.pressed and mouse_dragging_bar:
                mouse_dragging_bar = false
                _show_scrollbar()
    elif event is InputEventScreenTouch:
        if event.pressed and bar.get_global_rect().has_point(event.position):
            bar_touch = event.index
            _show_scrollbar()
        elif not event.pressed and event.index == bar_touch:
            bar_touch = -1
            _show_scrollbar()

func _show_scrollbar() -> void:
    if not is_inside_tree() or not is_instance_valid(idle_timer) or not idle_timer.is_inside_tree():
        return
    if fade != null:
        fade.kill()
    get_v_scroll_bar().modulate.a = 1.0
    idle_timer.start()

func _fade_scrollbar() -> void:
    if scrolling or pointer_over_bar or mouse_dragging_bar or bar_touch >= 0:
        return
    fade = create_tween()
    fade.tween_property(get_v_scroll_bar(), "modulate:a", 0.0, FADE_SECONDS)
