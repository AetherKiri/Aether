extends Panel
## The importer owns the operation. Progress updates keep the centered dialog and password editor mounted.
const SCROLL := preload("res://scripts/ui/astryx/astryx_scroll.gd")
const MAX_WIDTH := 480.0

var shell
var host
var importer: Node
var scrim: ColorRect
var inset: MarginContainer
var stack: VBoxContainer
var scroller: ScrollContainer
var body: VBoxContainer
var title: Label
var filename: Label
var file_info: Label
var plan_controls: VBoxContainer
var locations: OptionButton
var layouts: OptionButton
var conflicts: OptionButton
var layout_hint: Label
var replace_warning: Label
var destination_note: Label
var folder_error := ""
var folder_picker: FileDialog
var destination_group: VBoxContainer
var destination_caption: Label
var destination: Label
var password_group: VBoxContainer
var password: LineEdit
var message: Label
var progress_group: VBoxContainer
var progress_label: Label
var progress: ProgressBar
var close_button: Button
var cancel_button: Button
var primary: Button
var previous_focus: Control
var current_path := ""
var file_size := -1
var phase := ""
var cancelling := false
var closing := false
var released := false
var reveal := 1.0
var motion: Tween
var keyboard_height := 0

func open(view: Control, source: Node, path: String) -> void:
    shell = view
    host = shell.host
    importer = source
    previous_focus = shell.get_viewport().gui_get_focus_owner()
    name = "AstryxArchiveDialog"
    theme = shell.design.native
    mouse_filter = Control.MOUSE_FILTER_STOP
    var surface: StyleBoxFlat = shell.design.box("surface", 16, "border", 1)
    add_theme_stylebox_override("panel", surface)
    host._prepare_modal_layer()
    scrim = ColorRect.new()
    scrim.color = Color(0, 0, 0, 0.48)
    scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    host.modal_layer.add_child(scrim)
    host.modal_layer.add_child(self)
    host.active_modal_dialog = self
    host.active_modal_scrim = scrim
    shell.external_modal_id = get_instance_id()
    _build()
    scrim.gui_input.connect(_scrim_input)
    get_viewport().size_changed.connect(_layout)
    body.minimum_size_changed.connect(_layout.call_deferred)
    visibility_changed.connect(_visibility_changed)
    tree_exiting.connect(_release)
    importer.changed.connect(_sync)
    set_process(false)
    if String(importer.state.get("phase", "idle")) in ["inspecting", "extracting"]:
        _set_path(String(importer.state.path))
        _sync()
    else:
        _inspect(path)
    if not shell._reduced_motion():
        _set_reveal(0.0)
        _animate(1.0)
    _layout()

func select_archive(path: String) -> void:
    if path != current_path and phase not in ["inspecting", "extracting"] and not closing:
        _inspect(path)

func _inspect(path: String) -> void:
    _set_path(path)
    importer.inspect(path)
    _sync()

func _set_path(path: String) -> void:
    current_path = path
    file_size = -1
    for entry in importer.entries:
        if entry.get("path") == path:
            file_size = int(entry.get("size", -1))
            break
    password.clear()

