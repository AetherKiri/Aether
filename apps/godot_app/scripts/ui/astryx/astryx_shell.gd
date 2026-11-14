extends Control
## Native presenter for the React/Astryx reference. Runtime operations stay in the host.
const DESIGN := preload("res://scripts/ui/astryx/astryx_theme.gd")
const SWITCH := preload("res://scripts/ui/astryx/astryx_switch.gd")
const SCROLL := preload("res://scripts/ui/astryx/astryx_scroll.gd")
const SHADERS := preload("res://scripts/ui/aether_shaders.gd")
const COVER_PICKER := preload("res://scripts/ui/astryx/cover_picker.gd")
const BACKGROUND := preload("res://scripts/ui/astryx/astryx_background.gd")
const NAV := [
    ["library", "library", "nav.library"],
    ["videos", "video", "nav.videos"], ["flash", "flash", "nav.flash"],
    ["settings", "settings", "settings.title"],
]
const GROUPS := ["interface", "render", "compatibility", "diagnostics", "about"]
var controller
var host
var design
var phone := false
var sidebar_expanded := false
var sidebar_width := 48.0
var sidebar_tween: Tween
var sidebar_animating := false
var route := ""
var language := ""
var section := "interface"
var settings_narrow := false
var settings_detail := false
var editing_setting := ""
var detail_edit_key := ""
var detail_edit_path := ""
var detail_edit_draft: Dictionary = {}
var detail_edit_error := ""
var detail_edit_generation := 0
var detail_font_import: Dictionary = {}
var detail_preview_font: Font
var settings_footer: VBoxContainer
var query := ""
var recent_only := false
var page: VBoxContainer
var scroll: ScrollContainer
var content: VBoxContainer
var detail_backdrop: TextureRect
var save_button: Button
var cancel_button: Button
var save_status: Label
var search: LineEdit
var layout_pending := false
var last_size := Vector2.ZERO
var notice: PanelContainer
var notice_layer: MarginContainer
var notice_tween: Tween
var external_modal_id := 0
var expanded_details := {"information": true, "rendering": false, "cover": false}
var layout_root: Control
var library_content_key := ""
var cached_library: Dictionary = {}
var background_effect: Control

func setup(owner_node: Node) -> void:
    controller = owner_node
    host = controller.host
    design = DESIGN.new(controller.draft_theme)

func _ready() -> void:
    set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    mouse_filter = Control.MOUSE_FILTER_STOP
    resized.connect(_queue_layout)
    rebuild()

func _input(event: InputEvent) -> void:
    if not is_visible_in_tree() or not is_instance_valid(scroll) or host.modal_layer.visible:
        return
    var pointer := Vector2.ZERO
    var amount := 0.0
    var smooth := false
    if event is InputEventMouseButton:
        if not event.pressed or event.button_index not in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
            return
        pointer = event.position
        amount = maxf(1.0, absf(event.factor)) * 72.0
        if event.button_index == MOUSE_BUTTON_WHEEL_UP:
            amount = -amount
        smooth = not _reduced_motion()
    elif event is InputEventPanGesture:
        pointer = event.position
        amount = event.delta.y * host.SHELL_SCROLL_TOUCHPAD_SPEED
    else:
        return
    if not scroll.get_global_rect().has_point(pointer):
        return
    # Own this presenter's wheel/pan events before the hidden classic detail
    # view's global handler can consume them. Touch and thumb drags stay native.
    host._scroll_container_by(scroll, amount, smooth)
    get_viewport().set_input_as_handled()

func _queue_layout() -> void:
    if layout_pending or size.is_equal_approx(last_size):
        return
    layout_pending = true
    call_deferred("_finish_layout")

func _finish_layout() -> void:
    layout_pending = false
    # The host briefly resets full-window anchors before applying mobile safe
    # insets every frame. Rebuild only if the final size actually changed;
    # otherwise a held touch loses its Button before the release arrives.
    if is_inside_tree() and not size.is_equal_approx(last_size):
        rebuild(true)

func sync_state() -> void:
    if route != String(host.shell_route) or language != String(host.active_language):
        var changed_route := route != String(host.shell_route)
        if changed_route:
            _reset_detail_edit()
            query = ""
            if String(host.shell_route) == "settings":
                settings_detail = false
                editing_setting = ""
        rebuild(not changed_route)
    elif route != "settings":
        refresh_content(true)

func rebuild(preserve_scroll: bool = false) -> void:
    if not is_inside_tree() or size.x <= 0:
        return
    if route == "library" and String(host.shell_route) != "library" and is_instance_valid(scroll):
        _discard_library_cache()
        # Keep the page in the tree: reattaching hundreds of controls would
        # still repeat theme propagation and text layout on every tab switch.
        cached_library = {"key": library_content_key, "root": layout_root,
            "page": page, "scroll": scroll, "content": content, "search": search}
        layout_root.hide()
    var previous_scroll := scroll.scroll_vertical if preserve_scroll and is_instance_valid(scroll) else 0
    route = String(host.shell_route)
    if route != "detail":
        _reset_detail_edit()
    language = String(host.active_language)
    phone = size.x < 700
    if not sidebar_animating:
        sidebar_width = 260.0 if sidebar_expanded else 48.0
    last_size = size
    if design == null or design.mode != controller.draft_theme:
        design = DESIGN.new(controller.draft_theme)
    theme = design.native
    var default_font_size := 16 if phone else 14
    if theme.default_font_size != default_font_size:
        theme.default_font_size = default_font_size
    # One field survives page rebuilds and cached-library navigation. Detach it
    # before retiring the old page so hidden layouts cannot keep animating.
    if is_instance_valid(background_effect) and background_effect.get_parent() != null:
        background_effect.get_parent().remove_child(background_effect)
    _dismiss_notice()
    if is_instance_valid(layout_root) and layout_root != cached_library.get("root"):
        remove_child(layout_root)
        layout_root.queue_free()
    layout_root = null
    save_button = null
    cancel_button = null
    save_status = null
    settings_footer = null
    scroll = null
    content = null
    detail_backdrop = null
    search = null
    notice = null
    if route == "library" and not cached_library.is_empty():
        if cached_library.key == _library_key():
            layout_root = cached_library.root
            page = cached_library.page
            scroll = cached_library.scroll
            content = cached_library.content
            search = cached_library.search
            library_content_key = cached_library.key
            cached_library = {}
            move_child(layout_root, 0)
            layout_root.show()
            _attach_background(layout_root.find_child("AstryxPage", true, false))
            sync_dirty_state()
            return
        _discard_library_cache()
    layout_root = Control.new()
    layout_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    layout_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(layout_root)
    move_child(layout_root, 0)
    var fill := ColorRect.new()
    fill.color = design.color("surface" if phone else "canvas")
    fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
    fill.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    layout_root.add_child(fill)

    var outer := _margin(0, 0, 0, 0)
    outer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    layout_root.add_child(outer)
    var frame: BoxContainer = _vbox(0) if phone else _hbox(0)
    outer.add_child(frame)
    if not phone:
        frame.add_child(_navigation(false))
    var panel := PanelContainer.new()
    panel.name = "AstryxPage"
    panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
    panel.add_theme_stylebox_override("panel", design.box("surface", 0 if phone else 28))
    panel.clip_contents = true
    frame.add_child(panel)
    _attach_background(panel)
    page = _vbox(0)
    panel.add_child(page)
    match route:
        "settings": _build_settings()
        "detail": _build_detail()
        _: _build_library()
    if phone:
        frame.add_child(_navigation(true))
    if previous_scroll > 0:
        _restore_scroll.call_deferred(previous_scroll)
    sync_dirty_state()

func _attach_background(panel: Control) -> void:
    if not is_instance_valid(background_effect):
        background_effect = BACKGROUND.new()
        background_effect.name = "AstryxBackgroundEffect"
    panel.add_child(background_effect)
    panel.move_child(background_effect, 0)
    background_effect.configure(controller.draft_background_effects, design.color("text"), _reduced_motion())

func _discard_library_cache() -> void:
    var cached_root: Control = cached_library.get("root")
    if is_instance_valid(cached_root):
        remove_child(cached_root)
        cached_root.queue_free()
    cached_library = {}

func _library_key() -> String:
    return str([host.known_games.hash(), controller.library_revision, language,
        controller.draft_theme, controller.library_display, size, sidebar_width, query, recent_only])

func _restore_scroll(value: int) -> void:
    if is_instance_valid(scroll):
        scroll.scroll_vertical = value

func _clear(node: Node) -> void:
    for child in node.get_children():
        node.remove_child(child)
        child.queue_free()

func _vbox(gap: int = 0) -> VBoxContainer:
    var box := VBoxContainer.new()
    box.add_theme_constant_override("separation", gap)
    box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    return box

func _hbox(gap: int = 0) -> HBoxContainer:
    var box := HBoxContainer.new()
    box.add_theme_constant_override("separation", gap)
    box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    return box

func _margin(left: int, top: int, right: int, bottom: int) -> MarginContainer:
    var margin := MarginContainer.new()
    for pair in [["left", left], ["top", top], ["right", right], ["bottom", bottom]]:
        margin.add_theme_constant_override("margin_" + pair[0], pair[1])
    margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    return margin

func _label(value: String, point_size: int = 14, secondary: bool = false, weight: bool = false) -> Label:
    var label := Label.new()
    label.text = value
    label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    label.add_theme_font_size_override("font_size", point_size)
    label.add_theme_color_override("font_color", design.color("secondary" if secondary else "text"))
    label.add_theme_font_override("font", design.bold if weight else design.font)
    label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    return label

func _button(value: String, action: Callable, variant: String = "secondary", node_name: String = "") -> Button:
    var button := Button.new()
    button.text = value
    button.accessibility_name = value
    if not node_name.is_empty():
        button.name = node_name
    button.custom_minimum_size = Vector2(0, 44)
    # Let the surrounding ScrollContainer recognize a drag that starts on a
    # card or action, and cancel the pending click when scrolling begins.
    button.mouse_filter = Control.MOUSE_FILTER_PASS
    button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
    button.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
    button.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
    button.focus_mode = Control.FOCUS_ALL
    design.style_button(button, variant)
    if action.is_valid():
        button.pressed.connect(action)
    return button

func _icon(name_value: String, point_size: int = 22, ink: String = "text") -> TextureRect:
    var icon := TextureRect.new()
    icon.texture = load("res://assets/ui/astryx/%s.svg" % name_value)
    icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
    icon.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
    icon.custom_minimum_size = Vector2(point_size, point_size)
    icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
    icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    icon.modulate = design.color(ink)
    icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
    return icon

func _divider() -> ColorRect:
    var line := ColorRect.new()
    line.color = design.color("border")
    line.custom_minimum_size.y = 1
    line.mouse_filter = Control.MOUSE_FILTER_IGNORE
    return line

func _tab_button(value: String, action: Callable, selected: bool, node_name: String = "") -> Button:
    var button := _button(value, action, "quiet", node_name)
    var normal: StyleBoxFlat = design.box("", 0, "", 0, Vector2(8, 8))
    if selected:
        normal.border_width_bottom = 2
        normal.border_color = design.color("text")
    button.add_theme_stylebox_override("normal", normal)
    # Hover/pressed colors must not inherit the wider generic button padding.
    var hovered := normal.duplicate() as StyleBoxFlat
    hovered.bg_color = design.color("selected")
    button.add_theme_stylebox_override("hover", hovered)
    button.add_theme_stylebox_override("pressed", hovered)
    button.add_theme_font_override("font", design.bold if selected else design.font)
    button.add_theme_color_override("font_color", design.color("text" if selected else "secondary"))
    return button

