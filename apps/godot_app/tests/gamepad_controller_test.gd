extends SceneTree

const GamepadController = preload("res://scripts/gamepad_controller.gd")

func _initialize() -> void:
    call_deferred("_run")

func _run() -> void:
    var controller := GamepadController.new()
    root.add_child(controller)

    controller.configure(0.20, 1.75, 1200.0)
    if not is_equal_approx(controller.dead_zone, 0.20):
        _fail("dead-zone configuration was not retained")
        return
    if not is_equal_approx(controller.sensitivity, 1.75):
        _fail("sensitivity configuration was not retained")
        return
    if not is_equal_approx(controller.cursor_speed, 1200.0):
        _fail("cursor-speed configuration was not retained")
        return

    controller.configure(-1.0, 99.0, -1.0)
    if not is_equal_approx(controller.dead_zone, GamepadController.DEAD_ZONE_MIN):
        _fail("dead-zone lower bound was not clamped")
        return
    if not is_equal_approx(controller.sensitivity, 2.5):
        _fail("sensitivity upper bound was not clamped")
        return
    if not is_equal_approx(controller.cursor_speed, 120.0):
        _fail("cursor-speed lower bound was not clamped")
        return

    controller.dead_zone = 0.16
    var centered := controller._axis(0.10, 0.0)
    if centered != Vector2.ZERO:
        _fail("values inside the dead zone should be ignored")
        return
    var right := controller._axis(1.0, 0.0)
    if right.x <= 0.99 or absf(right.y) > 0.001:
        _fail("full right stick should produce a normalized right vector")
        return

    if controller._cardinal(Vector2(0.8, 0.2)) != Vector2.RIGHT:
        _fail("horizontal navigation did not snap to the nearest cardinal")
        return
    if controller._cardinal(Vector2(-0.1, -0.9)) != Vector2.UP:
        _fail("vertical navigation did not snap to the nearest cardinal")
        return

    var directions: Array[Vector2] = []
    controller.navigation_vector_changed.connect(func(direction: Vector2): directions.append(direction))
    controller._update_navigation(Vector2(0.1, 0.0), 0.01)
    controller._update_navigation(Vector2(0.1, 0.0), 0.10)
    assert(directions == [Vector2.RIGHT], "a lightly pushed stick must respect the repeat delay")
    controller._update_navigation(Vector2(0.1, 0.0), 0.25)
    assert(directions == [Vector2.RIGHT, Vector2.RIGHT])
    controller._update_navigation(Vector2.UP, 0.01)
    assert(directions.back() == Vector2.UP, "changing direction must navigate immediately")
    controller.enabled = false
    assert(controller._repeat_direction == Vector2.ZERO)

    var actions: Array = []
    controller.confirm_pressed.connect(func(): actions.append("confirm"))
    controller.cancel_pressed.connect(func(): actions.append("cancel"))
    controller.menu_pressed.connect(func(): actions.append("menu"))
    controller.page_previous_pressed.connect(func(): actions.append("previous"))
    controller.page_next_pressed.connect(func(): actions.append("next"))
    controller._emit_action_button(JOY_BUTTON_A)
    controller._emit_action_button(JOY_BUTTON_B)
    controller._emit_action_button(JOY_BUTTON_START)
    controller._emit_action_button(JOY_BUTTON_LEFT_SHOULDER)
    controller._emit_action_button(JOY_BUTTON_RIGHT_SHOULDER)
    assert(actions == ["confirm", "cancel", "menu", "previous", "next"])
    assert(controller._button_key(7, JOY_BUTTON_A) == "7:%d" % JOY_BUTTON_A)

    controller.enabled = true
    var button_down := InputEventJoypadButton.new()
    button_down.device = 7
    button_down.button_index = JOY_BUTTON_A
    button_down.pressed = true
    controller._input(button_down)
    controller._input(button_down)
    assert(actions.count("confirm") == 2, "repeated press events must be edge-safe")
    var button_up := InputEventJoypadButton.new()
    button_up.device = 7
    button_up.button_index = JOY_BUTTON_A
    button_up.pressed = false
    controller._input(button_up)

    print("gamepad_controller_test: PASS")
    quit(0)

func _fail(message: String) -> void:
    printerr("gamepad_controller_test: FAIL: %s" % message)
    quit(1)
