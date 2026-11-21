extends Control

const Layouts := preload("res://scripts/virtual_button_layout.gd")
const Canvas := preload("res://scripts/ui/astryx/virtual_button_canvas.gd")
const COPY := {
    "title": ["虚拟按钮", "Virtual buttons", "仮想ボタン", "虛擬按鈕", "Botones virtuales"],
    "layout": ["虚拟按钮布局", "Virtual button layout", "仮想ボタン配置", "虛擬按鈕佈局", "Diseño de botones virtuales"],
    "edit": ["编辑布局", "Edit layout", "配置を編集", "編輯佈局", "Editar diseño"],
    "global": ["全局布局", "Global layout", "全体の配置", "全域佈局", "Diseño global"],
    "inherit": ["跟随全局", "Use global layout", "全体設定を使用", "跟隨全域", "Usar diseño global"],
    "profile": ["布局方案", "Layout profile", "レイアウト", "佈局方案", "Perfil"],
    "new": ["新建方案", "New profile", "新規作成", "新增方案", "Crear perfil"],
    "name": ["方案名称", "Profile name", "レイアウト名", "方案名稱", "Nombre del perfil"],
    "number": ["方案 %d", "Layout %d", "レイアウト %d", "方案 %d", "Diseño %d"],
    "options": ["方案选项", "Options", "オプション", "方案選項", "Opciones"],
    "hide": ["收起", "Hide options", "閉じる", "收起", "Ocultar"],
    "reset": ["恢复默认布局", "Reset layout", "初期配置に戻す", "恢復預設佈局", "Restablecer diseño"],
    "remove": ["删除方案", "Delete profile", "レイアウトを削除", "刪除方案", "Eliminar perfil"],
    "add": ["新增按钮", "Add button", "ボタンを追加", "新增按鈕", "Añadir botón"],
    "delete": ["删除按钮", "Delete button", "ボタンを削除", "刪除按鈕", "Eliminar botón"],
    "binding": ["触发按键", "Binding", "割り当て", "觸發按鍵", "Asignación"],
    "fold": ["收起工具栏", "Hide toolbar", "ツールバーを閉じる", "收起工具列", "Ocultar barra"],
    "unfold": ["展开工具栏", "Show toolbar", "ツールバーを開く", "展開工具列", "Mostrar barra"],
    "opacity": ["按键不透明度", "Button opacity", "ボタンの不透明度", "按鍵不透明度", "Opacidad de botones"],
    "done": ["完成", "Done", "完了", "完成", "Listo"],
    "cancel": ["取消", "Cancel", "キャンセル", "取消", "Cancelar"],
    "pad": ["方向键", "Directional pad", "方向パッド", "方向鍵", "Cruceta"],
    "direction_mode": ["切换方向模式", "Switch direction mode", "方向モード切替", "切換方向模式", "Cambiar modo de dirección"],
    "mouse_left": ["鼠标左键", "Left mouse button", "左クリック", "滑鼠左鍵", "Botón izquierdo"],
    "mouse_right": ["鼠标右键", "Right mouse button", "右クリック", "滑鼠右鍵", "Botón derecho"],
    "wheel_up": ["向上滚动", "Scroll up", "上にスクロール", "向上捲動", "Desplazar arriba"],
    "wheel_down": ["向下滚动", "Scroll down", "下にスクロール", "向下捲動", "Desplazar abajo"],
    "error": ["无法保存布局", "Could not save layout", "配置を保存できません", "無法儲存佈局", "No se pudo guardar el diseño"],
    "read_error": ["无法读取布局", "Could not read layout", "配置を読み込めません", "無法讀取佈局", "No se pudo leer el diseño"],
}
var shell
var book: Dictionary
var globals: Dictionary
var initial: Dictionary
var game_root: String
var is_game := false
var selected := ""
var managing := false
var folded := false
var floating: PanelContainer
var toolbar: VBoxContainer
var unfold: Button
var identity: Label
var add_button: Button
var profile_bar: HBoxContainer
var options_box: VBoxContainer
var tools: HBoxContainer
var board: Canvas
var done: Button
var error_label: Label
var previous_orientation := -1


static func caption(view, key: String) -> String:
    return view.callv("_text", COPY[key]) if COPY.has(key) else key


func _word(key: String) -> String:
    return caption(shell, key)


func _current() -> Dictionary:
    return Layouts.effective(book, globals if is_game else {})


func _owned() -> Dictionary:
    return Layouts.profile_in(book, book.active)


func _button(title: String, callback: Callable, variant: String, id: String) -> Button:
    return shell._button(_word(title), callback, variant, "Pad" + id)


func _clear(row: Control) -> void:
    for child in row.get_children():
        row.remove_child(child)
        child.queue_free()


