extends RefCounted

const CONFIG_PATH := "user://aether_runtime_display.cfg"
const ASPECT := ["stretch", "contain", "native", "cover"]
const LABELS := {
    "en": ["Display settings", "Display", "Window size", "Allow window resizing", "Keep window proportions", "Game image", "Stretch", "Fit", "Original size", "Fill and crop", "Apply", "Cancel"],
    "zh_hans": ["窗口显示设置", "显示器", "窗口大小", "允许调整窗口大小", "锁定窗口宽高比", "游戏画面", "拉伸", "保持比例", "原始大小", "填满并裁剪", "应用", "取消"],
    "zh_hant": ["視窗顯示設定", "顯示器", "視窗大小", "允許調整視窗大小", "鎖定視窗比例", "遊戲畫面", "拉伸", "保持比例", "原始大小", "填滿並裁切", "套用", "取消"],
    "ja": ["ウィンドウ表示設定", "モニター", "ウィンドウサイズ", "ウィンドウサイズの変更を許可", "ウィンドウの縦横比を固定", "ゲーム画面", "引き伸ばす", "縦横比を保持", "原寸大", "画面全体に表示", "適用", "キャンセル"],
    "ko": ["화면 설정", "모니터", "창 크기", "창 크기 조절 허용", "창 비율 고정", "게임 화면", "늘이기", "비율 유지", "원본 크기", "채우고 자르기", "적용", "취소"],
    "es": ["Configuración de pantalla", "Monitor", "Tamaño de la ventana", "Permitir cambiar el tamaño", "Fijar proporciones de la ventana", "Imagen del juego", "Estirar", "Ajustar", "Tamaño original", "Rellenar y recortar", "Aplicar", "Cancelar"],
}

var config_path := CONFIG_PATH
var dialog: ConfirmationDialog
var _window: Window
var _desktop := false
var _section := ""
var _on_request: Callable
var _preferences: Dictionary = {}
var _before: Dictionary = {}
var _changed_window := false
var _correcting := false
var _aspect_ratio := 0.0
var _last_size := Vector2i.ZERO

func begin_game(window: Window, game_key: String, desktop: bool, on_request: Callable) -> void:
    if window == null or game_key.is_empty():
        return
    if _window == window and _section == game_key.sha256_text():
        return
    end_game()
    _window = window
    _desktop = desktop
    _section = game_key.sha256_text()
    _on_request = on_request
    _before = {"screen": window.current_screen, "size": window.size, "position": window.position,
        "resizable": not window.unresizable, "mode": window.mode}
    var cfg := ConfigFile.new()
    if cfg.load(config_path) == OK:
        var saved = cfg.get_value(_section, "settings", {})
        if saved is Dictionary and not saved.is_empty():
            _apply(saved)
    if desktop:
        _window.size_changed.connect(_on_resize)

func end_game() -> void:
    _close()
    if is_instance_valid(_window):
        if _window.size_changed.is_connected(_on_resize):
            _window.size_changed.disconnect(_on_resize)
        if _changed_window and not _before.is_empty():
            _window.unresizable = not bool(_before.resizable)
            _window.current_screen = clampi(int(_before.screen), 0, maxi(0, DisplayServer.get_screen_count() - 1))
            # The runtime restores its original fullscreen mode separately.
            if _window.mode == Window.MODE_WINDOWED:
                _window.size = _before.size
                _window.position = _before.position
            if int(_before.mode) == Window.MODE_MAXIMIZED and _window.mode == Window.MODE_WINDOWED:
                _window.mode = Window.MODE_MAXIMIZED
    _window = null
    _before.clear()
    _preferences.clear()
    _changed_window = false
    _section = ""
    _aspect_ratio = 0.0
    _on_request = Callable()

