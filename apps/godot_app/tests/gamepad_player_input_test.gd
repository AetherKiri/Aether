extends SceneTree

const Main = preload("res://scripts/main.gd")
const Adapter = preload("res://scripts/gamepad_player_input.gd")
const FlashView = preload("res://scripts/flash_player_view.gd")
const RenpyView = preload("res://scripts/renpy_player_view.gd")
const TyranoView = preload("res://scripts/tyrano_player_view.gd")

class FakeFlash extends Node:
    var events: Array = []
    func send_input(kind: int, x: float, y: float, code: int, unicode: int) -> bool:
        events.append([kind, x, y, code, unicode])
        return true

class FakeRenpy extends Node:
    var events: Array = []
    func send_input(event: Dictionary) -> void:
        events.append(event)
    func set_rect(_rect: Rect2, _size: Vector2) -> void:
        pass
    func set_paused(_paused: bool) -> void:
        pass
    func close() -> void:
        pass

class FakeTyrano extends Node:
    var scripts: Array = []
    func evaluate_script(script: String) -> void:
        scripts.append(script)
    func set_rect(_rect: Rect2, _size: Vector2) -> void:
        pass
    func set_paused(_paused: bool) -> void:
        pass
    func close() -> void:
        pass

var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _expect(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error(message)

func _run() -> void:
    var app := Control.new()
    root.add_child(app)
    app.set_script(Main)
    app.set_process(false)
    app.set_process_input(false)
    app.set_process_unhandled_input(false)
    app.add_child(app.ui_motion)
    app.ui_motion.reduced_motion = true
    app.size = Vector2(1000, 700)

    var flash := FlashView.new()
    app.flash_view = flash
    app.add_child(flash)
    flash.setup(app)
    flash.set_process(false)
    flash.native = FakeFlash.new()
    flash.add_child(flash.native)
    flash.surface.size = Vector2(800, 600)
    flash.surface.texture = ImageTexture.create_from_image(Image.create(800, 600, false, Image.FORMAT_RGBA8))
    _expect(Adapter.active_view(app) == flash and Adapter.ready(flash), "Flash view is detected without native runtime")
    var point := Adapter.bounds(flash).get_center()
    Adapter.pointer(flash, "click", point)
    _expect(flash.native.events.size() == 3 and flash.native.events[1][0] == 4 and flash.native.events[2][0] == 5, "Flash receives paired pointer edges")
    _expect(is_equal_approx(float(flash.native.events[1][1]), 400.0), "Flash cursor maps into movie coordinates")
    app._on_gamepad_button_changed(JOY_BUTTON_X, true)
    app._on_gamepad_button_changed(JOY_BUTTON_X, false)
    _expect(flash.native.events[-2][0] == 1 and flash.native.events[-1][0] == 2, "Flash skip is released")
    flash.controls.set_enabled(true)
    app._on_gamepad_menu()
    _expect(flash.controls.is_panel_open() and app._gamepad_focus_root() == flash.controls, "Flash menu participates in shared focus routing")
    app._on_gamepad_cancel()
    _expect(not flash.controls.is_panel_open(), "Flash menu closes before sending game Escape")
    flash.hide()

    var renpy := RenpyView.new()
    app.renpy_view = renpy
    app.add_child(renpy)
    renpy.setup(app)
    renpy.set_process(false)
    renpy.native = FakeRenpy.new()
    renpy.add_child(renpy.native)
    renpy.ready_received = true
    Adapter.key(renpy, true, 13)
    Adapter.key(renpy, false, 13)
    Adapter.pointer(renpy, "click", Adapter.bounds(renpy).get_center())
    _expect(renpy.native.events[0].key == "return" and not renpy.native.events[1].pressed, "RenPy uses existing key dictionary input")
    _expect(renpy.native.events[2].x == 0.5 and renpy.native.events[2].y == 0.5, "RenPy pointer is normalized to the native surface")
    _expect(renpy.native.events[3].pressed and not renpy.native.events[4].pressed, "RenPy click is paired")
    app._on_gamepad_menu()
    _expect(app.gamepad_toolbar_mode and app._gamepad_focus_root() == renpy.header, "Start focuses RenPy toolbar, not hidden library")
    app._on_gamepad_cancel()
    _expect(not app.gamepad_toolbar_mode, "B leaves RenPy toolbar without closing the game")
    renpy.hide()

    var tyrano := TyranoView.new()
    app.tyrano_view = tyrano
    app.add_child(tyrano)
    tyrano.setup(app)
    tyrano.set_process(false)
    tyrano.native = FakeTyrano.new()
    tyrano.add_child(tyrano.native)
    tyrano.ready_received = true
    Adapter.pointer(tyrano, "click", Adapter.bounds(tyrano).get_center())
    Adapter.pointer(tyrano, "scroll", Vector2.ZERO, -1)
    _expect(tyrano.native.scripts == ["window.AetherTyranoHost?.key(13,true)", "window.AetherTyranoHost?.key(13,false)",
        "window.AetherTyranoHost?.key(33,true)", "window.AetherTyranoHost?.key(33,false)"], "Tyrano uses its existing virtual-key API")
    tyrano.lifecycle_paused = true
    var previous: int = tyrano.native.scripts.size()
    Adapter.key(tyrano, true, 13)
    _expect(tyrano.native.scripts.size() == previous, "paused players reject controller input")

    # Avoid native shutdown hooks; these are fake transports, not engines.
    flash.native = null
    renpy.native = null
    tyrano.native = null
    app.flash_view = null
    app.renpy_view = null
    app.tyrano_view = null
    app.free()
    await process_frame
    print("gamepad_player_input_test: %s" % ("PASS" if failures == 0 else "FAIL (%d)" % failures))
    quit(0 if failures == 0 else 1)