func _build() -> void:
    inset = shell._margin(20, 18, 20, 20)
    add_child(inset)
    inset.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    stack = shell._vbox(16)
    inset.add_child(stack)
    var header: HBoxContainer = shell._hbox(12)
    stack.add_child(header)
    title = shell._label("", 22, false, true)
    title.accessibility_live = AccessibilityServer.LIVE_POLITE
    header.add_child(title)
    close_button = shell._media_action("close", shell._text("关闭", "Close", "閉じる", "關閉", "Cerrar"), _request_close, "ArchiveClose")
    header.add_child(close_button)

    scroller = SCROLL.new()
    scroller.name = "ArchiveBodyScroll"
    scroller.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    scroller.size_flags_vertical = Control.SIZE_EXPAND_FILL
    stack.add_child(scroller)
    body = shell._vbox(14)
    scroller.add_child(body)
    var file: HBoxContainer = shell._hbox(12)
    body.add_child(file)
    file.add_child(shell._icon("archive", 24))
    var copy: VBoxContainer = shell._vbox(2)
    file.add_child(copy)
    filename = shell._label("", 16, false, true)
    file_info = shell._label("", 14, true)
    copy.add_child(filename)
    copy.add_child(file_info)

    plan_controls = shell._vbox(6)
    body.add_child(plan_controls)
    plan_controls.add_child(shell._divider())
    locations = _selector("target", "ArchiveLocations", [], [], _location_selected)
    layouts = _selector("layout", "ArchiveLayout", [], [], importer.set_layout)
    conflicts = _selector("policy", "ArchiveConflict", importer.CONFLICTS, _labels(importer.CONFLICTS), importer.set_conflict)
    layout_hint = shell._label("", 13, true)
    plan_controls.add_child(layout_hint)
    replace_warning = shell._label(shell._t("archive.replace_warning"), 13, false, true)
    plan_controls.add_child(replace_warning)

    destination_group = shell._vbox(8)
    stack.add_child(destination_group)
    destination_group.add_child(shell._divider())
    destination_caption = shell._label("", 13, true)
    destination_group.add_child(destination_caption)
    var folder: HBoxContainer = shell._hbox(8)
    destination_group.add_child(folder)
    folder.add_child(shell._icon("folder", 18))
    destination = shell._label("", 15)
    destination.max_lines_visible = 2
    destination.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
    destination.name = "ArchiveDestination"
    folder.add_child(destination)
    destination_note = shell._label("", 13, true)
    destination_group.add_child(destination_note)

    password_group = shell._vbox(6)
    body.add_child(password_group)
    var password_label: String = shell._text("压缩包密码", "Archive password", "アーカイブのパスワード", "壓縮檔密碼", "Contraseña del archivo")
    password_group.add_child(shell._label(password_label, 14, false, true))
    password = LineEdit.new()
    password.name = "ArchivePassword"
    password.accessibility_name = password_label
    password.secret = true
    password.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_PASSWORD
    password.custom_minimum_size.y = 44
    password.add_theme_stylebox_override("focus", shell.design.box("", 10, "focus", 2))
    password_group.add_child(password)
    password.text_changed.connect(func(value: String): primary.disabled = value.is_empty())
    password.text_submitted.connect(func(_value: String): _act())

    message = shell._label("", 14, true)
    message.name = "ArchiveMessage"
    message.accessibility_live = AccessibilityServer.LIVE_POLITE
    body.add_child(message)
    progress_group = shell._vbox(6)
    body.add_child(progress_group)
    progress_label = shell._label("", 14, true)
    progress_group.add_child(progress_label)
    progress = ProgressBar.new()
    progress.name = "ArchiveProgress"
    progress.show_percentage = false
    progress.max_value = 1.0
    progress.step = 0.001
    progress.custom_minimum_size.y = 6
    progress.add_theme_stylebox_override("background", shell.design.box("subtle", 3))
    progress.add_theme_stylebox_override("fill", shell.design.box("accent", 3))
    progress_group.add_child(progress)

    var actions: HBoxContainer = shell._hbox(8)
    actions.alignment = BoxContainer.ALIGNMENT_END
    stack.add_child(actions)
    cancel_button = shell._button("", _request_close, "secondary", "ArchiveCancel")
    primary = shell._button("", _act, "primary", "ArchivePrimary")
    actions.add_child(cancel_button)
    actions.add_child(primary)

func _labels(values: Array) -> Array:
    var labels := []
    for value in values:
        labels.append(shell._t("archive." + str(value)))
    return labels

func _selector(key: String, id: String, values: Array, labels: Array, callback: Callable) -> OptionButton:
    var row: HBoxContainer = shell._hbox(12)
    plan_controls.add_child(row)
    var caption: Label = shell._label(shell._t("archive." + key), 14)
    caption.size_flags_horizontal = Control.SIZE_FILL
    caption.custom_minimum_size.x = 82
    row.add_child(caption)
    var select: OptionButton = shell._option(id, values, labels, "", callback)
    select.accessibility_name = caption.text
    row.add_child(select)
    return select