func open(parent: Node, game_size: Vector2i, language: String = "en", current_aspect: int = -1) -> void:
    if not is_instance_valid(_window) or not is_instance_valid(parent):
        return
    if is_instance_valid(dialog):
        dialog.grab_focus()
        return
    var code := language.to_lower().replace("-", "_")
    if code.begins_with("zh") and not LABELS.has(code):
        code = "zh_hant" if "tw" in code or "hk" in code else "zh_hans"
    var labels: Array = LABELS.get(code, LABELS.get(code.get_slice("_", 0), LABELS.en))
    dialog = ConfirmationDialog.new()
    dialog.name = "RuntimeDisplaySettings"
    dialog.title = labels[0]
    dialog.dialog_text = ""
    dialog.exclusive = true
    dialog.transient = true
    dialog.get_ok_button().text = labels[10]
    dialog.get_cancel_button().text = labels[11]
    var rows := VBoxContainer.new()
    rows.add_theme_constant_override("separation", 10)
    dialog.add_child(rows)
    var screen: OptionButton
    var width: SpinBox
    var height: SpinBox
    var resizable: CheckBox
    var ratio: CheckBox
    if _desktop:
        screen = OptionButton.new()
        width = SpinBox.new()
        height = SpinBox.new()
        resizable = CheckBox.new()
        ratio = CheckBox.new()
        screen.name = "Screen"
        for index in range(maxi(1, DisplayServer.get_screen_count())):
            var size := DisplayServer.screen_get_size(index)
            screen.add_item("%s %d  (%d × %d)" % [labels[1], index + 1, size.x, size.y], index)
        screen.select(clampi(_window.current_screen, 0, screen.item_count - 1))
        _add_row(rows, labels[1], screen)
        var dimensions := HBoxContainer.new()
        width.name = "Width"
        height.name = "Height"
        for spin in [width, height]:
            spin.min_value = 1
            spin.max_value = 16384
            spin.step = 1
            spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
            spin.update_on_text_changed = true
        width.value = _window.size.x
        height.value = _window.size.y
        dimensions.add_child(width)
        var times := Label.new()
        times.text = "×"
        dimensions.add_child(times)
        dimensions.add_child(height)
        _add_row(rows, labels[2], dimensions)
        resizable.name = "Resizable"
        resizable.text = labels[3]
        resizable.button_pressed = not _window.unresizable
        rows.add_child(resizable)
        ratio.name = "WindowRatio"
        ratio.text = labels[4]
        ratio.button_pressed = _preferences.get("lock", false)
        rows.add_child(ratio)
    var aspect := OptionButton.new()
    aspect.name = "Aspect"
    for i in range(ASPECT.size()):
        aspect.add_item(labels[6 + i], i)
    var index := current_aspect if current_aspect >= 0 else int(_preferences.get("aspect", 1))
    aspect.select(clampi(index, 0, ASPECT.size() - 1))
    _add_row(rows, labels[5], aspect)
    dialog.confirmed.connect(func() -> void:
        var settings := {"aspect": aspect.selected}
        if _desktop:
            settings.merge({"screen": screen.selected, "size": Vector2i(roundi(width.value), roundi(height.value)),
                "resizable": resizable.button_pressed, "lock": ratio.button_pressed,
                "ratio": float(game_size.x) / game_size.y if game_size.x > 0 and game_size.y > 0 else float(width.value) / maxf(1, height.value)})
        _apply(settings)
        var cfg := ConfigFile.new()
        cfg.load(config_path)
        cfg.set_value(_section, "settings", _preferences)
        var error := cfg.save(config_path)
        if error != OK:
            push_warning("Could not save display settings: %s" % error_string(error))
        _close()
    )
    dialog.canceled.connect(_close)
    parent.add_child(dialog)
    if not _desktop:
        dialog.popup_centered_clamped(Vector2i(390, 180), 0.9)
    else:
        dialog.popup_centered_clamped(Vector2i(460, 310), 0.9)
    aspect.grab_focus()

func _add_row(parent: VBoxContainer, label_text: String, field: Control) -> void:
    var row := HBoxContainer.new()
    var label := Label.new()
    label.text = label_text
    label.custom_minimum_size.x = 100
    row.add_child(label)
    field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    row.add_child(field)
    parent.add_child(row)

func _apply(values: Dictionary) -> void:
    var index := clampi(int(values.get("aspect", 1)), 0, ASPECT.size() - 1)
    _preferences = {"aspect": index}
    if _on_request.is_valid():
        _on_request.call("runtime_aspect_mode", ASPECT[index])
    if not _desktop or not values.has("size") or not values["size"] is Vector2i:
        return
    var screens := DisplayServer.get_screen_count()
    var screen := clampi(int(values.get("screen", _window.current_screen)), 0, maxi(0, screens - 1))
    var usable := DisplayServer.screen_get_usable_rect(screen) if screens > 0 else Rect2i()
    if not usable.has_area():
        usable = Rect2i(_window.position, _window.size.max(Vector2i(1280, 720)))
    var visible := usable.size.max(Vector2i(1, 1))
    var resolution: Vector2i = values["size"].clamp(Vector2i.ONE, visible)
    _aspect_ratio = clampf(float(values.get("ratio", 0.0)), 0.25, 8.0) if bool(values.get("lock", false)) else 0.0
    if _aspect_ratio > 0:
        resolution = _constrain(resolution, true, visible)
    var resizable := bool(values.get("resizable", true))
    _preferences.merge({"screen": screen, "size": resolution, "resizable": resizable, "lock": _aspect_ratio > 0, "ratio": _aspect_ratio})
    _changed_window = true
    _correcting = true
    var switch_screen := _window.current_screen != screen
    _window.unresizable = not resizable
    if switch_screen:
        _window.current_screen = screen
    if _window.mode == Window.MODE_MAXIMIZED:
        _window.mode = Window.MODE_WINDOWED
    if _window.mode == Window.MODE_WINDOWED:
        _window.size = resolution
        if switch_screen or not usable.encloses(Rect2i(_window.position, _window.size)):
            _window.position = usable.position + (visible - resolution) / 2
    _last_size = _window.size
    _correcting = false

func _constrain(size: Vector2i, use_width: bool, limit: Vector2i) -> Vector2i:
    var width := clampi(size.x, 1, limit.x) if use_width else clampi(roundi(size.y * _aspect_ratio), 1, limit.x)
    var height := roundi(width / _aspect_ratio)
    if height > limit.y:
        height = limit.y
        width = mini(limit.x, roundi(height * _aspect_ratio))
    return Vector2i(maxi(width, 1), maxi(1, height))

func _on_resize() -> void:
    if _correcting or _aspect_ratio <= 0 or _window.mode != Window.MODE_WINDOWED or _window.size == _last_size:
        return
    var delta := (_window.size - _last_size).abs()
    var limit := DisplayServer.screen_get_usable_rect(_window.current_screen).size.max(Vector2i.ONE)
    var next := _constrain(_window.size, delta.x >= delta.y * _aspect_ratio, limit)
    _correcting = true
    if next != _window.size:
        _window.size = next
    _last_size = _window.size
    _correcting = false

func _close() -> void:
    if is_instance_valid(dialog):
        dialog.hide()
        dialog.queue_free()
    dialog = null
    if is_instance_valid(_window) and _window.visible:
        _window.grab_focus()