func _navigation(bottom: bool) -> Control:
    var holder := PanelContainer.new()
    holder.name = "AstryxBottomNav" if bottom else "AstryxSideNav"
    var style: StyleBoxFlat = design.box("surface" if bottom else "canvas", 0)
    if bottom:
        style.border_width_top = 1
        style.border_color = design.color("border")
    else:
        holder.custom_minimum_size.x = sidebar_width
        holder.clip_contents = true
    holder.add_theme_stylebox_override("panel", style)
    var pad := _margin(8, 4 if bottom else 8, 8, 16 if bottom and OS.get_name() != "iOS" else 4)
    holder.add_child(pad)
    var items: BoxContainer = _hbox(4) if bottom else _vbox(4)
    pad.add_child(items)
    if not bottom:
        var toggle := _button("", _toggle_sidebar, "quiet", "AstryxToggleSidebar")
        toggle.custom_minimum_size.y = 48
        toggle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        # Pointer activation should not leave a selection ring on the app logo.
        # Keyboard users keep a neutral focus indicator after the rebuild.
        toggle.add_theme_stylebox_override("focus", design.box("", 10, "input_border", 1))
        toggle.gui_input.connect(func(event: InputEvent):
            if event is InputEventKey or event is InputEventJoypadButton:
                toggle.set_meta("keyboard_activation", true)
            elif event is InputEventMouseButton or event is InputEventScreenTouch:
                toggle.set_meta("keyboard_activation", false)
        )
        toggle.accessibility_name = _text("收起侧栏", "Collapse sidebar", "サイドバーを折りたたむ") if sidebar_expanded else _text("展开侧栏", "Expand sidebar", "サイドバーを展開")
        toggle.tooltip_text = toggle.accessibility_name
        items.add_child(toggle)
        var brand_row := _hbox(12)
        brand_row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
        brand_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
        toggle.add_child(brand_row)
        var brand := TextureRect.new()
        brand.name = "AstryxAppIcon"
        brand.texture = preload("res://assets/icon.png")
        brand.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
        brand.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
        brand.custom_minimum_size = Vector2(32, 32)
        brand.size_flags_vertical = Control.SIZE_SHRINK_CENTER
        brand.accessibility_name = "Aether"
        brand.mouse_filter = Control.MOUSE_FILTER_IGNORE
        brand_row.add_child(brand)
        if sidebar_expanded:
            var name_label := _label("Aether", 18, false, true)
            name_label.name = "AstryxSidebarTitle"
            name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
            name_label.autowrap_mode = TextServer.AUTOWRAP_OFF
            name_label.clip_text = true
            brand_row.add_child(name_label)
    for entry in NAV:
        var id: String = entry[0]
        var selected := route == id or (route == "detail" and id == "library")
        var label := _nav_label(id)
        var button: Button
        if bottom:
            button = _button("", func(): navigate(id), "quiet", "AstryxNav_" + id)
            button.icon = load("res://assets/ui/astryx/%s%s.svg" % [entry[1], "_selected" if selected else ""])
            button.expand_icon = true
            button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
            button.add_theme_constant_override("icon_max_width", 24)
            button.add_theme_color_override("icon_normal_color", design.color("text"))
            button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
            button.add_theme_stylebox_override("normal", design.box("", 10))
        else:
            button = _button("", func(): navigate(id), "quiet", "AstryxNav_" + id)
            button.custom_minimum_size = Vector2(32, 32)
            button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
            button.add_theme_stylebox_override("normal", design.box("subtle" if selected else "", 10))
            var icon := _icon(entry[1], 18, "text" if selected else "secondary")
            icon.position = Vector2(7, 7)
            button.add_child(icon)
            if sidebar_expanded:
                var caption := _label(label, 14, not selected, selected)
                caption.name = "AstryxNavLabel_" + id
                caption.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
                caption.offset_left = 40
                caption.offset_right = -8
                caption.autowrap_mode = TextServer.AUTOWRAP_OFF
                caption.clip_text = true
                caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
                button.add_child(caption)
        button.accessibility_name = label
        button.tooltip_text = label
        items.add_child(button)
    return holder

func _toggle_sidebar() -> void:
    var toggle: Button = layout_root.find_child("AstryxToggleSidebar", true, false)
    var keyboard_activation := toggle != null and bool(toggle.get_meta("keyboard_activation", false))
    if is_instance_valid(sidebar_tween):
        sidebar_tween.kill()
    sidebar_expanded = not sidebar_expanded
    var target := 260.0 if sidebar_expanded else 48.0
    sidebar_animating = not _reduced_motion()
    rebuild(true)
    if sidebar_animating:
        var rail: Control = layout_root.find_child("AstryxSideNav", true, false)
        sidebar_tween = create_tween()
        sidebar_tween.tween_method(func(value: float):
            sidebar_width = value
            if is_instance_valid(rail):
                rail.custom_minimum_size.x = value
        , sidebar_width, target, design.metric("page_seconds")).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
        sidebar_tween.tween_callback(func():
            sidebar_animating = false
            rebuild(true)
            if keyboard_activation:
                _focus_sidebar_toggle()
        )
    elif keyboard_activation:
        _focus_sidebar_toggle()

func _focus_sidebar_toggle() -> void:
    var toggle: Button = layout_root.find_child("AstryxToggleSidebar", true, false)
    if toggle != null:
        toggle.grab_focus()

func _nav_label(id: String) -> String:
    match id:
        "settings": return _t("settings.title")
        "videos": return _text("视频", "Videos", "動画")
        "flash": return "Flash"
        _: return _text("游戏库", "Games", "ゲーム")

func navigate(destination: String) -> void:
    match destination:
        "settings": host._show_settings()
        "videos": host._show_video_library()
        "flash": host._show_flash_library()
        # Tab changes reuse the loaded model. Imports, edits and explicit
        # refreshes keep using the host's normal library refresh lifecycle.
        _: host._show_library("game", false)
    controller.sync_state()

func handle_back() -> bool:
    if route == "settings" and settings_narrow and settings_detail:
        settings_detail = false
        editing_setting = ""
        rebuild()
        return true
    if route == "detail":
        navigate("library")
        return true
    return false

func _header(title: String, searchable: bool = false, action: Control = null) -> void:
    var pad := _margin(16, 16, 16, 16)
    page.add_child(pad)
    var stack := _vbox(16)
    pad.add_child(stack)
    var row := _hbox(20)
    stack.add_child(row)
    var heading := _label(title, 24, false, true)
    heading.custom_minimum_size.y = 32
    heading.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    row.add_child(heading)
    if searchable:
        search = LineEdit.new()
        search.name = "AstryxSearch"
        search.text = query
        search.placeholder_text = host._t("search.placeholder")
        if search.placeholder_text == "search.placeholder":
            search.placeholder_text = _text("搜索游戏…", "Search games…", "ゲームを検索…")
        search.accessibility_name = search.placeholder_text
        search.custom_minimum_size = Vector2(0 if phone else 260, 44)
        search.add_theme_stylebox_override("normal", design.box("", 10, "input_border", 1, Vector2(12, 10)))
        search.size_flags_horizontal = Control.SIZE_EXPAND_FILL if phone else Control.SIZE_SHRINK_END
        # LineEdit sizes right_icon from the texture's pixel dimensions. Use a
        # logical-size child so the high-DPI SVG cannot enlarge the input.
        var search_icon := _icon("search", 20, "secondary")
        search_icon.name = "AstryxSearchIcon"
        search_icon.set_anchors_and_offsets_preset(Control.PRESET_CENTER_RIGHT)
        search_icon.offset_left = -32
        search_icon.offset_right = -12
        search_icon.offset_top = -10
        search_icon.offset_bottom = 10
        search_icon.visible = query.is_empty()
        search.add_child(search_icon)
        search.add_theme_color_override("clear_button_color", design.color("secondary"))
        search.clear_button_enabled = true
        search.text_changed.connect(func(value: String):
            query = value
            search_icon.visible = value.is_empty()
            refresh_content()
        )
    if action != null:
        row.add_child(action)
    page.add_child(_divider())
    if searchable:
        var search_pad := _margin(20 if phone else 24, 20 if phone else 24, 20 if phone else 24, 0)
        page.add_child(search_pad)
        search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        search_pad.add_child(search)

func _scroll_into(parent: Control, gutter: int) -> void:
    scroll = SCROLL.new()
    scroll.name = "AstryxScroll"
    scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
    scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
    scroll.follow_focus = true
    parent.add_child(scroll)
    var pad := _margin(gutter, 20 if phone else 24, gutter, 32)
    scroll.add_child(pad)
    content = _vbox(24 if phone else 32)
    content.name = "AstryxContent"
    pad.add_child(content)

func refresh_content(preserve_scroll: bool = false) -> void:
    if not is_instance_valid(content):
        return
    var previous := scroll.scroll_vertical if preserve_scroll else 0
    _clear(content)
    match route:
        "settings": _settings_content()
        "detail": _detail_content()
        _: _library_content()
    _restore_scroll.call_deferred(previous)

func _text(zh: String, en: String, ja: String = "") -> String:
    return controller.text(zh, en, ja)

func _t(key: String) -> String:
    return String(host._t(key))

func _reduced_motion() -> bool:
    return bool(host.ui_motion.reduced_motion)

func _enter(control: Control) -> void:
    if _reduced_motion():
        return
    control.modulate.a = 0.5
    var tween := control.create_tween()
    tween.tween_property(control, "modulate:a", 1.0, design.metric("page_seconds")).set_ease(Tween.EASE_OUT)

func sync_dirty_state() -> void:
    if is_instance_valid(settings_footer):
        settings_footer.visible = controller.is_dirty()
    if is_instance_valid(save_button):
        save_button.disabled = not controller.is_dirty()
        cancel_button.disabled = save_button.disabled
        save_status.text = _text("有未保存的更改", "Unsaved changes", "未保存の変更") if controller.is_dirty() else _text("所有更改已保存", "All changes saved", "保存済み")

func sync_modal_style() -> void:
    if is_instance_valid(host.modal_layer) and host.modal_layer.visible:
        var dialog: Control = host.active_modal_dialog
        if is_instance_valid(dialog) and dialog.get_instance_id() != external_modal_id:
            external_modal_id = dialog.get_instance_id()
            style_external_modal(dialog)

func _dialog(title: String, body: String) -> VBoxContainer:
    host._prepare_modal_layer()
    var scrim := ColorRect.new()
    scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    scrim.color = Color(0, 0, 0, 0.4)
    host.modal_layer.add_child(scrim)
    var center := CenterContainer.new()
    center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    center.mouse_filter = Control.MOUSE_FILTER_IGNORE
    host.modal_layer.add_child(center)
    var dialog := PanelContainer.new()
    dialog.name = "AstryxDialog"
    dialog.theme = design.native
    dialog.custom_minimum_size.x = minf(460, size.x - 32)
    dialog.add_theme_stylebox_override("panel", design.box("surface", 24, "border", 1, Vector2(24, 24)))
    center.add_child(dialog)
    var stack := _vbox(20)
    dialog.add_child(stack)
    stack.add_child(_label(title, 22, false, true))
    if not body.is_empty():
        stack.add_child(_label(body, 14, true))
    host.active_modal_dialog = dialog
    host.active_modal_scrim = scrim
    external_modal_id = dialog.get_instance_id()
    _enter(dialog)
    return stack

func _dismiss_then(action: Callable) -> void:
    # Use the host's dismiss lifecycle so escape/back and runtime dialogs agree.
    host._dismiss_modal(func():
        action.call()
        if is_instance_valid(controller.view) and controller.enabled:
            controller.sync_state()
    )

func confirm_navigation(destination: Callable) -> void:
    var stack := _dialog(_text("保存更改？", "Save changes?", "変更を保存しますか？"), _text("你的设置尚未保存。离开前可以保存，也可以放弃这次修改。", "You have unsaved settings. Save or discard them before leaving.", "設定が保存されていません。保存するか、変更を破棄して移動できます。"))
    var actions: BoxContainer = _vbox(8) if phone else _hbox(8)
    stack.add_child(actions)
    actions.add_child(_button(_text("继续编辑", "Keep editing", "編集を続ける"), func(): host._dismiss_modal(), "quiet", "AstryxKeepEditing"))
    actions.add_child(_button(_text("放弃更改", "Discard", "破棄"), func():
        controller.discard_settings()
        _dismiss_then(destination)
    , "secondary", "AstryxDiscard"))
    var save := _button(_text("保存并离开", "Save and leave", "保存して移動"), func():
        if controller.save_settings():
            _dismiss_then(destination)
    , "primary", "AstryxSaveAndLeave")
    actions.add_child(save)
    save.grab_focus()

