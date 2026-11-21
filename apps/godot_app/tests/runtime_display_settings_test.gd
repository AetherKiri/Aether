extends SceneTree

const DisplaySettings = preload("res://scripts/runtime_display_settings.gd")
var _requests: Array[String] = []
var _failed := false

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        _failed = true
        push_error(message)

func _request(key: String, arg: String) -> void:
    _check(key == "runtime_aspect_mode", "Expected the runtime viewport aspect request")
    _requests.append(arg)

func _run() -> void:
    var path := "user://test_runtime_display_%s.cfg" % Time.get_ticks_usec()
    var view = DisplaySettings.new()
    view.config_path = path
    root.gui_embed_subwindows = true
    var window := Window.new()
    window.size = Vector2i(1000, 700)
    root.add_child(window)
    window.show()
    var container := Node.new()
    window.add_child(container)
    var saved_resizable := not window.unresizable
    view.begin_game(window, "game-a", true, _request)
    view.open(container, Vector2i(1280, 720), "zh_hans", 1)
    var first: ConfirmationDialog = view.dialog
    _check(first.title == "窗口显示设置", "Expected localized title")
    _check(first.exclusive and first.transient, "Modal controls must take ownership of input")
    var selector: OptionButton = first.find_child("Screen", true, false)
    _check(selector.item_count > 0, "Expected a desktop screen selector")
    var width: SpinBox = first.find_child("Width", true, false)
    var height: SpinBox = first.find_child("Height", true, false)
    width.value = 800
    height.value = 450
    var locked: CheckBox = first.find_child("WindowRatio", true, false)
    locked.button_pressed = true
    var resizable: CheckBox = first.find_child("Resizable", true, false)
    resizable.button_pressed = false
    var aspect: OptionButton = first.find_child("Aspect", true, false)
    aspect.select(3)
    view.open(container, Vector2i(1280, 720))
    _check(view.dialog == first, "A second request must focus the existing dialog")
    first.confirmed.emit()
    _check(view.dialog == null and window.unresizable and _requests == ["cover"], "Apply must update window and viewport")
    _check(view._constrain(Vector2i(800, 1), true, Vector2i(1920, 1080)) == Vector2i(800, 450), "Native aspect ratio must survive a resize")
    view.end_game()
    _check(not window.unresizable == saved_resizable, "Leaving the game restores library resize behavior")
    view.begin_game(window, "game-a", true, _request)
    _check(_requests == ["cover", "cover"], "Reopening a game restores its own display preferences")
    view.end_game()
    view.begin_game(window, "game-b", false, _request)
    view.open(container, Vector2i(1280, 720), "en", 1)
    _check(view.dialog.find_child("Screen", true, false) == null, "Touch platforms only present supported controls")
    view.dialog.canceled.emit()
    _check(view.dialog == null and _requests.size() == 2, "Cancel or a different game must preserve the current layout")
    view.end_game()
    window.queue_free()
    await process_frame
    DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
    print("runtime display settings self-test ", "failed" if _failed else "passed")
    quit(1 if _failed else 0)