func open(view, game: Dictionary) -> void:
    shell = view
    var host = shell.host
    is_game = not game.is_empty()
    game_root = host._game_runtime_root(String(game.get("path", ""))) if is_game else ""
    var shared := Layouts.load_global(host._virtual_button_global_path())
    var local := Layouts.load_game(game_root) if is_game else shared
    if shared.error != OK or local.error != OK or (is_game and game_root.is_empty()):
        shell.show_notice(_word("read_error"))
        free()
        return
    globals = shared.book
    initial = local.book
    book = initial.duplicate(true)
    host._prepare_modal_layer()
    var bg := ColorRect.new()
    bg.color = Color("#14171c")
    host.modal_layer.add_child(bg)
    bg.size = host.get_viewport_rect().size
    resized.connect(func(): bg.size = host.get_viewport_rect().size)
    _backdrop(bg, game)
    name = "AstryxVirtualButtonEditor"
    theme = shell.design.native
    set_meta("aether_safe_dialog_kind", "fullscreen")
    host.modal_layer.add_child(self)
    host.active_modal_dialog = self
    host.active_modal_scrim = bg
    shell.external_modal_id = get_instance_id()
    previous_orientation = host._begin_virtual_button_orientation()
    visibility_changed.connect(
        func():
            if not is_visible_in_tree():
                _restore_orientation()
    )
    tree_exiting.connect(_restore_orientation)
    host._layout_safe_dialog(self, host._ui_safe_rect(host.get_viewport_rect().size))
    var artwork := Control.new()
    artwork.mouse_filter = Control.MOUSE_FILTER_IGNORE
    artwork.theme = host.theme
    artwork.z_index = 3
    add_child(artwork)
    artwork.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    board = Canvas.new()
    board.name = "PadCanvas"
    board.design = shell.design
    board.z_index = 5
    add_child(board)
    board.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    board.setup(artwork, host.ui_tokens, host.game_virtual_keyboard_opacity)
    board.mode_button.accessibility_name = _word("direction_mode")
    board.mode_button.tooltip_text = _word("direction_mode")
    board.picked.connect(_select)
    board.adjusted.connect(_adjust)
    board.direction_mode_changed.connect(_toggle_direction)

    floating = PanelContainer.new()
    floating.name = "PadFloatingTools"
    floating.z_index = 6
    floating.mouse_filter = Control.MOUSE_FILTER_STOP
    var style: StyleBoxFlat = shell.design.box("surface", 18, "border", 1, Vector2(6, 6))
    style.bg_color.a = 0.95
    style.shadow_color = Color(0, 0, 0, 0.22)
    style.shadow_size = 6
    floating.add_theme_stylebox_override("panel", style)
    add_child(floating)
    toolbar = shell._vbox(4)
    floating.add_child(toolbar)
    var header: HBoxContainer = shell._hbox(4)
    toolbar.add_child(header)
    header.add_child(_icon_action("cancel", "back", func(): host._dismiss_modal(), "Cancel"))
    var heading: VBoxContainer = shell._vbox(0)
    heading.custom_minimum_size.x = 84
    header.add_child(heading)
    identity = _clipped_label("", 15, true)
    heading.add_child(identity)
    heading.add_child(_clipped_label(host._game_display_title(game) if is_game else _word("global"), 12, false))
    header.add_child(
        _icon_action(
            "options",
            "settings",
            func():
                managing = not managing
                _refresh(),
            "Options"
        )
    )
    add_button = _button("add", _add, "secondary", "Add")
    header.add_child(add_button)
    done = _button("done", _save, "primary", "Done")
    header.add_child(done)
    header.add_child(_icon_action("fold", "chevron_up", _fold, "Fold"))
    unfold = _icon_action("unfold", "chevron_down", _fold, "Unfold")
    floating.add_child(unfold)
    unfold.hide()
    profile_bar = shell._hbox(6)
    toolbar.add_child(profile_bar)
    options_box = shell._vbox(4)
    toolbar.add_child(options_box)
    tools = shell._hbox(6)
    toolbar.add_child(tools)
    error_label = shell._label("", 13, true)
    error_label.hide()
    toolbar.add_child(error_label)
    resized.connect(_place_toolbar)
    floating.minimum_size_changed.connect(_place_toolbar.call_deferred)
    _refresh()