func show_notice(message: String) -> void:
    _dismiss_notice()
    # Match Astryx's bounded toast card. A wrapping Label has almost no
    # intrinsic width, so measuring it before layout collapses CJK into a column.
    var bottom_inset := 16
    var navigation := layout_root.find_child("AstryxBottomNav", true, false) as Control
    if is_instance_valid(navigation):
        bottom_inset += int(maxf(navigation.size.y, navigation.get_combined_minimum_size().y))
    notice_layer = _margin(16, 16, 16, bottom_inset)
    notice_layer.name = "AstryxNoticeLayer"
    notice_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
    notice_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    add_child(notice_layer)
    notice = PanelContainer.new()
    notice.name = "AstryxNotice"
    notice.custom_minimum_size.x = minf(400, size.x - 32)
    notice.size_flags_horizontal = Control.SIZE_SHRINK_END
    notice.size_flags_vertical = Control.SIZE_SHRINK_END
    var surface: StyleBoxFlat = design.box("toast_surface", 12, "", 0, Vector2(16, 8))
    surface.shadow_color = Color(0, 0, 0, 0.12)
    surface.shadow_size = 8
    surface.shadow_offset = Vector2(0, 4)
    notice.add_theme_stylebox_override("panel", surface)
    notice.mouse_filter = Control.MOUSE_FILTER_STOP
    notice_layer.add_child(notice)
    var row := _hbox(12)
    row.mouse_filter = Control.MOUSE_FILTER_PASS
    notice.add_child(row)
    var label := _label(message, 14)
    label.name = "AstryxNoticeMessage"
    label.add_theme_color_override("font_color", design.color("on_accent"))
    label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    row.add_child(label)
    var close := _button("", _dismiss_notice, "quiet", "AstryxDismissNotice")
    close.custom_minimum_size = Vector2(44, 44)
    close.accessibility_name = _text("关闭提示", "Dismiss notification", "通知を閉じる")
    close.tooltip_text = close.accessibility_name
    close.icon = load("res://assets/ui/astryx/close.svg")
    close.expand_icon = true
    close.add_theme_constant_override("icon_max_width", 16)
    close.add_theme_stylebox_override("normal", design.box("", 8))
    var hover: StyleBoxFlat = design.box("", 8)
    hover.bg_color = design.color("on_accent", 0.1)
    close.add_theme_stylebox_override("hover", hover)
    close.add_theme_stylebox_override("pressed", hover)
    close.add_theme_stylebox_override("focus", design.box("", 8, "on_accent", 1))
    for state in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_focus_color"]:
        close.add_theme_color_override(state, design.color("on_accent"))
    row.add_child(close)
    notice_tween = create_tween()
    notice_tween.tween_interval(5.0)
    notice_tween.tween_property(notice, "modulate:a", 0.0, 0.0 if _reduced_motion() else 0.125)
    notice_tween.tween_callback(_dismiss_notice)
    notice.mouse_entered.connect(_sync_notice_timer)
    notice.mouse_exited.connect(_sync_notice_timer.call_deferred)
    close.focus_entered.connect(_sync_notice_timer)
    close.focus_exited.connect(_sync_notice_timer.call_deferred)

func _sync_notice_timer() -> void:
    if not is_instance_valid(notice) or notice_tween == null:
        return
    var focus := get_viewport().gui_get_focus_owner()
    if notice.get_global_rect().has_point(get_global_mouse_position()) or (focus != null and notice.is_ancestor_of(focus)):
        notice_tween.pause()
    else:
        notice_tween.play()

func _dismiss_notice() -> void:
    if notice_tween != null:
        notice_tween.kill()
        notice_tween = null
    if is_instance_valid(notice_layer):
        remove_child(notice_layer)
        notice_layer.queue_free()
    notice_layer = null
    notice = null

func style_external_modal(control: Control) -> void:
    control.theme = design.native
    var badge_icon: TextureRect
    if control is PanelContainer and control.get_child_count() == 1:
        var center := control.get_child(0) as CenterContainer
        if center != null and center.get_child_count() == 1:
            badge_icon = center.get_child(0) as TextureRect
    if badge_icon != null:
        # Classic modal badges use an on-accent icon. Restyling their surface
        # without its tint made the icon disappear against the new light theme.
        if is_instance_valid(host.active_modal_dialog) and host.active_modal_dialog.find_child("DismissAnnouncement", true, false) != null:
            badge_icon.texture = preload("res://assets/icon.png")
            badge_icon.custom_minimum_size = Vector2(36, 36)
            badge_icon.modulate = Color.WHITE
            badge_icon.accessibility_name = "Aether"
            control.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
        else:
            control.add_theme_stylebox_override("panel", design.box("subtle", 12))
            badge_icon.modulate = design.color("secondary")
    elif control is PanelContainer:
        var old: StyleBox = control.get_theme_stylebox("panel")
        var style: StyleBoxFlat = design.box("surface", 24, "border", 1)
        for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
            style.set_content_margin(side, old.get_content_margin(side))
        control.add_theme_stylebox_override("panel", style)
    elif control is Label:
        var font_size: int = control.get_theme_font_size("font_size")
        control.add_theme_font_override("font", design.bold if font_size >= 20 else design.font)
        control.add_theme_color_override("font_color", design.color("text"))
    elif control is Button:
        design.style_button(control, "secondary")
    elif control is LineEdit:
        control.add_theme_color_override("font_color", design.color("text"))
        control.add_theme_stylebox_override("normal", design.box("surface", 10, "input_border", 1, Vector2(12, 10)))
        control.add_theme_stylebox_override("focus", design.focus_box(10))
    for child in control.get_children():
        if child is Control:
            style_external_modal(child)

func _group_label(id: String) -> String:
    match id:
        "interface": return _text("界面", "Interface", "外観")
        "render": return _text("画面", "Display", "画面")
        "compatibility": return _text("兼容性", "Compatibility", "互換性")
        "diagnostics": return _text("诊断", "Diagnostics", "診断")
        _: return _text("关于", "About", "情報")

func _build_settings() -> void:
    # Use the available page width, including changes to the global app rail.
    settings_narrow = size.x - (0.0 if phone else sidebar_width) <= 768.0
    if not settings_narrow:
        settings_detail = true
    var body := _hbox(0)
    body.size_flags_vertical = Control.SIZE_EXPAND_FILL
    page.add_child(body)
    if not settings_narrow or not settings_detail:
        var menu := SCROLL.new()
        menu.name = "AstryxSettingsMenu"
        menu.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
        menu.size_flags_vertical = Control.SIZE_EXPAND_FILL
        menu.size_flags_horizontal = Control.SIZE_EXPAND_FILL if settings_narrow else Control.SIZE_SHRINK_BEGIN
        if not settings_narrow:
            menu.custom_minimum_size.x = 256
        body.add_child(menu)
        var pad := _margin(20 if settings_narrow else 12, 24 if settings_narrow else 16, 20 if settings_narrow else 12, 16)
        menu.add_child(pad)
        var navigation := _vbox(16)
        pad.add_child(navigation)
        var heading_pad := _margin(16, 0, 16, 0)
        navigation.add_child(heading_pad)
        heading_pad.add_child(_label(_t("settings.title"), 24, false, true))
        var items := _vbox(8)
        navigation.add_child(items)
        for id in GROUPS:
            if id == "about":
                var separator := _margin(0, 8, 0, 8)
                items.add_child(separator)
                separator.add_child(_divider())
            var button := _settings_menu_item(_group_label(id), id, func():
                section = id
                settings_detail = true
                editing_setting = ""
                rebuild()
            , "AstryxSection_" + id, section == id and not settings_narrow)
            items.add_child(button)
        items.add_child(_settings_menu_item(_t("settings.community_open"), "community",
            host._open_community, "AstryxSettingsCommunity"))
        if host._apple_app_store_platform():
            items.add_child(_settings_menu_item(_t("settings.rate_app_open"), "star",
                host._open_app_store_review, "AstryxSettingsRateApp"))
        if settings_narrow:
            scroll = menu
            _settings_actions(page)
            return
        var separator := _divider()
        separator.custom_minimum_size = Vector2(1, 0)
        separator.size_flags_vertical = Control.SIZE_EXPAND_FILL
        body.add_child(separator)
    var detail := _vbox(0)
    detail.name = "AstryxSettingsDetail"
    detail.size_flags_vertical = Control.SIZE_EXPAND_FILL
    body.add_child(detail)
    _scroll_into(detail, 16)
    var content_pad := content.get_parent() as MarginContainer
    content_pad.add_theme_constant_override("margin_top", 16)
    content.add_theme_constant_override("separation", 16)
    _settings_content()
    _settings_actions(detail)

func _settings_menu_item(title: String, icon_name: String, action: Callable, node_name: String, selected: bool = false) -> Button:
    var button := _button("", action, "quiet", node_name)
    button.accessibility_name = title
    button.custom_minimum_size.y = 56
    button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    button.add_theme_stylebox_override("normal", design.box("selected" if selected else "", 10))
    button.add_theme_stylebox_override("hover", design.box("selected", 10))
    var inset := _margin(16, 12, 16, 12)
    inset.mouse_filter = Control.MOUSE_FILTER_IGNORE
    inset.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    button.add_child(inset)
    var row := _hbox(16)
    row.mouse_filter = Control.MOUSE_FILTER_IGNORE
    inset.add_child(row)
    row.add_child(_icon(icon_name, 24))
    var label := _label(title, 16)
    label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    row.add_child(label)
    if settings_narrow:
        row.add_child(_icon("chevron_right", 20, "secondary"))
    return button

func _settings_actions(parent: Control) -> void:
    settings_footer = _vbox(0)
    settings_footer.name = "AstryxSettingsFooter"
    parent.add_child(settings_footer)
    settings_footer.add_child(_divider())
    var footer := _margin(16, 16, 16, 16)
    settings_footer.add_child(footer)
    var actions := _hbox(12)
    footer.add_child(actions)
    save_status = _label("", 12, true)
    save_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    actions.add_child(save_status)
    cancel_button = _button(_t("dialog.cancel"), func():
        editing_setting = ""
        controller.discard_settings()
    , "secondary", "AstryxCancelSettings")
    actions.add_child(cancel_button)
    save_button = _button(_text("保存更改", "Save changes", "保存"), func():
        editing_setting = ""
        controller.save_settings()
    , "primary", "AstryxSaveSettings")
    actions.add_child(save_button)

func _settings_content() -> void:
    var heading := _hbox(8)
    heading.name = "AstryxSettingsHeading"
    content.add_child(heading)
    if settings_narrow:
        var back := _button("", handle_back, "quiet", "AstryxSettingsBack")
        back.accessibility_name = _text("返回设置", "Back to settings", "設定に戻る")
        back.custom_minimum_size = Vector2(44, 44)
        back.icon = load("res://assets/ui/astryx/back.svg")
        back.expand_icon = true
        back.add_theme_constant_override("icon_max_width", 20)
        for state in ["normal", "hover", "pressed"]:
            back.add_theme_stylebox_override(state, design.box("selected" if state != "normal" else "", 8, "", 0, Vector2(4, 4)))
        heading.add_child(back)
    var title := _label(_group_label(section), 24, false, true)
    title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    heading.add_child(title)
    match section:
        "interface": _interface_settings()
        "render": _render_settings()
        "compatibility": _compatibility_settings()
        "diagnostics": _diagnostic_settings()
        "about": _about_settings()

func _section(title: String, description: String) -> VBoxContainer:
    var section_box := _vbox(0)
    content.add_child(section_box)
    var pad := _margin(0, 16, 0, 16)
    section_box.add_child(pad)
    var copy := _vbox(4)
    pad.add_child(copy)
    copy.add_child(_label(title, 20, false, true))
    if not description.is_empty():
        copy.add_child(_label(description, 14, true))
    var fields := _vbox(0)
    section_box.add_child(fields)
    return fields

func _setting_link(value: String, action: Callable, node_name: String = "") -> Button:
    var button := _button(value, action, "quiet", node_name)
    _style_setting_link(button)
    return button

func _style_setting_link(button: Button) -> void:
    design.style_button(button, "quiet")
    button.add_theme_font_size_override("font_size", 16)
    button.add_theme_font_override("font", design.font)
    button.custom_minimum_size = Vector2(44, 44)
    button.alignment = HORIZONTAL_ALIGNMENT_RIGHT
    for state in ["normal", "hover", "pressed", "disabled"]:
        button.add_theme_stylebox_override(state, design.box("", 0))

func _field(parent: Control, title: String, control: Control, description: String = "") -> void:
    if route == "settings":
        _setting_field(parent, title, control, description)
        return
    var field := _vbox(8)
    parent.add_child(field)
    field.add_child(_label(title, 15 if phone else 14, false, true))
    control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    field.add_child(control)
    if not description.is_empty():
        field.add_child(_label(description, 12, true))