func _set_choices(select: OptionButton, values: Array, labels: Array, selected: String) -> void:
    # A progress/validation notification must not reset an open selector.
    var cached = select.get_meta("archive_choices", [])
    if cached != [values, labels]:
        select.clear()
        for index in values.size():
            select.add_item(str(labels[index]))
            select.set_item_metadata(index, values[index])
        select.set_meta("archive_choices", [values, labels])
    select.select(values.find(selected))

func _sync_plan(state: Dictionary) -> void:
    plan_controls.visible = phase in ["ready", "password"]
    var placement: Dictionary = state.get("placement", {})
    if plan_controls.visible:
        var modes: Array = importer.LAYOUTS.duplicate()
        if not placement.get("can_strip", false):
            modes.erase("strip")
        _set_choices(layouts, modes, _labels(modes), importer.layout)
        _set_choices(conflicts, importer.CONFLICTS, _labels(importer.CONFLICTS), importer.conflict)
        var base: String = importer.games_folder()
        var current: String = importer.destination_dir if not importer.destination_dir.is_empty() else base
        var choices: Dictionary = importer.location_options()
        _set_choices(locations, choices.keys(), choices.values(), current)
        locations.tooltip_text = current
        layout_hint.text = shell._t("archive." + importer.layout + "_help")
        replace_warning.visible = importer.conflict == "replace"
    var projected := phase in ["ready", "password"]
    destination_caption.text = shell._t("archive.preview") if projected else shell._t("archive.done").strip_edges()
    var output: String = importer.output_preview() if projected else String(state.get("destination", ""))
    destination.text = _display_destination(output)
    destination.tooltip_text = output
    destination.accessibility_description = output
    destination_group.visible = projected or phase == "done"
    var nested: bool = importer.layout == "smart" and placement.get("inner_archive", false)
    var creates_folder: bool = importer.layout == "folder" or (importer.layout == "smart" and not nested and not placement.is_empty() and (String(placement.get("single_file","")).is_empty() or placement.get("has_launcher", false)))
    destination_note.visible = projected and (nested or creates_folder)
    destination_note.text = shell._t("archive.nested" if nested else "archive.numbered")

func _location_selected(value: String) -> void:
    if value != "@choose":
        _choose_path(value)
        return
    locations.select(-1)
    _sync_plan(importer.state)
    if is_instance_valid(folder_picker):
        return
    folder_picker = importer.pick_folder(_choose_path)

func _choose_path(path: String) -> void:
    folder_error = ""
    if not importer.choose_destination(path):
        folder_error = shell._t("archive.unavailable")
    _sync()

func _caption(value: String) -> String:
    match value:
        "inspecting": return shell._text("正在检查压缩包", "Checking archive", "アーカイブを確認中", "正在檢查壓縮檔", "Comprobando archivo")
        "password": return shell._text("需要密码", "Password required", "パスワードが必要です", "需要密碼", "Se necesita contraseña")
        "extracting": return shell._text("正在解压", "Extracting", "展開中", "正在解壓", "Extrayendo")
        "done": return shell._text("解压完成", "Extraction complete", "展開完了", "解壓完成", "Extracción completada")
        "error": return shell._text("解压失败", "Extraction failed", "展開できませんでした", "解壓失敗", "Error de extracción")
        _: return shell._group_label("archive")