func _backdrop(bg: ColorRect, game: Dictionary) -> void:
    var gradient := Gradient.new()
    gradient.colors = PackedColorArray([Color("#12151a"), Color("#454b53")])
    var texture := GradientTexture2D.new()
    texture.gradient = gradient
    texture.fill_from = Vector2(0.3, 0)
    texture.fill_to = Vector2(0.7, 1)
    var base := TextureRect.new()
    base.texture = texture
    base.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    base.mouse_filter = Control.MOUSE_FILTER_IGNORE
    bg.add_child(base)
    base.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    if not game.is_empty():
        var cover: Texture2D = shell.host._load_cover_texture(game, Vector2i(1280, 720), 0)
        if cover != null:
            var picture := TextureRect.new()
            picture.texture = cover
            picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
            picture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
            picture.modulate.a = 0.55
            picture.mouse_filter = Control.MOUSE_FILTER_IGNORE
            bg.add_child(picture)
            picture.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    var grid := Control.new()
    grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
    bg.add_child(grid)
    grid.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    grid.draw.connect(
        func():
            for x in range(0, ceili(grid.size.x), 32):
                grid.draw_line(Vector2(x, 0), Vector2(x, grid.size.y), Color(1, 1, 1, 0.11 if x % 128 == 0 else 0.04))
            for y in range(0, ceili(grid.size.y), 32):
                grid.draw_line(Vector2(0, y), Vector2(grid.size.x, y), Color(1, 1, 1, 0.11 if y % 128 == 0 else 0.04))
    )


func _clipped_label(value: String, points: int, bold: bool) -> Label:
    var label: Label = shell._label(value, points, not bold, bold)
    label.autowrap_mode = TextServer.AUTOWRAP_OFF
    label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
    return label


func _icon_action(word: String, icon: String, callback: Callable, id: String) -> Button:
    var button := _button(word, callback, "quiet", id)
    button.tooltip_text = _word(word)
    button.text = ""
    button.custom_minimum_size = Vector2(44, 44)
    var center := CenterContainer.new()
    center.mouse_filter = Control.MOUSE_FILTER_IGNORE
    button.add_child(center)
    center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    center.add_child(shell._icon(icon, 18))
    return button


func _place_toolbar() -> void:
    if not is_instance_valid(floating) or floating.is_queued_for_deletion():
        return
    floating.reset_size()
    var x := size.x - floating.size.x - 8 if folded else (size.x - floating.size.x) * 0.5
    floating.position = Vector2(maxf(0, roundf(x)), 8)


func _fold() -> void:
    folded = not folded
    toolbar.visible = not folded
    unfold.visible = folded
    _place_toolbar.call_deferred()


func _toggle_direction() -> void:
    if selected != "pad":
        return
    var edited := _editable()
    if not edited.is_empty():
        edited.pad_mode = "wasd" if edited.pad_mode == "arrows" else "arrows"
        _refresh()


func _restore_orientation() -> void:
    if previous_orientation >= 0 and is_instance_valid(shell):
        shell.host._restore_virtual_button_orientation(previous_orientation)
        previous_orientation = -1


func _editable() -> Dictionary:
    var own := _owned()
    if not own.is_empty():
        return own
    return Layouts.copy_profile(book, _current(), is_game, _word("number"))


func _choose(id: String) -> void:
    book.active = id
    selected = ""
    board.contact = Canvas.IDLE
    _refresh()


func _new() -> void:
    if not Layouts.copy_profile(book, _current(), is_game, _word("number")).is_empty():
        selected = ""
        managing = true
        _refresh()


func _select(id: String) -> void:
    if selected == id and not managing:
        return
    selected = id
    if managing:
        managing = false
        _refresh()
    else:
        _tools()
        _redraw(false)


func _cap(profile: Dictionary) -> Dictionary:
    for cap in profile.buttons:
        if cap.id == selected:
            return cap
    return {}


func _adjust(id: String, patch: Dictionary) -> void:
    if id != selected:
        return
    var was_shared := _owned().is_empty()
    var p := _editable()
    if p.is_empty():
        return
    var cap := _cap(p)
    if cap.is_empty():
        return
    cap.merge(patch, true)
    if was_shared or patch.has("action"):
        _refresh()
    else:
        _redraw(false)


func _add() -> void:
    var p := _editable()
    if p.is_empty() or p.buttons.size() >= Layouts.MAX_BUTTONS:
        return
    managing = false
    selected = Layouts.new_id("b-")
    p.buttons.append({"id": selected, "action": "Space", "x": 0.5, "y": 0.5})
    _refresh()


func _remove_cap() -> void:
    var p := _editable()
    if selected != "pad" and not p.is_empty():
        p.buttons.erase(_cap(p))
        selected = ""
        _refresh()


func _refresh() -> void:
    identity.text = _current().name
    _profiles()
    _options()
    _tools()
    _redraw()
    done.disabled = not Layouts.valid_book(book, is_game)


func _redraw(rebind: bool = true) -> void:
    board.selected = selected
    board.profile = _current()
    board.refresh(rebind)