func _setting_field(parent: Control, title: String, control: Control, description: String = "") -> void:
    var pad := _margin(0, 16, 0, 16)
    parent.add_child(pad)
    var field := _vbox(16)
    pad.add_child(field)
    var key := String(control.name).trim_prefix("AstryxSetting_")
    var editable := control is OptionButton or control is HSlider or key == "theme"
    var header := _hbox(16)
    field.add_child(header)
    var copy := _vbox(0)
    header.add_child(copy)
    var label := _label(title, 16, false, true)
    label.name = "AstryxSettingLabel_" + key
    copy.add_child(label)
    var value := ""
    if control is OptionButton:
        value = control.get_item_text(control.selected)
    elif control is HSlider:
        value = "%d%%" % control.value
    elif key == "theme":
        value = controller.draft_theme.capitalize()
    if editable:
        var summary := _label(value, 14, true)
        summary.name = "AstryxSettingSummary_" + key
        summary.visible = editing_setting != key
        copy.add_child(summary)
        header.add_child(_setting_link(_text("收起", "Close", "閉じる") if editing_setting == key else _text("编辑", "Edit", "編集"), func():
            editing_setting = "" if editing_setting == key else key
            refresh_content(true)
        , "AstryxEdit_" + key))
    var editor := _vbox(8)
    editor.name = "AstryxSettingEditor_" + key
    editor.visible = not editable or editing_setting == key
    field.add_child(editor)
    control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    editor.add_child(control)
    if not description.is_empty():
        editor.add_child(_label(description, 14, true))
    parent.add_child(_divider())

func _value(key: String):
    if key == "background_effects":
        return controller.draft_background_effects
    var snapshot: Dictionary = host.settings_draft if not host.settings_draft.is_empty() else host._current_settings_snapshot()
    return snapshot.get(key)

func _set_value(key: String, value) -> void:
    if key == "background_effects":
        controller.draft_background_effects = bool(value)
        background_effect.configure(bool(value), design.color("text"), _reduced_motion())
        sync_dirty_state()
        return
    host._set_settings_draft_value(key, value)
    if key == "frame_enhancement_kind":
        host._set_settings_draft_value("frame_enhancement_enabled", value != "off")
    sync_dirty_state()
    if key in ["frame_enhancement_kind", "fps_limit_enabled"]:
        refresh_content.call_deferred(true)

func _select(key: String, options: Array, labels: Array = []) -> OptionButton:
    return _option("AstryxSetting_" + key, options, labels, _value(key), func(value): _set_value(key, value))

func _option(node_name: String, options: Array, labels: Array, current, changed: Callable) -> OptionButton:
    var select := OptionButton.new()
    select.mouse_filter = Control.MOUSE_FILTER_PASS
    select.action_mode = BaseButton.ACTION_MODE_BUTTON_RELEASE
    select.name = node_name
    select.custom_minimum_size = Vector2(0, 44)
    select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    select.fit_to_longest_item = false
    select.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
    select.clip_text = true
    select.add_theme_stylebox_override("normal", design.box("surface", 10, "input_border", 1, Vector2(12, 10)))
    select.add_theme_stylebox_override("hover", design.box("selected", 10, "input_border", 1, Vector2(12, 10)))
    select.add_theme_stylebox_override("pressed", design.box("selected", 10, "input_border", 1, Vector2(12, 10)))
    select.add_theme_stylebox_override("focus", design.focus_box(10))
    var selected := 0
    for index in range(options.size()):
        select.add_item(str(labels[index]) if index < labels.size() else str(options[index]))
        select.set_item_metadata(index, options[index])
        if options[index] == current:
            selected = index
    select.select(selected)
    select.item_selected.connect(func(index: int): changed.call(select.get_item_metadata(index)))
    return select

func _toggle(parent: Control, title: String, description: String, key: String) -> void:
    var pad := _margin(0, 16, 0, 16)
    parent.add_child(pad)
    var row := _hbox(20)
    pad.add_child(row)
    var copy := _vbox(4)
    copy.add_child(_label(title, 16, false, true))
    if not description.is_empty():
        copy.add_child(_label(description, 14, true))
    row.add_child(copy)
    var toggle = SWITCH.new()
    toggle.name = "AstryxSetting_" + key
    toggle.accessibility_name = title
    toggle.configure(bool(_value(key)), design, _reduced_motion())
    toggle.toggled.connect(func(value: bool): _set_value(key, value))
    row.add_child(toggle)
    parent.add_child(_divider())

func _interface_settings() -> void:
    var fields := _section(_text("外观", "Appearance", "外観"), _text("选择适合你的界面，让每一段故事都有舒适的开始。", "Make every story feel at home with an interface that suits you.", "あなたに合った外観で、心地よく物語を始めましょう。"))
    var themes := _theme_segment()
    _field(fields, _text("主题", "Theme", "テーマ"), themes)
    _toggle(fields, _t("settings.background_effects"), _t("settings.background_effects_desc"), "background_effects")
    var language_labels: Array = []
    for mode in host.LANGUAGE_MODES:
        language_labels.append(host._language_option_label(mode))
    _field(fields, _text("界面语言", "Language", "表示言語"), _select("language", host.LANGUAGE_MODES, language_labels))
    var pad := _margin(0, 16, 0, 16)
    fields.add_child(pad)
    var switch_row := _hbox(16)
    pad.add_child(switch_row)
    var copy := _vbox(0)
    copy.add_child(_label(_text("界面版本", "Interface", "インターフェイス"), 16, false, true))
    copy.add_child(_label("Astryx", 14, true))
    switch_row.add_child(copy)
    switch_row.add_child(_setting_link(_text("切换到经典界面", "Use classic interface", "クラシックに戻す"), func():
        var destination := Callable(controller, "set_enabled").bind(false)
        if not controller.request_navigation(destination):
            destination.call()
    , "AstryxSwitchToClassic"))
    fields.add_child(_divider())
    if OS.get_name() == "iOS":
        _field(fields, _t("settings.ui_scale"), _select("ios_ui_scale_mode", ["compact", "comfortable", "standard"], [_t("ui_scale.compact"), _t("ui_scale.comfortable"), _t("ui_scale.standard")]))
    var controls := _section(_text("游戏控制", "Game controls", "ゲーム操作"), _text("按你的习惯调整游戏内的触控操作。", "Adjust touch controls to the way you play.", "プレイスタイルに合わせてタッチ操作を調整します。"))
    _toggle(controls, _t("settings.virtual_control_menu"), _t("settings.virtual_control_menu_desc"), "game_virtual_menu_enabled")
    _field(controls, _text("虚拟键盘不透明度", "Virtual keyboard opacity", "仮想キーボードの不透明度"), _opacity_slider())
    if host._mobile_runtime():
        _toggle(controls, _t("settings.picture_in_picture"), _t("settings.picture_in_picture_desc"), "picture_in_picture_enabled")
        _toggle(controls, _t("settings.landscape"), _t("settings.landscape_desc"), "force_landscape")

func _theme_segment() -> Control:
    var group := HBoxContainer.new()
    group.add_theme_constant_override("separation", 0)
    var panel := PanelContainer.new()
    panel.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
    panel.add_theme_stylebox_override("panel", design.box("subtle", 10, "", 0, Vector2(4, 4)))
    panel.add_child(group)
    for mode in ["light", "dark"]:
        var selected: bool = controller.draft_theme == mode
        var button := _button(mode.capitalize(), func():
            controller.draft_theme = mode
            rebuild(true)
        , "quiet", "AstryxTheme_" + mode)
        button.toggle_mode = true
        button.button_pressed = selected
        button.custom_minimum_size = Vector2(60, 36 if phone else 28)
        var fill: StyleBoxFlat = design.box("surface" if selected else "", 6, "", 0, Vector2(12, 4))
        for state in ["normal", "hover", "pressed", "hover_pressed"]:
            button.add_theme_stylebox_override(state, fill)
        group.add_child(button)
    # A plain parent keeps the control at intrinsic width inside a stretch field.
    var row := _hbox()
    row.name = "AstryxSetting_theme"
    row.add_child(panel)
    return row

func _opacity_slider() -> Control:
    var slider := HSlider.new()
    slider.name = "AstryxSetting_game_virtual_keyboard_opacity"
    slider.accessibility_name = _t("settings.keyboard_control_opacity")
    slider.min_value = 20
    slider.max_value = 100
    slider.step = 5
    slider.value = float(_value("game_virtual_keyboard_opacity")) * 100
    slider.custom_minimum_size.y = 44
    slider.add_theme_stylebox_override("slider", design.box("input_border", 2, "", 0, Vector2(0, 2)))
    slider.add_theme_stylebox_override("grabber_area", design.box("accent", 2))
    slider.add_theme_stylebox_override("grabber_area_highlight", design.box("accent", 2))
    slider.tooltip_text = "%d%%" % slider.value
    slider.value_changed.connect(func(value: float):
        _set_value("game_virtual_keyboard_opacity", value / 100)
        slider.tooltip_text = "%d%%" % value
    )
    return slider

func _render_settings() -> void:
    var fields := _section(_text("画面与渲染", "Graphics & rendering", "画面とレンダリング"), _text("调整渲染方式、图像缩放和输出分辨率。", "Choose rendering, scaling and output resolution.", "描画方法、拡大処理、出力解像度を調整します。"))
    _field(fields, _t("settings.render_backend"), _select("backend", host.BACKENDS))
    _field(fields, _t("settings.surface_mode"), _select("surface_mode", ["game", "display"], ["Game Native", "Display Fit"]))
    var algorithms: Array = ["smooth", "linear", "nearest", "bicubic", "lanczos"]
    var algorithm_labels: Array = ["Smooth", "Linear", "Nearest", "Bicubic", "Lanczos"]
    if OS.get_name() in ["macOS", "iOS"] or _value("upscale_algorithm") == "metalfx_spatial":
        algorithms.append("metalfx_spatial")
        algorithm_labels.append("MetalFX Spatial")
    _field(fields, _t("settings.upscale"), _select("upscale_algorithm", algorithms, algorithm_labels))
    _field(fields, _t("settings.output_resolution"), _select("output_resolution", host.OUTPUT_RESOLUTION_MODES, [_t("settings.output_resolution.original"), "1080p", "2K (2560×1440)", "4K (3840×2160)"]))
    var enhancement := _section(_t("settings.frame_enhancement"), _t("settings.frame_enhancement_desc"))
    var kind_labels: Array = []
    for kind in host.FRAME_ENHANCEMENT_KINDS:
        kind_labels.append(_t("settings.frame_enhancement_kind." + kind))
    _field(enhancement, _t("settings.frame_enhancement"), _select("frame_enhancement_kind", host.FRAME_ENHANCEMENT_KINDS, kind_labels))
    if _value("frame_enhancement_kind") == "preset":
        var preset_labels: Array = []
        for preset in host.FRAME_ENHANCEMENT_PRESET_MODES:
            preset_labels.append(_t("settings.frame_enhancement_mode." + preset))
        _field(enhancement, _t("settings.frame_enhancement_mode"), _select("frame_enhancement_mode", host.FRAME_ENHANCEMENT_PRESET_MODES, preset_labels))
    elif _value("frame_enhancement_kind") == "custom":
        _custom_chain(enhancement)
    var fps := _section(_text("帧率", "Frame rate", "フレームレート"), _text("在流畅度和功耗之间找到适合你的设置。", "Balance smooth playback and power use.", "滑らかさと消費電力を調整します。"))
    _toggle(fps, _t("settings.fps_limit"), _t("settings.fps_limit_desc"), "fps_limit_enabled")
    if bool(_value("fps_limit_enabled")):
        var limits: Array = [30, 60, 90, 120, 144, 240]
        if _value("target_fps") not in limits:
            limits.append(_value("target_fps"))
            limits.sort()
        _field(fps, _text("帧率上限", "Frame rate limit", "上限 FPS"), _select("target_fps", limits))

func _custom_chain(parent: Control, game_override: bool = false) -> void:
    var chain: PackedStringArray = PackedStringArray(detail_edit_draft.frame_enhancement_custom_chain) if game_override else host._settings_draft_custom_chain()
    var prefix := "AstryxGame" if game_override else "Astryx"
    var pad := _margin(0, 16, 0, 16)
    parent.add_child(pad)
    var editor := _vbox(16)
    editor.name = prefix + "CustomChain"
    pad.add_child(editor)
    editor.add_child(_label(_t("settings.frame_enhancement_custom_desc"), 14, true))
    var steps := _vbox(16)
    editor.add_child(steps)
    var labels: Array = []
    for algorithm in host.FRAME_ENHANCEMENT_ALGORITHMS:
        labels.append(host.FRAME_ENHANCEMENT_ALGORITHM_LABELS[algorithm])
    if chain.is_empty():
        editor.add_child(_label(_t("settings.frame_enhancement_custom_empty"), 14, true))
    for index in range(chain.size()):
        var step := _vbox(8)
        step.name = prefix + "CustomStep_%d" % index
        steps.add_child(step)
        var row := _hbox(12)
        step.add_child(row)
        var title := _label(_t("settings.frame_enhancement_custom_step") % (index + 1), 14, false, true)
        title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
        if not phone:
            title.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
            title.autowrap_mode = TextServer.AUTOWRAP_OFF
        row.add_child(title)
        var picker := _option(prefix + "CustomAlgorithm_%d" % index, host.FRAME_ENHANCEMENT_ALGORITHMS, labels, chain[index], func(value):
            var updated := chain.duplicate()
            updated[index] = value
            _store_custom_chain(updated, game_override)
        )
        picker.accessibility_name = title.text
        picker.tooltip_text = picker.get_item_text(picker.selected)
        if not phone:
            row.add_child(picker)
        var remove := _setting_link(_text("移除", "Remove", "削除"), func():
            var updated := chain.duplicate()
            updated.remove_at(index)
            _store_custom_chain(updated, game_override)
        , prefix + "RemoveCustomStep_%d" % index)
        remove.accessibility_name = "%s · %s" % [_t("settings.frame_enhancement_custom_remove"), title.text]
        row.add_child(remove)
        if phone:
            step.add_child(picker)
    var add := _button(_text("添加步骤", "Add step", "手順を追加"), func():
        var updated := chain.duplicate()
        updated.append(host.FRAME_ENHANCEMENT_ALGORITHMS[0])
        _store_custom_chain(updated, game_override)
    , "secondary", prefix + "AddCustomStep")
    add.disabled = chain.size() >= host.FRAME_ENHANCEMENT_CUSTOM_MAX_STEPS
    add.size_flags_horizontal = Control.SIZE_SHRINK_END
    editor.add_child(add)
    parent.add_child(_divider())