func _sync() -> void:
    if closing or released:
        return
    var state: Dictionary = importer.state
    var next := String(state.get("phase", "idle"))
    if next == "idle":
        _close_dialog()
        return
    if cancelling and next not in ["inspecting", "extracting"]:
        cancelling = false
        if next != "done":
            _request_close()
            return
    var changed_phase := phase != next
    phase = next
    if changed_phase:
        password.clear()
    title.text = _caption(phase)
    accessibility_name = title.text
    filename.text = String(state.get("name", ""))
    if filename.text.is_empty():
        filename.text = current_path.get_file()
    var metadata := PackedStringArray()
    var format_label := String(state.get("format", ""))
    if not format_label.is_empty():
        metadata.append(format_label)
    if file_size >= 0:
        metadata.append(String.humanize_size(file_size))
    file_info.text = " · ".join(metadata)
    file_info.visible = not metadata.is_empty()
    _sync_plan(state)
    message.text = folder_error if not folder_error.is_empty() else String(state.get("message", ""))
    message.visible = not message.text.is_empty()
    password_group.visible = phase == "password"
    set_process(OS.has_feature("mobile") and (password_group.visible or keyboard_height > 0))
    progress_group.visible = phase in ["inspecting", "extracting"]
    var fraction := float(state.get("progress", -1))
    progress.indeterminate = fraction < 0
    progress.value = clampf(fraction, 0, 1)
    progress.accessibility_name = title.text
    progress_label.visible = fraction >= 0
    progress_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    progress_label.text = "%d%%" % roundi(progress.value * 100)
    close_button.visible = phase != "extracting"
    cancel_button.visible = phase != "done"
    cancel_button.disabled = cancelling
    cancel_button.text = shell._text("取消解压", "Cancel extraction", "展開を中止", "取消解壓", "Cancelar extracción") if phase == "extracting" else shell._t("dialog.cancel")
    cancel_button.accessibility_name = cancel_button.text
    primary.visible = phase in ["ready", "password", "error", "done"]
    match phase:
        "error": primary.text = shell._text("重试", "Retry", "再試行", "重試", "Reintentar")
        "done": primary.text = shell._text("完成", "Done", "完了", "完成", "Listo")
        _:
            if phase == "password" and state.get("locked_catalog", false):
                primary.text = shell._t("archive.unlock")
            else:
                primary.text = shell._t("archive.confirm_replace") if importer.conflict == "replace" else _caption("ready")
    primary.accessibility_name = primary.text
    primary.disabled = phase == "password" and password.text.is_empty()
    if changed_phase:
        _update_focus()
    _layout()

func _display_destination(path: String) -> String:
    if path.is_empty():
        return ""
    var games := ProjectSettings.globalize_path("user://Games").simplify_path()
    var absolute := ProjectSettings.globalize_path(path).simplify_path()
    if absolute != games and not absolute.begins_with(games + "/"):
        return path
    var label: String = shell._text("游戏目录", "Games", "ゲームフォルダー", "遊戲目錄", "Juegos")
    return label if absolute == games else label + " / " + absolute.trim_prefix(games + "/")

func _update_focus() -> void:
    var enabled: Array[Control] = []
    for control: Control in [close_button, locations, layouts, conflicts, password, cancel_button, primary]:
        if control.is_visible_in_tree():
            enabled.append(control)
    for i in enabled.size():
        enabled[i].focus_previous = enabled[i].get_path_to(enabled[(i + enabled.size() - 1) % enabled.size()])
        enabled[i].focus_next = enabled[i].get_path_to(enabled[(i + 1) % enabled.size()])
    if phase == "password":
        password.grab_focus()
    elif phase in ["ready", "done", "error"]:
        primary.grab_focus(true)
    elif not cancel_button.disabled:
        cancel_button.grab_focus(true)

func _act() -> void:
    if closing or released:
        return
    match phase:
        "ready": importer.extract("")
        "password":
            if not password.text.is_empty():
                var value := password.text
                password.clear()
                primary.disabled = true
                importer.extract(value)
                if phase == "password":
                    password.grab_focus()
        "error": _inspect(current_path)
        "done": _request_close()

func _request_close() -> void:
    if closing or released or cancelling:
        return
    password.clear()
    if String(importer.state.get("phase", "idle")) in ["inspecting", "extracting"]:
        cancelling = true
        cancel_button.disabled = true
        importer.cancel()
    else:
        importer.dismiss()
        _close_dialog()

func _scrim_input(event: InputEvent) -> void:
    if phase in ["password", "extracting"]:
        return
    if event is InputEventScreenTouch or (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT):
        if not event.pressed and not event.is_canceled() and not get_global_rect().has_point(scrim.get_global_transform() * Vector2(event.position)):
            _request_close()

