extends SceneTree
const Suite := preload("res://tests/astryx_shell_test.gd")
const Icons := preload("res://scripts/ui/app_icon.gd")

class IconController extends Suite.TestController:
    var applied: Array[bool] = []
    var fail_save := false
    func save_preferences(path: String = "") -> Error:
        return ERR_CANT_CREATE if fail_save else super.save_preferences(path)
    func _apply_app_icon() -> void:
        applied.append(enabled)

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
    _expect(classic.get_size() == Vector2i(1024, 1024) and astryx.get_size() == classic.get_size(), "Both identities retain full resolution")
    var body := Vector2i(450, 300)
    var original := classic.get_pixelv(body)
    var neutral := astryx.get_pixelv(body)
    _expect(original.b - original.r > 0.2, "Classic keeps its original blue artwork")
    _expect(absf(neutral.r - neutral.g) < 0.025 and absf(neutral.g - neutral.b) < 0.025, "Astryx body matches the neutral UI palette")
    for pixel in [Vector2i.ZERO, Vector2i(28, 28), Vector2i(512, 512), Vector2i(1023, 1023)]:
        _expect(is_equal_approx(classic.get_pixelv(pixel).a, astryx.get_pixelv(pixel).a), "Platform packaging preserves the original tile alpha")

    var host := Suite.TestHost.new()
    var controller := IconController.new()
    controller.name = "ShellInterface"
    controller.preference_path = OS.get_cache_dir().path_join("aether-icon-test-%d.cfg" % OS.get_process_id())
    host.add_child(controller)
    root.add_child(host)
    await process_frame
    await process_frame
    _expect(controller.enabled and controller.applied == [true], "A new installation applies Astryx once at startup")
    var brand: TextureRect = controller.view.find_child("AstryxAppIcon", true, false)
    _expect(brand != null and brand.texture == Icons.texture(true), "Sidebar consumes the selected identity")
    controller.set_enabled(false)
    _expect(not controller.enabled and controller.app_icon_texture() == Icons.texture(false), "Classic interface uses the original icon")
    _expect(controller.applied == [true, false], "Switching interface updates system identity")
    var saved := ConfigFile.new()
    saved.load(controller.preference_path)
    _expect(saved.get_value("shell", "interface") == "classic", "System icon changes only after persisting the same interface")
    controller.fail_save = true
    controller.set_enabled(true)
    _expect(not controller.enabled and controller.applied == [true, false], "Failed persistence preserves both current interface and system icon")
    controller.fail_save = false
    controller.set_enabled(true)
    controller.theme_mode = "dark"
    controller.view.rebuild()
    _expect(controller.app_icon_texture() == Icons.texture(true) and controller.applied == [true, false, true], "Light/dark changes do not churn launcher icons")
    var reloaded := IconController.new()
    reloaded.preference_path = controller.preference_path
    reloaded.load_preferences()
    _expect(reloaded.enabled and reloaded.app_icon_texture() == Icons.texture(true), "Restart restores the selected identity")
    reloaded.free()
    var preference_path: String = controller.preference_path
    host.queue_free()
    await process_frame
    DirAccess.remove_absolute(preference_path)
    print("APP_ICON_TEST failures=", failures)
    quit(1 if failures else 0)