func _store_custom_chain(chain: PackedStringArray, game_override: bool) -> void:
    if game_override:
        _set_game_render_draft("frame_enhancement_custom_chain", chain)
    else:
        _set_value("frame_enhancement_custom_chain", chain)
        refresh_content.call_deferred(true)

func _reset_detail_edit() -> void:
    detail_edit_generation += 1
    detail_font_import.clear()
    detail_preview_font = null
    detail_edit_key = ""
    detail_edit_path = ""
    detail_edit_draft.clear()
    detail_edit_error = ""

func _begin_detail_edit(key: String) -> void:
    _reset_detail_edit()
    detail_edit_key = key
    detail_edit_path = String(host.selected_game.get("path", ""))
    detail_edit_error = ""
    detail_edit_draft = {"name": host._game_display_title(host.selected_game)} if key == "name" else host._read_game_render_config(host.selected_game).rendering.duplicate(true)
    if key in ["encoding", "font_file"]:
        var loaded: Dictionary = host._read_game_text_config(host.selected_game)
        detail_edit_draft = loaded.text.duplicate(true)
        if loaded.error != OK:
            detail_edit_error = error_string(loaded.error)
        if key == "font_file" and not detail_edit_draft.font_file.is_empty():
            var root: String = host._game_runtime_root(detail_edit_path)
            var font_path: String = host.GameTextConfig.font_path(root, detail_edit_draft.font_file)
            if not font_path.is_empty():
                detail_preview_font = host.GameTextConfig.load_font(font_path).font
    refresh_content(true)
    if key == "name":
        var input := find_child("AstryxGameNameInput", true, false) as LineEdit
        if input != null:
            input.call_deferred("grab_focus")

func _cancel_detail_edit() -> void:
    _reset_detail_edit()
    refresh_content(true)

func _set_game_render_draft(key: String, value) -> void:
    if detail_edit_key.is_empty() or detail_edit_path != String(host.selected_game.get("path", "")):
        return
    detail_edit_draft[key] = value
    detail_edit_error = ""
    refresh_content.call_deferred(true)

func _save_detail_edit() -> void:
    if detail_edit_key.is_empty() or detail_edit_path != String(host.selected_game.get("path", "")):
        return
    if detail_edit_key == "name":
        var value := String(detail_edit_draft.get("name", "")).strip_edges()
        if value.is_empty():
            return
        var path := detail_edit_path
        _reset_detail_edit()
        host._update_game(path, {"title": value})
    elif detail_edit_key in ["encoding", "font_file"]:
        var runtime: String = host._game_runtime_kind(detail_edit_path)
        var root: String = host._game_runtime_root(detail_edit_path)
        var error: Error = host.GameTextConfig.save(root, runtime, host.selected_game,
            {detail_edit_key: detail_edit_draft[detail_edit_key]}, detail_font_import)
        if error != OK:
            detail_edit_error = _text("无法保存游戏设置：", "Could not save game settings: ", "ゲーム設定を保存できません：") + error_string(error)
        else:
            _reset_detail_edit()
    else:
        var patch := {detail_edit_key: detail_edit_draft[detail_edit_key]}
        if detail_edit_key == "frame_enhancement_kind":
            patch.frame_enhancement_mode = detail_edit_draft.frame_enhancement_mode
            if patch.frame_enhancement_kind != "preset":
                patch.frame_enhancement_custom_chain = detail_edit_draft.frame_enhancement_custom_chain
        var error: Error = host._save_game_render_config(host.selected_game, patch)
        if error != OK:
            detail_edit_error = _text("无法保存游戏配置：", "Could not save game settings: ", "ゲーム設定を保存できません：") + error_string(error)
        else:
            _reset_detail_edit()
    refresh_content.call_deferred(true)

func _detail_field(parent: Control, key: String, title: String, value: String, control: Control, divider: bool = true) -> void:
    var expanded := detail_edit_key == key
    var pad := _margin(0, 16, 0, 16)
    parent.add_child(pad)
    var field := _vbox(16)
    pad.add_child(field)
    var header := _hbox(16)
    field.add_child(header)
    var copy := _vbox(0)
    header.add_child(copy)
    copy.add_child(_label(title, 16, false, true))
    if not expanded:
        var summary := _label(value, 14, true)
        summary.name = "AstryxGameName" if key == "name" else "AstryxSettingSummary_game_" + key
        copy.add_child(summary)
        var edit := _setting_link(_text("编辑", "Edit", "編集"), func(): _begin_detail_edit(key), "AstryxRenameGame" if key == "name" else "AstryxEdit_game_" + key)
        edit.accessibility_name = _text("编辑", "Edit ", "編集：") + title
        header.add_child(edit)
    control.name = "AstryxDetailEditor_" + key if control.name.is_empty() else control.name
    control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    control.visible = expanded
    field.add_child(control)
    if expanded:
        if not detail_edit_error.is_empty():
            var error := _label(detail_edit_error, 14)
            error.name = "AstryxDetailEditError"
            field.add_child(error)
        var actions := _hbox(8)
        actions.name = "AstryxDetailEditActions_" + key
        field.add_child(actions)
        var save := _button(_text("保存", "Save", "保存"), _save_detail_edit, "primary", "AstryxSaveDetail_" + key)
        save.disabled = key == "name" and String(detail_edit_draft.get("name", "")).strip_edges().is_empty()
        actions.add_child(save)
        actions.add_child(_button(_text("取消", "Cancel", "キャンセル"), _cancel_detail_edit, "quiet", "AstryxCancelDetail_" + key))
    if divider:
        parent.add_child(_divider())

func _choose_detail_font() -> void:
    var generation := detail_edit_generation
    host._choose_game_font(func(loaded: Dictionary):
        if generation != detail_edit_generation or detail_edit_key != "font_file":
            return
        if loaded.get("error", FAILED) != OK:
            detail_edit_error = _text("无法读取字体，请选择有效的 TTF 或 OTF 文件（最大 32 MiB）。", "Choose a valid TTF or OTF font up to 32 MiB.", "有効な TTF / OTF フォントを選択してください（最大 32 MiB）。")
        else:
            detail_font_import = loaded
            detail_preview_font = loaded.font
            detail_edit_error = ""
        refresh_content(true)
    )

func _detail_text_settings(parent: Control, game: Dictionary, runtime: String) -> void:
    if runtime not in host.GameTextConfig.ENGINES:
        return
    var loaded: Dictionary = host._read_game_text_config(game, runtime)
    var fields := _vbox(0)
    fields.name = "AstryxGameTextSettings"
    parent.add_child(fields)
    if loaded.error != OK:
        fields.add_child(_label(_text("无法读取游戏文本设置：", "Cannot read game text settings: ", "テキスト設定を読み込めません：") + error_string(loaded.error), 14, true))
    var automatic := _text("自动（游戏默认）", "Automatic (game default)", "自動（ゲームの既定値）")
    if runtime == "entisgls":
        var margin := _margin(0, 16, 0, 16)
        fields.add_child(margin)
        var fixed := _vbox(4)
        margin.add_child(fixed)
        fixed.add_child(_label(_text("文本编码", "Text encoding", "文字コード"), 16, false, true))
        fixed.add_child(_label(_text("引擎原生（无需转换）", "Engine native (no conversion)", "エンジン標準（変換不要）"), 14, true))
        fields.add_child(_divider())
    else:
        var values: Array = host.GameTextConfig.encodings(runtime)
        var labels: Array = []
        for value in values:
            labels.append(automatic if String(value).is_empty() else "CP932 / Shift-JIS" if value == "CP932" else value)
        var selected: String = detail_edit_draft.get("encoding", "") if detail_edit_key == "encoding" else loaded.text.encoding
        var picker := _option("AstryxSetting_game_encoding", values, labels, selected, func(value):
            detail_edit_draft.encoding = value
            detail_edit_error = ""
        )
        var summary: String = automatic if loaded.text.encoding.is_empty() else loaded.text.encoding
        _detail_field(fields, "encoding", _text("文本编码", "Text encoding", "文字コード"), summary, picker)
    var editor := _vbox(16)
    editor.name = "AstryxGameFontEditor"
    var current: String = detail_edit_draft.get("font_file", "") if detail_edit_key == "font_file" else loaded.text.font_file
    var caption: String = detail_font_import.get("name", "") if not detail_font_import.is_empty() else current.get_file()
    var label := _label(caption if not caption.is_empty() else _text("默认字体", "Default font", "既定のフォント"), 14, true)
    label.name = "AstryxGameFontPath"
    label.tooltip_text = current
    editor.add_child(label)
    var buttons := _hbox(8)
    editor.add_child(buttons)
    buttons.add_child(_button(_text("选择字体文件", "Choose font file", "フォントを選択"), _choose_detail_font, "secondary", "AstryxChooseGameFont"))
    var reset := _button(_text("恢复默认", "Use default", "既定値に戻す"), func():
        detail_font_import.clear()
        detail_preview_font = null
        detail_edit_draft.font_file = ""
        detail_edit_error = ""
        refresh_content(true)
    , "quiet", "AstryxResetGameFont")
    reset.disabled = current.is_empty() and detail_font_import.is_empty()
    buttons.add_child(reset)
    var preview := _label("你好，世界。物語の続きを。\nThe story continues. 0123456789", 18)
    preview.name = "AstryxGameFontPreview"
    if detail_preview_font != null:
        preview.add_theme_font_override("font", detail_preview_font)
    editor.add_child(preview)
    editor.add_child(_label(_text("下次启动游戏时生效。", "Applies the next time this game starts.", "次回のゲーム起動時に適用されます。"), 14, true))
    _detail_field(fields, "font_file", _text("游戏字体", "Game font", "ゲームフォント"), loaded.text.font_file.get_file() if not loaded.text.font_file.is_empty() else _text("默认字体", "Default font", "既定のフォント"), editor, false)

func _game_render_select(key: String, options: Array, labels: Array, config: Dictionary, inherit: bool = true) -> OptionButton:
    var values := [""] + options if inherit else options.duplicate()
    var captions := [_text("跟随系统", "Use app settings", "全体設定に従う")] + labels if inherit else labels.duplicate()
    return _option("AstryxSetting_game_" + key, values, captions, config[key], func(value): _set_game_render_draft(key, value))

