extends RefCounted
## Non-scrolling navigation uses slide-to-select. Scrollable content remains
## owned by ScrollContainer, whose scroll-begin notification cancels clicks.
const GROUP_META := "astryx_touch_navigation"
const EMULATED_MOUSE := -1
var view: Control
var touch_index := -1
var group: Control
var highlighted: Button
var styles: Dictionary = {}
var cancelled := false
var touched_buttons: Array[WeakRef] = []
var feedback_generation := 0

func _init(shell: Control) -> void:
    view = shell

func _button_at(position: Vector2) -> BaseButton:
    var control: Control = view.host._control_at_pointer(position)
    return view.host._nearest_base_button(control) if control != null else null

func _remember_button(button: BaseButton) -> void:
    if not is_instance_valid(button):
        return
    for reference in touched_buttons:
        if reference.get_ref() == button:
            return
    touched_buttons.append(weakref(button))

func _clear_pointer_feedback(position: Vector2, finished: bool = true) -> void:
    if not is_instance_valid(view) or not view.is_inside_tree():
        return
    var control := view.get_viewport().gui_get_hovered_control()
    var hovered: BaseButton = view.host._nearest_base_button(control) if control != null else null
    _remember_button(hovered)
    _remember_button(_button_at(position))
    for reference in touched_buttons:
        var button := reference.get_ref() as BaseButton
        if is_instance_valid(button):
            # Touch-emulated mouse hover has no pointer to leave the target.
            # Clear only transient feedback, preserving the selected tab/style.
            button.notification(Control.NOTIFICATION_MOUSE_EXIT)
            if finished:
                button.notification(Control.NOTIFICATION_SCROLL_BEGIN)
                if button.is_inside_tree():
                    button.release_focus()
    if finished:
        touched_buttons.clear()

func _defer_feedback_cleanup(position: Vector2, finished: bool) -> void:
    var generation := feedback_generation
    # Viewport hover dispatch can run after _input, including after a drag was
    # consumed. Clear that later feedback too, without cancelling a native tap.
    (func():
        if generation == feedback_generation:
            _clear_pointer_feedback(position, finished)
    ).call_deferred()

func _highlight(button: Button) -> void:
    if highlighted == button:
        return
    if is_instance_valid(highlighted):
        for key in styles:
            highlighted.add_theme_stylebox_override(key, styles[key])
        highlighted.notification(Control.NOTIFICATION_SCROLL_BEGIN)
        highlighted.notification(Control.NOTIFICATION_MOUSE_EXIT)
        if highlighted.is_inside_tree():
            highlighted.release_focus()
    highlighted = button
    styles.clear()
    if highlighted != null:
        _remember_button(highlighted)
        for key in ["normal", "hover"]:
            styles[key] = highlighted.get_theme_stylebox(key)
            highlighted.add_theme_stylebox_override(key, highlighted.get_theme_stylebox("pressed"))

func cancel_gesture() -> void:
    # Retain ownership until release so rotation/rebuild cannot activate a new
    # button that happened to appear beneath a finger already held down.
    cancelled = true
    _highlight(null)

func _candidate(position: Vector2) -> Button:
    if cancelled or not is_instance_valid(group) or not group.is_visible_in_tree() or not group.get_global_rect().has_point(position):
        return null
    var button := _button_at(position) as Button
    if button == null or button.disabled or button.get_parent() != group or not button.get_meta(GROUP_META, false):
        return null
    return button

func handle_input(event: InputEvent) -> bool:
    if not view.host._is_touch_platform():
        return false
    if not view.is_visible_in_tree() or view.host.game_running:
        cancel_gesture()
        touch_index = -1
        group = null
        return false
    if event is InputEventMouseMotion or event is InputEventMouseButton:
        if event.device == EMULATED_MOUSE:
            var released: bool = event is InputEventMouseButton and not event.pressed
            _defer_feedback_cleanup(event.position, released)
            return touch_index >= 0
        # An attached mouse still gets ordinary hover, including when its
        # first movement follows a touch on the same control.
        if event is InputEventMouseMotion and view.is_visible_in_tree():
            feedback_generation += 1
            touched_buttons.clear()
            var button := _button_at(event.position)
            if button != null and not button.is_hovered():
                button.notification(Control.NOTIFICATION_MOUSE_ENTER)
        return false
    if not event is InputEventScreenTouch and not event is InputEventScreenDrag:
        return false
    var position: Vector2 = event.position
    feedback_generation += 1
    _remember_button(_button_at(position))
    if event is InputEventScreenTouch and not event.pressed:
        _defer_feedback_cleanup(position, true)
    elif event is InputEventScreenDrag:
        _defer_feedback_cleanup(position, false)
    if view.host.modal_layer.visible:
        cancel_gesture()
        touch_index = -1
        group = null
        return false
    if event is InputEventScreenTouch:
        if event.pressed:
            if touch_index >= 0:
                if event.index != touch_index:
                    cancel_gesture()
                return true
            var button := _button_at(position) as Button
            if button == null or button.disabled or not button.get_meta(GROUP_META, false):
                return false
            var scroll: ScrollContainer = view.host._nearest_scroll_container(button)
            if scroll != null:
                var bar := scroll.get_v_scroll_bar()
                if bar.max_value > bar.page + 0.5:
                    # The settings list can overflow on compact screens. Its
                    # entire gesture stays native, even if it ends on a row.
                    return false
            touch_index = event.index
            group = button.get_parent()
            cancelled = false
            _highlight(button)
            return true
        if event.index != touch_index:
            return false
        var target := _candidate(position) if not event.canceled else null
        _highlight(null)
        touch_index = -1
        group = null
        cancelled = false
        _clear_pointer_feedback(position)
        if is_instance_valid(target):
            target.pressed.emit()
        return true
    if event.index == touch_index:
        _highlight(_candidate(position))
        return true
    return false