func _profiles() -> void:
    _clear(profile_bar)
    profile_bar.visible = managing
    if not managing:
        return
    var ids := ["mouse"]
    var labels := ["Mouse"]
    if is_game:
        ids.push_front("")
        labels.push_front(_word("inherit"))
        for p in globals.profiles:
            ids.append(p.id)
            labels.append("%s · %s" % [_word("global"), p.name])
    for p in book.profiles:
        ids.append(p.id)
        labels.append(p.name)
    var chosen: String = book.active if book.active in ids else ""
    var picker: OptionButton = shell._option("PadProfiles", ids, labels, chosen, _choose)
    picker.accessibility_name = _word("profile")
    profile_bar.add_child(picker)
    var add := _button("new", _new, "secondary", "New")
    add.disabled = book.profiles.size() >= Layouts.MAX_PROFILES
    profile_bar.add_child(add)


func _options() -> void:
    _clear(options_box)
    options_box.visible = managing
    if not managing:
        return
    var p := _current()
    var own := _owned()
    var names: HBoxContainer = shell._hbox(8)
    options_box.add_child(names)
    if not own.is_empty():
        var field := LineEdit.new()
        field.name = "PadProfileName"
        field.placeholder_text = _word("name")
        field.accessibility_name = _word("name")
        field.text = p.name
        field.max_length = 48
        field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        field.text_changed.connect(
            func(value: String):
                own.name = value
                identity.text = value
                var picker: OptionButton = profile_bar.get_node("PadProfiles")
                picker.set_item_text(picker.selected, value)
                done.disabled = not Layouts.valid_book(book, is_game)
        )
        names.add_child(field)
    names.add_child(
        _button(
            "reset",
            func():
                var edited := _editable()
                if not edited.is_empty():
                    edited.buttons = Layouts.mouse().buttons
                    edited.pad_mode = "wasd"
                    edited.erase("opacity")
                    selected = ""
                    _refresh(),
            "secondary",
            "Reset"
        )
    )
    if not own.is_empty():
        names.add_child(
            _button(
                "remove",
                func():
                    book.profiles.erase(own)
                    _choose("" if is_game else "mouse"),
                "quiet",
                "Remove"
            )
        )
    var opacity_row: HBoxContainer = shell._hbox(10)
    options_box.add_child(opacity_row)
    var label: Label = shell._label(_word("opacity"), 13, true)
    label.autowrap_mode = TextServer.AUTOWRAP_OFF
    label.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
    opacity_row.add_child(label)
    var slider := HSlider.new()
    slider.name = "PadOpacity"
    slider.min_value = 20
    slider.max_value = 100
    slider.step = 5
    slider.value = roundi(float(p.get("opacity", board.default_opacity)) * 100)
    slider.accessibility_name = _word("opacity")
    slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    slider.custom_minimum_size.y = 32
    opacity_row.add_child(slider)
    var percent: Label = shell._label("%d%%" % slider.value, 13)
    percent.custom_minimum_size.x = 42
    percent.size_flags_horizontal = Control.SIZE_SHRINK_END
    opacity_row.add_child(percent)
    slider.value_changed.connect(
        func(value):
            var was_shared := _owned().is_empty()
            var edited := _editable()
            if not edited.is_empty():
                edited.opacity = value / 100.0
                percent.text = "%d%%" % value
                if was_shared:
                    _profiles()
                _redraw()
    )
    slider.drag_ended.connect(func(_changed): _options.call_deferred())


func _tools() -> void:
    _clear(tools)
    var p := _current()
    add_button.disabled = (
        p.buttons.size() >= Layouts.MAX_BUTTONS or (_owned().is_empty() and book.profiles.size() >= Layouts.MAX_PROFILES)
    )
    var cap := _cap(p)
    tools.visible = not managing and not cap.is_empty() and cap.action != "pad"
    if tools.visible:
        var ids := Layouts.actions()
        var labels := ids.map(func(action): return _word(action))
        var picker: OptionButton = shell._option(
            "PadBinding", ids, labels, cap.action, func(action): _adjust(selected, {"action": action})
        )
        picker.accessibility_name = _word("binding")
        tools.add_child(picker)
        tools.add_child(_button("delete", _remove_cap, "quiet", "Delete"))


func _save() -> void:
    for p in book.profiles:
        p.name = p.name.strip_edges()
    var path: String = shell.host._virtual_button_global_path()
    var latest := Layouts.load_game(game_root) if is_game else Layouts.load_global(path)
    var error: Error = latest.error
    if error == OK and latest.book != initial:
        error = ERR_BUSY
    if error == OK and book != initial:
        error = Layouts.save_game(game_root, book) if is_game else Layouts.save_global(book, path)
    if error != OK:
        error_label.text = "%s (%s)" % [_word("error"), error_string(error)]
        error_label.show()
        return
    done.disabled = true
    shell.host._dismiss_modal(func(): shell.refresh_content(true))