func _game_render_settings(parent: Control, game: Dictionary) -> void:
    var loaded: Dictionary = host._read_game_render_config(game)
    var saved: Dictionary = loaded.rendering
    var config := saved.duplicate(true)
    if detail_edit_key in ["upscale_algorithm", "output_resolution", "frame_enhancement_kind"]:
        config.merge(detail_edit_draft, true)
    parent.add_child(_label(_text("仅对这个游戏生效；跟随系统时使用全局设置。", "Applies to this game. Unspecified options use the app settings.", "このゲームのみに適用。未指定の項目は全体設定に従います。"), 14, true))
    if loaded.error != OK:
        parent.add_child(_label(_text("无法读取游戏配置，请检查文件格式或访问权限。", "Cannot read game settings. Check the file format or access permissions.", "ゲーム設定を読み込めません。形式やアクセス権を確認してください。"), 14, true))
    var fields := _vbox(0)
    parent.add_child(fields)
    var algorithms: Array = ["smooth", "linear", "nearest", "bicubic", "lanczos"]
    var labels: Array = ["Smooth", "Linear", "Nearest", "Bicubic", "Lanczos"]
    if OS.get_name() in ["macOS", "iOS"] or config.upscale_algorithm == "metalfx_spatial":
        algorithms.append("metalfx_spatial")
        labels.append("MetalFX Spatial")
    var upscale := _game_render_select("upscale_algorithm", algorithms, labels, config)
    _detail_field(fields, "upscale_algorithm", _t("settings.upscale"), upscale.get_item_text(upscale.selected), upscale)
    var resolution := _game_render_select("output_resolution", host.OUTPUT_RESOLUTION_MODES, [_t("settings.output_resolution.original"), "1080p", "2K (2560×1440)", "4K (3840×2160)"], config)
    _detail_field(fields, "output_resolution", _t("settings.output_resolution"), resolution.get_item_text(resolution.selected), resolution)
    var kind_labels: Array = []
    for kind in host.FRAME_ENHANCEMENT_KINDS:
        kind_labels.append(_t("settings.frame_enhancement_kind." + kind))
    var enhancement := _vbox(16)
    enhancement.name = "AstryxGameEnhancementEditor"
    var kind := _game_render_select("frame_enhancement_kind", host.FRAME_ENHANCEMENT_KINDS, kind_labels, config)
    enhancement.add_child(kind)
    var summary := _text("跟随系统", "Use app settings", "全体設定に従う") if String(saved.frame_enhancement_kind).is_empty() else _t("settings.frame_enhancement_kind." + String(saved.frame_enhancement_kind))
    if saved.frame_enhancement_kind == "preset":
        summary += " · " + _t("settings.frame_enhancement_mode." + String(saved.frame_enhancement_mode))
    elif saved.frame_enhancement_kind == "custom":
        summary += " · " + _text("%d 个步骤", "%d steps", "%d ステップ") % saved.frame_enhancement_custom_chain.size()
    if detail_edit_key == "frame_enhancement_kind" and config.frame_enhancement_kind == "preset":
        var preset_labels: Array = []
        for preset in host.FRAME_ENHANCEMENT_PRESET_MODES:
            preset_labels.append(_t("settings.frame_enhancement_mode." + preset))
        _field(enhancement, _t("settings.frame_enhancement_mode"), _game_render_select("frame_enhancement_mode", host.FRAME_ENHANCEMENT_PRESET_MODES, preset_labels, config, false))
    elif detail_edit_key == "frame_enhancement_kind" and config.frame_enhancement_kind == "custom":
        _custom_chain(enhancement, true)
        enhancement.get_child(-1).free()
    _detail_field(fields, "frame_enhancement_kind", _t("settings.frame_enhancement"), summary, enhancement)
    # The next accordion already supplies the section divider.
    fields.get_child(-1).free()

func _compatibility_settings() -> void:
    var fields := _section(_text("运行时兼容性", "Runtime compatibility", "ランタイムの互換性"), _t("settings.plugin_load_mode_desc"))
    _field(fields, _t("settings.plugin_load_mode"), _select("plugin_load_mode", ["krkrsdl3", "aether_all"], [_t("settings.plugin_load.core"), _t("settings.plugin_load.all")]))
    _toggle(fields, _t("settings.mock"), _t("settings.mock_desc"), "mock_enabled")
    if host.player != null and host.player.has_method("is_text_translation_available") and host.player.is_text_translation_available():
        var translation := _section(_t("settings.translation_model"), _t("settings.translation_model_desc"))
        var model_path := String(_value("text_translation_model_path"))
        if not model_path.is_empty():
            translation.add_child(_label(model_path.get_file(), 14, true))
        translation.add_child(_button(_t("settings.translation_model_select"), host._choose_translation_model))
        if not model_path.is_empty():
            translation.add_child(_button(_t("settings.translation_model_clear"), func():
                host._clear_translation_model()
                refresh_content(true)
            ))

func _diagnostic_settings() -> void:
    var fields := _section(_text("诊断与日志", "Diagnostics & logs", "診断とログ"), _text("在遇到问题时保留必要的信息。", "Keep useful information when something goes wrong.", "問題の調査に必要な情報を記録します。"))
    var profiles: Array = []
    for profile in host.DIAGNOSTIC_PROFILES:
        profiles.append(_t("profile." + profile))
    _field(fields, _t("settings.diagnostic_profile"), _select("diagnostic_profile", host.DIAGNOSTIC_PROFILES, profiles))
    _field(fields, _t("settings.debug_overlay"), _select("debug_overlay_mode", host.DEBUG_OVERLAY_MODES, [_t("overlay.off"), _t("overlay.summary"), _t("overlay.detail")]))
    _toggle(fields, _t("settings.error_dialog_logs"), _t("settings.error_dialog_logs_desc"), "error_dialog_logs")
    var advanced := _section(_t("settings.section.advanced"), _t("settings.advanced_desc"))
    for entry in [["plugin_trace", "plugin_trace"], ["trace_log", "trace_log"], ["console_log_file", "console_log"], ["export_scripts", "export_tjs"]]:
        var pad := _margin(0, 16, 0, 16)
        advanced.add_child(pad)
        var row := _hbox(16)
        pad.add_child(row)
        row.add_child(_label(_t("settings." + entry[1]), 16, false, true))
        var toggle = SWITCH.new()
        toggle.accessibility_name = _t("settings." + entry[1])
        toggle.configure(bool(host.get(entry[0])), design, _reduced_motion())
        toggle.toggled.connect(func(value: bool): host._set_advanced_tool(entry[0], value))
        row.add_child(toggle)
        advanced.add_child(_divider())

func _about_row(parent: Control, id: String, title: String, description: String, control: Control) -> void:
    var pad := _margin(0, 16, 0, 16)
    pad.name = "AstryxAboutRow_" + id
    parent.add_child(pad)
    var row := _hbox(16)
    pad.add_child(row)
    var copy := _vbox(4)
    copy.name = "Description"
    copy.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    row.add_child(copy)
    copy.add_child(_label(title, 16, false, true))
    if not description.is_empty():
        copy.add_child(_label(description, 14, true))
    control.name = "AstryxAbout_" + id
    control.size_flags_horizontal = Control.SIZE_SHRINK_END
    control.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    row.add_child(control)
    parent.add_child(_divider())

func _about_purchase(parent: Control, id: String, source: Control, title: String, description: String, status: String) -> void:
    # Retain the host's purchase state, price and callbacks, only replace its row.
    for button in source.find_children("*", "Button", true, false):
        if not button.get_meta("settings_action", false):
            continue
        button.get_parent().remove_child(button)
        _style_setting_link(button)
        _about_row(parent, id, title, "%s\n%s" % [description, status], button)
        source.free()
        return
    style_external_modal(source)
    parent.add_child(source)

func _about_settings() -> void:
    var fields := _section("Aether", _text("让故事，再次抵达你。", "Let the story find you again.", "物語を、もう一度あなたへ。"))
    var version := _label(host._application_version_text(), 16, true)
    version.autowrap_mode = TextServer.AUTOWRAP_OFF
    version.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    version.custom_minimum_size.y = 44
    version.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    version.mouse_filter = Control.MOUSE_FILTER_STOP
    host._attach_secret_version_tap(version)
    _about_row(fields, "version", _t("settings.version"), _text("当前安装的应用版本", "Currently installed app version", "インストール済みのバージョン"), version)
    _about_row(fields, "legal", _t("settings.legal"), _t("settings.legal_desc"), _setting_link(_t("settings.legal_open"), func(): host._show_legal_agreement(false)))
    if host._apple_app_store_platform():
        _about_row(fields, "apple_notice", _t("settings.ios_statement"), _t("settings.ios_statement_desc"), _setting_link(_t("settings.ios_statement_open"), host._show_ios_additional_statement))
    _about_row(fields, "updates", _t("settings.check_update"), _t("settings.check_update_desc"), _setting_link(_t("settings.check_update_action"), host._check_app_update_manually))
    if not host._is_apple_app_store_build():
        var toggle = SWITCH.new()
        toggle.configure(host.include_prerelease, design, _reduced_motion())
        toggle.accessibility_name = _t("settings.include_prerelease")
        toggle.toggled.connect(func(value: bool): host._on_setting_toggle("include_prerelease", value))
        _about_row(fields, "prerelease", _t("settings.include_prerelease"), _t("settings.include_prerelease_desc"), toggle)
    var community := _section(_t("settings.section.community_support"), "")
    _about_row(community, "community", _t("settings.community"), _t("settings.community_desc"), _setting_link(_t("settings.community_open"), host._open_community))
    if host._apple_app_store_platform():
        _about_row(community, "rate_app", _t("settings.rate_app"), _t("settings.rate_app_desc"), _setting_link(_t("settings.rate_app_open"), host._open_app_store_review))
    if host._coffee_sponsorship_available():
        _about_row(community, "support", _t("support.coffee.title"), _t("support.coffee.desc"), _setting_link(_t("support.coffee.open"), host._open_coffee_sponsorship))
    if host._iap_supported_platform():
        var purchases := _section(_t("settings.section.purchases"), "")
        _about_purchase(purchases, "purchase_library", host._settings_iap_product_row(), _t("iap.list_limit.title"), _t("iap.list_limit.desc"), host._iap_product_status_text())
        _about_purchase(purchases, "purchase_coffee", host._settings_iap_coffee_row(), _t("iap.coffee.title"), _t("iap.coffee.desc"), host._iap_coffee_status_text())
        _about_row(purchases, "restore", _t("iap.restore"), _t("iap.restore_desc"), _setting_link(_t("iap.restore_action"), host._begin_iap_restore))

func _build_library() -> void:
    var media := route in ["videos", "flash"]
    var title := _nav_label(route)
    var refresh_only: bool = host._library_uses_refresh_action()
    var import_button := _button(_t("home.refresh") if refresh_only else _t("home.import"),
        _import, "primary", "AstryxRefresh" if refresh_only else "AstryxImport")
    import_button.icon = load("res://assets/ui/astryx/%s.svg" % ("refresh" if refresh_only else "plus"))
    import_button.expand_icon = true
    import_button.add_theme_constant_override("icon_max_width", 18)
    var actions := _hbox(8 if phone else 12)
    actions.size_flags_horizontal = Control.SIZE_SHRINK_END
    if not media:
        actions.add_child(_library_display_switch())
    actions.add_child(import_button)
    _header(title, true, actions)
    # Expanded icons do not contribute to Button's minimum width.
    var text_width := import_button.get_theme_font("font").get_string_size(import_button.text,
        HORIZONTAL_ALIGNMENT_LEFT, -1, import_button.get_theme_font_size("font_size")).x
    import_button.custom_minimum_size.x = text_width + 18 + 8 + 24
    if media and is_instance_valid(search):
        search.placeholder_text = _text("搜索文件…", "Search files…", "ファイルを検索…")
        search.accessibility_name = search.placeholder_text
    _scroll_into(page, 20 if phone else 24)
    _library_content()

func _library_display_switch() -> Control:
    var panel := PanelContainer.new()
    panel.name = "AstryxLibraryDisplay"
    panel.accessibility_name = _text("展示方式", "Library display", "表示方法")
    panel.add_theme_stylebox_override("panel", design.box("subtle", 10))
    var group := HBoxContainer.new()
    group.add_theme_constant_override("separation", 0)
    panel.add_child(group)
    for mode in ["cards", "list"]:
        var selected: bool = controller.library_display == mode
        var label := _text("卡片", "Cards", "カード") if mode == "cards" else _text("列表", "List", "リスト")
        var button := _button("" if phone else label, func():
            controller.set_library_display(mode)
        , "quiet", "AstryxDisplay_" + mode)
        button.accessibility_name = label
        button.tooltip_text = label
        button.toggle_mode = true
        button.button_pressed = selected
        button.icon = load("res://assets/ui/astryx/%s.svg" % mode)
        button.expand_icon = true
        button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER if phone else HORIZONTAL_ALIGNMENT_LEFT
        button.add_theme_constant_override("icon_max_width", 18)
        button.custom_minimum_size = Vector2(44 if phone else 76, 44)
        var fill: StyleBoxFlat = design.box("surface" if selected else "", 10, "", 0, Vector2(10, 6))
        if selected:
            fill.set_border_width_all(1)
            fill.border_color = design.color("border")
        for state in ["normal", "hover", "pressed", "hover_pressed"]:
            button.add_theme_stylebox_override(state, fill)
        group.add_child(button)
    return panel

func _import() -> void:
    host._on_refresh_or_import()
    controller.sync_state()