func _process(_delta: float) -> void:
    var current := DisplayServer.virtual_keyboard_get_height()
    if current != keyboard_height:
        keyboard_height = current
        _layout()
    if current <= 0 and phase != "password":
        set_process(false)

func _layout() -> void:
    if released or not is_inside_tree() or not is_instance_valid(primary):
        return
    var viewport_size := get_viewport_rect().size
    var safe: Rect2 = host._ui_safe_rect(viewport_size)
    var bottom := viewport_size.y
    if keyboard_height > 0:
        var screen := DisplayServer.window_get_current_screen()
        var keyboard_y := DisplayServer.screen_get_position(screen).y + DisplayServer.screen_get_size(screen).y - keyboard_height
        var local_y := keyboard_y - DisplayServer.window_get_position().y
        bottom = clampf(local_y * viewport_size.y / maxf(1.0, DisplayServer.window_get_size().y), safe.position.y, bottom)
    var gutter := 16.0
    var available_height := maxf(1.0, minf(safe.end.y, bottom) - safe.position.y)
    # Keep the preview with the confirmation except where the keyboard or a
    # short landscape window would leave no usable room for the form.
    var fixed_preview := keyboard_height == 0 and available_height >= 500
    if fixed_preview and destination_group.get_parent() != stack:
        destination_group.reparent(stack, false)
        stack.move_child(destination_group, primary.get_parent().get_index())
    elif not fixed_preview and destination_group.get_parent() != body:
        destination_group.reparent(body, false)
    var width := minf(MAX_WIDTH, maxf(1.0, safe.size.x - gutter * 2))
    var desired := inset.get_combined_minimum_size().y + body.get_combined_minimum_size().y
    size = Vector2(width, minf(desired, maxf(1.0, available_height - gutter * 2)))
    position = (Vector2(safe.get_center().x, safe.position.y + available_height * 0.5) - size * 0.5).round()
    pivot_offset = size * 0.5
    if keyboard_height > 0 and password.has_focus():
        scroller.ensure_control_visible.call_deferred(password)

func _set_reveal(value: float) -> void:
    reveal = value
    modulate.a = value
    scale = Vector2.ONE * lerpf(0.96, 1.0, value)
    scrim.color.a = value * 0.48

func _animate(target: float) -> void:
    if motion: motion.kill()
    if shell._reduced_motion():
        _set_reveal(target)
        return
    motion = create_tween()
    motion.tween_method(_set_reveal, reveal, target, shell.design.metric("page_seconds")).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

func _close_dialog() -> void:
    if closing or released:
        return
    closing = true
    password.clear()
    if shell._reduced_motion():
        _finish()
    else:
        _animate(0)
        motion.tween_callback(_finish)

func _finish() -> void:
    if host.active_modal_dialog != self:
        _release()
        return
    host.active_modal_dialog = null
    host.active_modal_scrim = null
    host.modal_layer.hide()
    _release()
    if is_instance_valid(previous_focus) and previous_focus.is_visible_in_tree():
        previous_focus.grab_focus(true)
    elif is_instance_valid(shell.search) and shell.search.is_visible_in_tree():
        shell.search.grab_focus(true)

func _visibility_changed() -> void:
    if not is_visible_in_tree():
        _release()

func _release() -> void:
    if released:
        return
    released = true
    set_process(false)
    password.clear()
    if is_instance_valid(folder_picker):
        folder_picker.queue_free()
    if is_instance_valid(importer):
        importer.changed.disconnect(_sync)
        # Back or another host modal can dismiss the surface directly.
        if not closing and is_instance_valid(shell) and shell.archive_dialog == self and String(importer.state.get("path", "")) == current_path:
            var current := String(importer.state.get("phase", "idle"))
            if current in ["inspecting", "extracting"]:
                if not cancelling: importer.cancel()
            elif current != "idle":
                importer.dismiss()
    if is_instance_valid(scrim):
        scrim.queue_free()
    queue_free()
