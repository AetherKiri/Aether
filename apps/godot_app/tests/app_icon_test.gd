extends SceneTree
const Suite := preload("res://tests/astryx_shell_test.gd")
const Icons := preload("res://scripts/ui/app_icon.gd")

class IconController extends Suite.TestController:
    var applied: Array[String] = []
    var fail_save := false
    func save_preferences(path: String = "") -> Error:
        return ERR_CANT_CREATE if fail_save else super.save_preferences(path)
    func _apply_app_icon() -> void:
        applied.append("astryx/" + theme_mode if enabled else "classic")

var failures := 0
func _initialize() -> void:
    call_deferred("_run")

func _expect(ok: bool, message: String) -> void:
    if not ok:
        failures += 1
        push_error(message)

func _run() -> void:
    root.size = Vector2i(1180, 820)
    root.content_scale_size = Vector2i.ZERO
    var classic := Icons.texture(false).get_image()
    var astryx := Icons.texture(true).get_image()
    var dark := Icons.texture(true, true).get_image()
    _expect(classic.get_size() == Vector2i(1024, 1024) and astryx.get_size() == classic.get_size() and dark.get_size() == classic.get_size(), "All identities retain full resolution")
    var body := Vector2i(450, 300)
    var original := classic.get_pixelv(body)
    var neutral := astryx.get_pixelv(body)
    _expect(original.b - original.r > 0.2, "Classic keeps its original blue artwork")
    _expect(absf(neutral.r - neutral.g) < 0.025 and absf(neutral.g - neutral.b) < 0.025, "Astryx body matches the neutral UI palette")
    _expect(neutral.get_luminance() < 0.01 and dark.get_pixelv(body).get_luminance() > 0.99, "Light and dark whale bodies use black and white")
    _expect(dark.get_pixel(512, 60).get_luminance() < 0.01, "Dark has a black background")
    _expect(Icons.texture(false, true) == Icons.texture(false), "Classic keeps the blue icon in either theme")
    for pixel in [Vector2i.ZERO, Vector2i(28, 28), Vector2i(512, 512), Vector2i(1023, 1023)]:
        _expect(is_equal_approx(classic.get_pixelv(pixel).a, astryx.get_pixelv(pixel).a), "Platform packaging preserves the original tile alpha")
        _expect(is_equal_approx(classic.get_pixelv(pixel).a, dark.get_pixelv(pixel).a), "Dark preserves the same tile alpha")

    var host := Suite.TestHost.new()
    var controller := IconController.new()
    controller.name = "ShellInterface"
    controller.preference_path = OS.get_cache_dir().path_join("aether-icon-test-%d.cfg" % OS.get_process_id())
    host.add_child(controller)
    root.add_child(host)
    await process_frame
    await process_frame
    _expect(controller.enabled and controller.applied == ["astryx/light"], "A new installation applies Astryx once at startup")
    var brand: TextureRect = controller.view.find_child("AstryxAppIcon", true, false)
    _expect(brand != null and brand.texture == Icons.texture(true), "Sidebar consumes the selected identity")
    controller.set_enabled(false)
    _expect(not controller.enabled and controller.app_icon_texture() == Icons.texture(false), "Classic interface uses the original icon")
    _expect(controller.applied == ["astryx/light", "classic"], "Switching interface updates system identity")
    var saved := ConfigFile.new()
    saved.load(controller.preference_path)
    _expect(saved.get_value("shell", "interface") == "classic", "System icon changes only after persisting the same interface")
    controller.fail_save = true
    controller.set_enabled(true)
    _expect(not controller.enabled and controller.applied == ["astryx/light", "classic"], "Failed persistence preserves both current interface and system icon")
    controller.fail_save = false
    controller.set_enabled(true)
    controller.draft_theme = "dark"
    controller.view.rebuild()
    _expect(controller.app_icon_texture() == Icons.texture(true, true) and controller.applied == ["astryx/light", "classic", "astryx/light"], "Draft dark previews the icon without changing the launcher")
    _expect(controller.save_settings(), "Theme saves successfully")
    _expect(controller.applied == ["astryx/light", "classic", "astryx/light", "astryx/dark"], "Saving the dark theme changes the launcher once")
    saved.load(controller.preference_path)
    _expect(saved.get_value("shell", "theme") == "dark", "Theme is persisted before changing the system icon")
    controller.draft_theme = "light"
    controller.fail_save = true
    _expect(not controller.save_settings() and controller.theme_mode == "dark" and controller.applied.back() == "astryx/dark", "Failed theme save preserves the system identity")
    controller.fail_save = false
    controller.discard_settings()
    _expect(controller.app_icon_texture() == Icons.texture(true, true), "Cancel restores the saved dark icon")
    controller.save_settings()
    _expect(controller.applied.size() == 4, "Saving unchanged theme does not request another launcher update")
    var reloaded := IconController.new()
    reloaded.preference_path = controller.preference_path
    reloaded.load_preferences()
    _expect(reloaded.enabled and reloaded.app_icon_texture() == Icons.texture(true, true), "Restart restores the selected dark identity")
    reloaded.free()
    var preference_path: String = controller.preference_path
    host.queue_free()
    await process_frame
    DirAccess.remove_absolute(preference_path)
    print("APP_ICON_TEST failures=", failures)
    quit(1 if failures else 0)