func _library_content() -> void:
    if route in ["videos", "flash"]:
        _media_content()
        return
    library_content_key = _library_key()
    var bar := _hbox(8)
    content.add_child(bar)
    var all := _tab_button(_text("全部游戏", "All games", "すべて"), func():
        recent_only = false
        refresh_content()
    , not recent_only, "AstryxAllGames")
    bar.add_child(all)
    bar.add_child(_tab_button(_text("最近游玩", "Recently played", "最近プレイ"), func():
        recent_only = true
        refresh_content()
    , recent_only, "AstryxRecentGames"))
    var games: Array = []
    for game in host.known_games:
        if host._game_matches_home_search(game, query) and (not recent_only or int(game.get("lastPlayed", 0)) > 0):
            games.append(game)
    if recent_only:
        games.sort_custom(func(a, b): return int(a.get("lastPlayed", 0)) > int(b.get("lastPlayed", 0)))
    var count := _label(_text("%d 部游戏", "%d games", "%d 本") % games.size(), 12, true)
    count.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    count.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    bar.add_child(count)
    if games.is_empty():
        if not query.is_empty():
            _empty(_t("search.no_results_title"), _t("search.no_results_help"), "search")
        elif recent_only:
            _empty(_text("尚未开始游玩", "Your next story awaits", "まだプレイしていません"), _text("开始一个游戏后，会在这里找到它。", "Games you play will appear here.", "プレイしたゲームはここに表示されます。"), "library")
        else:
            _empty(_t("home.empty_title"), host._empty_help_text(), "library", _button(_t("home.refresh" if host._library_uses_refresh_action() else "home.import"), _import, "primary", "AstryxEmptyLibraryAction"))
        return
    if controller.library_display == "list":
        var list := _vbox(4)
        list.name = "AstryxGameList"
        content.add_child(list)
        for game in games:
            list.add_child(_game_row(game))
        _enter(list)
        return
    var grid := _grid()
    content.add_child(grid)
    var width := _card_width(grid.columns)
    for game in games:
        grid.add_child(_game_card(game, width))
    _enter(grid)

func _game_row(game: Dictionary) -> Button:
    var title: String = host._game_display_title(game)
    var button := _button("", func(): host._open_game_detail_with_iap(game), "quiet", "AstryxGameRow")
    button.accessibility_name = title
    button.tooltip_text = title
    button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    button.custom_minimum_size.y = 88
    var pad := _margin(12, 8, 12, 8)
    pad.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
    button.add_child(pad)
    var row := _hbox(16)
    row.mouse_filter = Control.MOUSE_FILTER_IGNORE
    pad.add_child(row)
    var cover := _cover(game, 72, true)
    cover.custom_minimum_size.x = 54
    cover.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
    row.add_child(cover)
    var labels := _vbox(4)
    labels.mouse_filter = Control.MOUSE_FILTER_IGNORE
    labels.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    row.add_child(labels)
    var heading := _label(title, 16, false, true)
    heading.max_lines_visible = 2
    heading.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
    labels.add_child(heading)
    labels.add_child(_game_history(game))
    row.add_child(_icon("chevron_right", 18, "secondary"))
    pad.minimum_size_changed.connect(func(): button.custom_minimum_size.y = maxf(88, pad.get_combined_minimum_size().y))
    return button

func _game_history(game: Dictionary) -> VBoxContainer:
    var history := _vbox(2)
    history.name = "AstryxGameHistory"
    history.mouse_filter = Control.MOUSE_FILTER_IGNORE
    var duration: String = host._format_play_duration(int(game.get("playDurationSeconds", 0)))
    history.add_child(_label(_text("已玩 %s", "Played %s", "プレイ時間 %s") % duration, 12, true))
    var last_launch := int(game.get("lastPlayed", 0))
    var recent := _text("尚未启动", "Not started yet", "未プレイ")
    var full_date := ""
    if last_launch > 0:
        # Match the host's local-time conversion for stored Unix timestamps.
        var bias := int(Time.get_time_zone_from_system().get("bias", 0)) * 60
        var date := Time.get_datetime_dict_from_unix_time(last_launch + bias)
        var short_date := "%02d/%02d %02d:%02d" % [date.month, date.day, date.hour, date.minute]
        full_date = "%04d/%s" % [date.year, short_date]
        if date.year != Time.get_date_dict_from_system().year:
            short_date = full_date
        recent = _text("最近启动 %s", "Last opened %s", "前回起動 %s") % short_date
    var label := _label(recent, 12, true)
    label.tooltip_text = full_date
    label.mouse_filter = Control.MOUSE_FILTER_PASS
    history.add_child(label)
    return history

func _grid() -> GridContainer:
    var grid := GridContainer.new()
    grid.name = "AstryxLibraryGrid"
    grid.columns = 2 if phone else 3
    grid.add_theme_constant_override("h_separation", 16 if phone else 24)
    grid.add_theme_constant_override("v_separation", 24)
    grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    return grid

func _content_width() -> float:
    return size.x - (40 if phone else sidebar_width + 48)

func _card_width(columns: int) -> float:
    return maxf(96, (_content_width() - (16 if phone else 24) * (columns - 1)) / columns)

func _game_card(game: Dictionary, width: float) -> Button:
    var title: String = host._game_display_title(game)
    var button := _button("", func(): host._open_game_detail_with_iap(game), "quiet")
    button.name = "AstryxGameCard"
    button.accessibility_name = title
    button.tooltip_text = title
    button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    # Reserve two title lines and the history; longer localized dates may wrap.
    button.custom_minimum_size = Vector2(0, width * (4.0 / 3.0 if phone else 0.75))
    for key in ["normal", "hover", "pressed"]:
        button.add_theme_stylebox_override(key, StyleBoxEmpty.new())
    button.add_theme_stylebox_override("focus", design.focus_box(16))
    var stack := _vbox(10)
    stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
    stack.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    button.add_child(stack)
    var height := width * (4.0 / 3.0 if phone else 0.75)
    stack.add_child(_cover(game, height))
    var label := _label(title, 14 if phone else 16, false, true)
    label.max_lines_visible = 2
    label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
    stack.add_child(label)
    stack.add_child(_game_history(game))
    stack.minimum_size_changed.connect(func(): button.custom_minimum_size.y = stack.get_combined_minimum_size().y)
    button.custom_minimum_size.y = stack.get_combined_minimum_size().y
    return button

func _cover(game: Dictionary, height: float, thumbnail: bool = false) -> Control:
    var cover := PanelContainer.new()
    cover.custom_minimum_size.y = height
    cover.mouse_filter = Control.MOUSE_FILTER_IGNORE
    cover.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    cover.add_theme_stylebox_override("panel", design.box("subtle", 12))
    var texture: Texture2D = host._load_cover_texture(game)
    if texture != null:
        var image: TextureRect = host._rounded_cover_rect(texture, 12)
        image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
        image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
        image.mouse_filter = Control.MOUSE_FILTER_IGNORE
        cover.add_child(image)
    elif thumbnail:
        cover.add_child(_icon("library", 22, "secondary"))
    else:
        var pad := _margin(16 if phone else 24, 20, 16 if phone else 24, 20)
        pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
        cover.add_child(pad)
        var stack := _vbox(8)
        stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
        pad.add_child(stack)
        var monogram := _label("Ae", 44 if phone else 56, true, true)
        monogram.size_flags_vertical = Control.SIZE_EXPAND_FILL
        monogram.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
        stack.add_child(monogram)
        stack.add_child(_label("AETHER", 11, true))
    return cover

func _empty(title: String, description: String, glyph: String, action: Button = null) -> void:
    var pad := _margin(12, 48, 12, 48)
    content.add_child(pad)
    var stack := _vbox(16)
    stack.alignment = BoxContainer.ALIGNMENT_CENTER
    pad.add_child(stack)
    stack.add_child(_icon(glyph, 44, "secondary"))
    var heading := _label(title, 20, false, true)
    heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    stack.add_child(heading)
    var body := _label(description, 14, true)
    body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    stack.add_child(body)
    if action != null:
        action.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
        stack.add_child(action)

func _open_media_directory(path: String) -> void:
    query = ""
    search.text = ""
    if path.is_empty():
        host._go_to_video_library_root()
    else:
        host._enter_video_directory(path)
    refresh_content()

