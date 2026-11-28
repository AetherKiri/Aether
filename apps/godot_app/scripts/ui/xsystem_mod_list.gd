extends VBoxContainer

const Tools := preload("res://scripts/xsystem_tools.gd")
var host
var game_root := ""
var service
var _status := ""

func setup(owner_host, root_path: String) -> void:
    host = owner_host
    game_root = root_path
    service = host._xsystem_tools()
    name = "XSystemModManager"
    add_theme_constant_override("separation", 12)
    service.changed.connect(_changed)
    _rebuild()
    service.request(game_root)

func _text(zh: String, en: String) -> String:
    return Tools.text(host, zh, en)

func _label(value: String, small := false) -> Label:
    var label := Label.new()
    label.text = value
    label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    label.add_theme_font_size_override("font_size", 14 if small else 16)
    return label

func _button(value: String, action: Callable) -> Button:
    var button := Button.new()
    button.text = value
    button.custom_minimum_size.y = 44
    button.pressed.connect(action)
    button.disabled = service.busy or host.game_running
    return button

func _changed(_root: String) -> void:
    _rebuild()

func _rebuild() -> void:
    for child in get_children():
        remove_child(child)
        child.queue_free()
    add_child(_label(_text("MOD 管理", "MOD manager")))
    add_child(_label(_text("选择文件、压缩包或文件夹即可安装。后安装的 MOD 优先；移除后恢复原有文件。", "Install a file, archive or folder. Later MODs take priority; removing one restores the previous files."), true))
    var result: Dictionary = service.results.get(game_root, {})
    var mods: Array = result.get("mods", [])
    for mod in mods:
        var row := HBoxContainer.new()
        row.add_theme_constant_override("separation", 12)
        add_child(row)
        var caption := _label(String(mod.get("name", "MOD")))
        caption.tooltip_text = String(mod.get("source", ""))
        row.add_child(caption)
        var remove := _button(_text("移除", "Remove"), func(): service.request(game_root, "uninstall", String(mod.id)))
        remove.name = "Remove_" + String(mod.id)
        remove.accessibility_name = _text("卸载 ", "Uninstall ") + caption.text
        row.add_child(remove)
    if mods.is_empty() and not service.busy and bool(result.get("ok", true)):
        add_child(_label(_text("尚未安装 MOD", "No MODs installed"), true))
    var pickers := HFlowContainer.new()
    pickers.add_theme_constant_override("h_separation", 12)
    pickers.add_theme_constant_override("v_separation", 8)
    add_child(pickers)
    var file := _button(_text("选择文件", "Choose file"), _pick.bind(false))
    file.name = "ChooseModFile"
    pickers.add_child(file)
    var folder := _button(_text("选择文件夹", "Choose folder"), _pick.bind(true))
    folder.name = "ChooseModFolder"
    pickers.add_child(folder)
    if service.busy:
        add_child(_label(_text("正在处理 MOD，请稍候…", "Processing MODs…"), true))
    elif not bool(result.get("ok", true)):
        add_child(_label(Tools.error_text(host, String(result.get("error", ""))), true))

func _pick(folder: bool) -> void:
    if service.busy or host.game_running or not host._ensure_android_storage_permission_for_import():
        return
    var dialog: FileDialog = host._create_file_dialog(
        _text("选择 MOD 文件夹", "Choose MOD folder") if folder else _text("选择 MOD 文件或压缩包", "Choose MOD file or archive"),
        FileDialog.FILE_MODE_OPEN_DIR if folder else FileDialog.FILE_MODE_OPEN_FILE,
        PackedStringArray())
    var selected := func(path: String): service.request(game_root, "install", path)
    dialog.file_selected.connect(selected)
    dialog.dir_selected.connect(selected)
    host.add_child(dialog)
    dialog.popup_centered(Vector2i(900, 640))
