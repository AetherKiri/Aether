extends SceneTree

class FlashApp:
    extends "res://scripts/main.gd"

    func _ready() -> void:
        ui_motion.reduced_motion = true
        add_child(ui_motion)
        _apply_ui_font()
        _build_ui()

    func _process(_delta: float) -> void:
        pass

    func _require_legal_documents_for_media() -> bool:
        return true

var app: FlashApp
var failures := 0

func _expect(value: bool, message: String) -> void:
    if not value:
        failures += 1
        push_error(message)

func _capture(name: String) -> void:
    var output := OS.get_environment("AETHERKIRI_FLASH_CAPTURE_DIR")
    if output.is_empty() or DisplayServer.get_name() == "headless":
        return
    await RenderingServer.frame_post_draw
    DirAccess.make_dir_recursive_absolute(output)
    root.get_texture().get_image().save_png(output.path_join(name + ".png"))

func _initialize() -> void:
    call_deferred("_run")

func _run() -> void:
    root.size = Vector2i(1280, 720)
    root.gui_embed_subwindows = true
    var path := OS.get_environment("AETHERKIRI_TEST_FLASH")
    if path.is_empty():
        path = ProjectSettings.globalize_path("res://../../packages/ruffle/tests/tests/swfs/from_shumway/timeline/timeline_loop/test.swf")
    if not FileAccess.file_exists(path) or not ClassDB.class_exists("AetherFlashPlayer"):
        push_error("Flash native build and AETHERKIRI_TEST_FLASH (or Ruffle fixtures) are required")
        quit(2)
        return
    app = FlashApp.new()
    app.home_library_mode = "flash"
    app.shell_route = "flash"
    root.add_child(app)
    app._open_flash_player({"path": path, "name": "Flash 播放验证"})
    _expect(app._is_flash_active() and not app.shell_root.visible, "Opening SWF enters the native player")
    if not app._is_flash_active():
        quit(1)
        return
    var view = app.flash_view
    var texture: Texture2D = view.surface.texture
    _expect(texture != null and texture.get_width() > 0 and texture.get_height() > 0, "Flash provides a usable texture")
    await create_timer(0.15).timeout
    var initial := texture.get_image().get_data()
    var animated := false
    for _step in range(20):
        await create_timer(0.02).timeout
        animated = animated or texture.get_image().get_data() != initial
    _expect(animated, "Native Godot playback updates the animated SWF texture")
    view.controls.show_virtual_controls()
    view.controls.space_button.button_down.emit()
    view.controls.space_button.button_up.emit()
    _expect(view.held_keys.is_empty(), "Virtual keys release after forwarding input to Ruffle")
    await _capture("native-flash-player")
    view.set_paused(true)
    var paused := texture.get_image().get_data()
    await create_timer(0.2).timeout
    _expect(texture.get_image().get_data() == paused, "Pausing holds the current rendered frame")
    view.set_paused(false)
    view._restart()
    _expect(app._is_flash_active() and view.native != null, "Restart recreates a working native player")
    root.size = Vector2i(844, 390)
    app._fit_full_rects()
    await create_timer(0.15).timeout
    view.controls.show_virtual_controls()
    _expect(view.size.is_equal_approx(Vector2(844, 390)), "Flash resizes with the mobile viewport")
    _expect(Rect2(Vector2.ZERO, view.size).encloses(view.controls.enter_button.get_global_rect()), "Virtual buttons remain within the landscape viewport")
    await _capture("native-flash-controls-landscape")
    app._handle_go_back_request()
    _expect(not app._is_flash_active() and app.shell_root.visible and app.shell_route == "flash", "System back closes Flash and restores its library")
    var invalid = ClassDB.instantiate("AetherFlashPlayer")
    root.add_child(invalid)
    _expect(not invalid.open(path + ".missing", ProjectSettings.globalize_path("user://flash_saves")) and not invalid.get_error().is_empty(), "Invalid files produce a useful error without crashing")
    invalid.queue_free()
    app.queue_free()
    await process_frame
    print("FLASH_PLAYER_SMOKE_OK" if failures == 0 else "FLASH_PLAYER_SMOKE_FAILED: %d" % failures)
    quit(0 if failures == 0 else 1)