func _media_breadcrumbs(library) -> Control:
    var crumbs := [{"label": _nav_label(route), "path": ""}]
    if library.can_go_up():
        var origin := String(library.navigation_root)
        var path := origin
        if String(library.automatic_root).is_empty():
            crumbs.append({"label": origin.get_file(), "path": path})
        for segment in String(library.current_directory).trim_prefix(origin).trim_prefix("/").split("/", false):
            path = path.path_join(segment)
            crumbs.append({"label": segment, "path": path})
    var trail := HFlowContainer.new()
    trail.name = "AstryxBreadcrumbs"
    trail.accessibility_name = _text("文件夹路径", "Folder path", "フォルダーのパス")
    trail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    trail.add_theme_constant_override("h_separation", 4)
    trail.add_theme_constant_override("v_separation", 0)
    for index in range(crumbs.size()):
        var item: Dictionary = crumbs[index]
        var group := _hbox(4)
        group.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
        trail.add_child(group)
        if index > 0:
            var separator := _label("/", 14, true)
            separator.autowrap_mode = TextServer.AUTOWRAP_OFF
            separator.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
            separator.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
            group.add_child(separator)
        var current := index == crumbs.size() - 1
        var crumb := _button(String(item.label), _open_media_directory.bind(String(item.path)), "quiet", "AstryxBreadcrumb_%d" % index)
        crumb.set_meta("path", item.path)
        crumb.tooltip_text = item.label
        crumb.disabled = current
        crumb.clip_text = true
        crumb.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
        crumb.add_theme_font_override("font", design.bold if current else design.font)
        crumb.add_theme_font_size_override("font_size", 14)
        var text_width: float = crumb.get_theme_font("font").get_string_size(crumb.text, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
        crumb.custom_minimum_size.x = minf(text_width + 8, maxf(80, _content_width() - 24))
        for state in ["normal", "hover", "pressed", "disabled"]:
            crumb.add_theme_stylebox_override(state, design.box("", 4, "", 0, Vector2(4, 0)))
        crumb.add_theme_stylebox_override("focus", design.box("", 4, "input_border", 1))
        crumb.add_theme_color_override("font_color", design.color("secondary"))
        crumb.add_theme_color_override("font_hover_color", design.color("text"))
        crumb.add_theme_color_override("font_disabled_color", design.color("text"))
        group.add_child(crumb)
    return trail

func _media_action(icon_name: String, label: String, action: Callable, node_name: String) -> Button:
    var button := _button("", action, "quiet", node_name)
    button.icon = load("res://assets/ui/astryx/%s.svg" % icon_name)
    button.expand_icon = true
    button.add_theme_constant_override("icon_max_width", 20)
    button.custom_minimum_size = Vector2(44, 44)
    button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    button.accessibility_name = label
    button.tooltip_text = label
    return button

func _media_content() -> void:
    var library = host._active_file_library()
    content.add_theme_constant_override("separation", 8)
    if library.can_go_up():
        content.add_child(_media_breadcrumbs(library))
    var entries: Array = []
    for item in library.entries if query.is_empty() else library.search_entries():
        if query.is_empty() or (str(item.get("name", "")) + " " + str(item.get("path", ""))).to_lower().contains(query.to_lower()):
            entries.append(item)
    var folder_count := 0
    for entry in entries:
        if host.VideoLibrary.is_directory(entry):
            folder_count += 1
    content.add_child(_label(_text("%d 个文件夹 · %d 个文件", "%d folders · %d files", "%d フォルダー · %d ファイル") % [folder_count, entries.size() - folder_count], 12, true))
    if entries.is_empty():
        _empty(_t("search.no_results_title") if not query.is_empty() else host._media_text("video.empty_folder_title" if library.can_go_up() else "video.empty_title"), _t("search.no_results_help") if not query.is_empty() else host._video_empty_help_text(), "flash" if route == "flash" else "video", _button(host._media_text("video.refresh" if host._library_uses_refresh_action() else "video.import"), _import, "primary", "AstryxEmptyLibraryAction") if query.is_empty() else null)
        return
    for item in entries:
        var row := _hbox(12)
        row.name = "AstryxMediaRow_%d" % content.get_child_count()
        row.set_meta("path", item.path)
        content.add_child(row)
        var folder: bool = host.VideoLibrary.is_directory(item)
        var name_value := String(item.get("name", String(item.get("path", "")).get_file()))
        var open := func():
            if folder:
                _open_media_directory(String(item.path))
            elif route == "flash":
                host._open_flash_player(item)
            else:
                host._open_video_player(item)
        var button := _button("", open, "quiet", "AstryxOpenMedia")
        button.accessibility_name = name_value
        button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        button.custom_minimum_size.y = 64
        button.add_theme_stylebox_override("normal", design.box("", 10))
        row.add_child(button)
        var pad := _margin(12, 8, 0, 8)
        pad.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
        pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
        button.add_child(pad)
        var contents := _hbox(16)
        contents.mouse_filter = Control.MOUSE_FILTER_IGNORE
        pad.add_child(contents)
        contents.add_child(_icon("folder" if folder else ("flash" if route == "flash" else "video"), 26, "secondary"))
        var labels := _vbox(4)
        labels.alignment = BoxContainer.ALIGNMENT_CENTER
        labels.mouse_filter = Control.MOUSE_FILTER_IGNORE
        contents.add_child(labels)
        var title := _label(name_value, 15, false, true)
        title.max_lines_visible = 1
        title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
        labels.add_child(title)
        var description := _label(host._media_text("video.open_folder") if folder else String(item.get("fileName", "")), 12, true)
        description.max_lines_visible = 1
        description.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
        labels.add_child(description)
        var actions := _hbox(4)
        actions.name = "AstryxMediaActions"
        actions.size_flags_horizontal = Control.SIZE_SHRINK_END
        actions.size_flags_vertical = Control.SIZE_SHRINK_CENTER
        row.add_child(actions)
        var open_label: String = host._media_text("video.open_folder") if folder else _text("播放", "Play", "再生")
        actions.add_child(_media_action("chevron_right" if folder else "play", open_label + " " + name_value, open, "AstryxPlayMedia"))
        if library.can_remove(item):
            actions.add_child(_media_action("delete", _text("删除", "Delete", "削除") + " " + name_value, func(): host._confirm_remove_video(item), "AstryxDeleteMedia"))

func _build_detail() -> void:
    # A separate layer keeps the cover wash behind the header and scrollport.
    var backdrop_layer := Control.new()
    backdrop_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
    page.get_parent().add_child(backdrop_layer)
    page.get_parent().move_child(backdrop_layer, 0)
    detail_backdrop = TextureRect.new()
    detail_backdrop.name = "AstryxDetailBackdrop"
    detail_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
    detail_backdrop.anchor_right = 1.0
    detail_backdrop.offset_bottom = 420.0
    detail_backdrop.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    detail_backdrop.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
    detail_backdrop.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
    var material := SHADERS.material(SHADERS.image())
    material.set_shader_parameter("radius", 0.0 if phone else 28.0)
    material.set_shader_parameter("blur", 4.5)
    material.set_shader_parameter("zoom", 1.25)
    material.set_shader_parameter("fade_bottom", 0.85)
    material.set_shader_parameter("fade_color", design.color("surface"))
    material.set_shader_parameter("dim", 0.45 if design.mode == "dark" else 0.0)
    detail_backdrop.material = material
    detail_backdrop.modulate.a = 0.55 if design.mode == "dark" else 0.35
    var backdrop := detail_backdrop
    backdrop.resized.connect(func(): material.set_shader_parameter("rect_size", backdrop.size))
    backdrop_layer.add_child(backdrop)
    var pad := _margin(16, 16, 16, 16)
    page.add_child(pad)
    var back := _button(_nav_label("library"), func(): navigate("library"), "quiet", "AstryxDetailBack")
    back.icon = load("res://assets/ui/astryx/back.svg")
    back.expand_icon = true
    back.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
    back.add_theme_constant_override("icon_max_width", 20)
    # Expanded icons do not contribute to Button's minimum width in Godot.
    # Reserve the arrow explicitly so a short, content-sized button cannot hide it.
    var text_width := back.get_theme_font("font").get_string_size(back.text, HORIZONTAL_ALIGNMENT_LEFT, -1, back.get_theme_font_size("font_size")).x
    back.custom_minimum_size.x = text_width + 20 + 8 + 24
    back.accessibility_name = _text("返回游戏库", "Back to games", "ゲーム一覧に戻る")
    pad.add_child(back)
    page.add_child(_divider())
    _scroll_into(page, 20 if phone else 24)
    _detail_content()

func _detail_content() -> void:
    var game: Dictionary = host.selected_game
    if not detail_edit_path.is_empty() and detail_edit_path != String(game.get("path", "")):
        _reset_detail_edit()
    var texture: Texture2D = host._load_cover_texture(game, Vector2i(480, 480), 0) if not game.is_empty() else null
    detail_backdrop.texture = host._mipmapped_texture(texture) if texture != null else null
    detail_backdrop.visible = texture != null
    if game.is_empty():
        return
    var narrow := _content_width() < 660
    var layout: BoxContainer = _vbox(20) if narrow else _hbox(20)
    content.add_child(layout)
    var column_width := _content_width() - 10 if narrow else (_content_width() - 30) / 2
    # Use the artwork's own ratio so landscape covers fill the column without
    # letterboxing. Only shrink when needed to keep the full image on screen.
    var available_height := maxf(80, size.y - 133 - (68 if phone else 0))
    var max_cover_height := minf(available_height, size.y * 0.60) if phone else available_height
    var gallery := _vbox(0)
    if not narrow:
        gallery.custom_minimum_size.x = column_width
        gallery.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
    layout.add_child(gallery)
    var image := _cover(game, 0)
    image.name = "AstryxDetailCover"
    image.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
    image.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
    var artwork := image.find_child("CoverImage", true, false) as TextureRect
    var ratio := 4.0 / 5.0
    if artwork != null:
        ratio = artwork.texture.get_size().aspect()
        artwork.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
        image.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
    var cover_size := Vector2(column_width, column_width / ratio)
    if cover_size.y > max_cover_height:
        cover_size *= max_cover_height / cover_size.y
    image.custom_minimum_size = cover_size
    gallery.add_child(image)
    var info := _vbox(20)
    layout.add_child(info)
    var heading := _vbox(8)
    info.add_child(heading)
    heading.add_child(_label(host._game_display_title(game), 34, false, true))
    _field(info, _text("游玩记录", "Play history", "プレイ履歴"), _label("%s · %s" % [host._last_played_label(game), host._format_play_duration(int(game.get("playDurationSeconds", 0)))], 14, true))
    var actions := _vbox(8)
    info.add_child(actions)
    var launch := _button(_text("开始游戏", "Start game", "ゲームを開始"), host._start_selected_game, "primary", "AstryxLaunchGame")
    launch.icon = load("res://assets/ui/astryx/play.svg")
    launch.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
    launch.expand_icon = true
    launch.add_theme_constant_override("icon_max_width", 20)
    launch.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    actions.add_child(launch)
    var rows := _collapsible(info, "information", _text("游戏信息", "Game information", "ゲーム情報"))
    if rows.visible:
        _detail_information(rows, game)
    var rendering := _collapsible(info, "rendering", _text("画面与渲染", "Graphics & rendering", "画面とレンダリング"))
    if rendering.visible:
        _game_render_settings(rendering, game)
    var cover_section := _collapsible(info, "cover", _text("封面", "Cover", "カバー"))
    if cover_section.visible:
        _detail_cover_actions(cover_section, game)
    info.add_child(_divider())

func _detail_information(rows: Control, game: Dictionary) -> void:
    var input := LineEdit.new()
    input.name = "AstryxGameNameInput"
    input.accessibility_name = _text("游戏名字", "Game name", "ゲーム名")
    input.text = String(detail_edit_draft.get("name", "")) if detail_edit_key == "name" else host._game_display_title(game)
    input.custom_minimum_size.y = 44
    input.text_changed.connect(func(value: String):
        if detail_edit_key != "name":
            return
        detail_edit_draft["name"] = value
        var save := find_child("AstryxSaveDetail_name", true, false) as Button
        if save != null:
            save.disabled = value.strip_edges().is_empty()
    )
    input.text_submitted.connect(func(_value: String): _save_detail_edit())
    _detail_field(rows, "name", input.accessibility_name, host._game_display_title(game), input, false)
    # Reuse one engine detection for all fields on this page; probing archives
    # repeatedly on mobile storage can block the opening frame.
    var runtime: String = host._game_runtime_kind(String(game.get("path", "")))
    _detail_text_settings(rows, game, runtime)
    var launch_row := _hbox(16)
    launch_row.name = "AstryxLaunchFileRow"
    rows.add_child(launch_row)
    var launch_copy := _vbox(4)
    launch_copy.name = "Description"
    launch_copy.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    launch_row.add_child(launch_copy)
    launch_copy.add_child(_label(_text("启动文件", "Launch file", "起動ファイル"), 16, false, true))
    launch_copy.add_child(_label(host._game_launch_entry_label(game), 14, true))
    if host._can_configure_launch_file(game, runtime):
        var set_launch := _setting_link(_text("设置", "Set", "設定"), host._set_launch_file_for_selected, "AstryxSetLaunchFile")
        set_launch.accessibility_name = _t("detail.set_launch_file")
        set_launch.size_flags_horizontal = Control.SIZE_SHRINK_END
        set_launch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
        launch_row.add_child(set_launch)
        if not host.GameLaunchEntry.configured_relative_path(game).is_empty():
            var reset_launch := _setting_link(_t("detail.reset_launch_file"), host._reset_launch_file_for_selected, "AstryxResetLaunchFile")
            reset_launch.size_flags_horizontal = Control.SIZE_SHRINK_END
            rows.add_child(reset_launch)
    rows.add_child(_label(String(game.get("path", "")), 12, true))
    var remove := _button(_text("删除游戏", "Delete game", "ゲームを削除"), host._confirm_remove_selected, "destructive", "AstryxRemoveGame")
    remove.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    rows.add_child(remove)

func _detail_cover_actions(cover_section: Control, game: Dictionary) -> void:
    var cover_path: String = host._resolve_cover_path(game)
    var location := _label(cover_path if not cover_path.is_empty() else _text("未设置封面", "No cover set", "カバー未設定"), 14, true)
    location.name = "AstryxCoverPath"
    location.autowrap_mode = TextServer.AUTOWRAP_OFF
    location.clip_text = true
    location.max_lines_visible = 1
    location.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
    location.tooltip_text = cover_path
    location.accessibility_name = _text("封面文件：", "Cover file: ", "カバーファイル：") + location.text
    location.mouse_filter = Control.MOUSE_FILTER_PASS
    cover_section.add_child(location)
    var cover_actions := _vbox(12)
    cover_actions.name = "AstryxCoverActions"
    cover_section.add_child(cover_actions)
    var set_cover := _button(_t("detail.set_cover"), _show_cover_sources, "primary", "AstryxSetCover")
    set_cover.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    cover_actions.add_child(set_cover)
    if not cover_path.is_empty():
        # Remove the cover association, preserving the user's source image.
        var clear_cover := _button(_text("清除封面", "Clear cover", "カバーをクリア"), host._clear_cover_for_selected, "destructive", "AstryxClearCover")
        clear_cover.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        cover_actions.add_child(clear_cover)

func _show_cover_sources() -> void:
    COVER_PICKER.new().show_for(self)

func _collapsible(parent: Control, id: String, title: String) -> VBoxContainer:
    var group := _vbox(12)
    parent.add_child(group)
    group.add_child(_divider())
    var expanded: bool = expanded_details[id]
    var trigger := _button(title, func():
        expanded_details[id] = not expanded_details[id]
        if not expanded_details[id] and ((id == "information" and detail_edit_key in ["name", "encoding", "font_file"]) or (id == "rendering" and detail_edit_key in ["upscale_algorithm", "output_resolution", "frame_enhancement_kind"])):
            _reset_detail_edit()
        refresh_content(true)
    , "quiet", "AstryxDetailSection_" + id)
    trigger.icon = load("res://assets/ui/astryx/chevron_%s.svg" % ("up" if expanded else "down"))
    trigger.icon_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    trigger.expand_icon = true
    trigger.add_theme_constant_override("icon_max_width", 18)
    trigger.add_theme_font_size_override("font_size", 17)
    trigger.alignment = HORIZONTAL_ALIGNMENT_LEFT
    # Accordion headings share the content column's leading edge. Generic
    # button insets would shift only the title, including on hover/press.
    for state in ["normal", "hover", "pressed", "disabled"]:
        var style := trigger.get_theme_stylebox(state).duplicate() as StyleBox
        style.content_margin_left = 0
        style.content_margin_right = 0
        trigger.add_theme_stylebox_override(state, style)
    trigger.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    trigger.accessibility_name = title
    trigger.accessibility_description = _text("折叠", "Collapse", "折りたたむ") if expanded else _text("展开", "Expand", "展開")
    group.add_child(trigger)
    var body := _vbox(12)
    body.name = "AstryxDetailBody_" + id
    body.visible = expanded
    group.add_child(body)
    return body
