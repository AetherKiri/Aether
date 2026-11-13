extends Node
## Optional shell presenter. Runtime, library, import and settings remain owned by main.gd.
## This node survives the classic shell's style rebuilds; no classic view is reparented.
const VIEW := preload("res://scripts/ui/astryx/astryx_shell.gd")
const PREFERENCES := "user://astryx_shell.cfg"
var host
var enabled := false
var theme_mode := "light"
var draft_theme := "light"
var library_display := "cards"
var view: Control
var backdrop: ColorRect
var elapsed := 0.0
var state_signature := ""

func _ready() -> void:
    host = get_parent()
    load_preferences()
    set_process(false)
    host.ready.connect(_attach, CONNECT_ONE_SHOT)

func load_preferences(path: String = PREFERENCES) -> void:
    var config := ConfigFile.new()
    if config.load(path) == OK:
        enabled = String(config.get_value("shell", "interface", "classic")) == "astryx"
        theme_mode = String(config.get_value("shell", "theme", "light"))
        library_display = String(config.get_value("shell", "library_display", "cards"))
    if theme_mode not in ["light", "dark"]:
        theme_mode = "light"
    draft_theme = theme_mode
    if library_display not in ["cards", "list"]:
        library_display = "cards"

func save_preferences(path: String = PREFERENCES) -> Error:
    var config := ConfigFile.new()
    config.set_value("shell", "interface", "astryx" if enabled else "classic")
    config.set_value("shell", "theme", theme_mode)
    config.set_value("shell", "library_display", library_display)
    return config.save(path)

func set_library_display(value: String) -> void:
    if value not in ["cards", "list"] or value == library_display:
        return
    var previous := library_display
    library_display = value
    if save_preferences() != OK:
        library_display = previous
        view.show_notice(text("展示方式保存失败，请重试。", "Could not save display preference. Try again.", "表示設定を保存できませんでした。"))
        return
    view.rebuild()

func _attach() -> void:
    set_process(true)
    if enabled:
        _ensure_view()

func _ensure_view() -> void:
    if not is_instance_valid(host.shell_root):
        return
    if not is_instance_valid(backdrop):
        backdrop = ColorRect.new()
        backdrop.name = "AstryxBackdrop"
        backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
        backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
        host.add_child(backdrop)
    if backdrop.get_index() != host.shell_root.get_index() - 1:
        host.move_child(backdrop, host.shell_root.get_index() - (1 if backdrop.get_index() < host.shell_root.get_index() else 0))
    if not is_instance_valid(view):
        view = VIEW.new()
        view.name = "AstryxShell"
        view.setup(self)
        host.shell_root.add_child(view)
        state_signature = ""
    view.visible = enabled
    _hide_classic_chrome()

func _hide_classic_chrome() -> void:
    for control in [host.shell_content, host.shell_sidebar, host.shell_compact_header, host.shell_compact_topbar, host.shell_safe_top_fill]:
        if is_instance_valid(control):
            control.hide()

func _process(delta: float) -> void:
    if not enabled:
        return
    _ensure_view()
    if not is_instance_valid(view):
        return
    backdrop.visible = host.shell_root.visible
    backdrop.color = view.design.color("surface" if view.phone else "canvas")
    elapsed += delta
    if elapsed < 0.15:
        return
    elapsed = 0.0
    var signature := "%s:%s:%s:%s:%s:%s:%s" % [host.shell_route, host.active_language,
        host.known_games.hash(), host.selected_game.hash(), host._active_file_library().entries.hash(),
        host._active_file_library().current_directory, host.settings_draft.hash()]
    if signature != state_signature:
        state_signature = signature
        view.sync_state()
    view.sync_dirty_state()

func mount_classic_switch(rows: Control) -> void:
    var row: Control = host._settings_action_row(
        text("界面版本", "Interface", "インターフェイス"),
        text("试用 Astryx 界面，随时可以切回。", "Try Astryx. Switch back at any time.", "Astryx を試す。いつでも元に戻せます。"),
        text("切换到 Astryx", "Switch to Astryx", "Astryx に切り替える"),
        func():
            if not host._request_settings_navigation(Callable(self, "set_enabled").bind(true)):
                set_enabled(true)
    )
    row.name = "ShellInterfaceSwitch"
    host._add_settings_row(rows, row)

func set_enabled(value: bool, persist: bool = true) -> void:
    enabled = value
    draft_theme = theme_mode
    host._reset_shell_scroll_drag()
    if enabled:
        if host.shell_route == "settings":
            host._begin_settings_edit()
        _ensure_view()
        view.rebuild()
    else:
        if is_instance_valid(view):
            view.hide()
        if is_instance_valid(backdrop):
            backdrop.hide()
        host.shell_content.show()
        host._fit_full_rects()
        if host.shell_route == "settings":
            host._begin_settings_edit()
            host._rebuild_settings_view()
    if persist and save_preferences() != OK:
        push_warning("Could not save shell interface preference")

func is_dirty() -> bool:
    return bool(host.dirty_settings) or draft_theme != theme_mode

func request_navigation(destination: Callable) -> bool:
    if host.shell_route != "settings" or not is_dirty():
        return false
    view.confirm_navigation(destination)
    return true

func save_settings() -> bool:
    var previous := theme_mode
    theme_mode = draft_theme
    if save_preferences() != OK:
        view.show_notice(text("界面偏好保存失败，请重试。", "Could not save interface preferences. Try again.", "設定を保存できませんでした。"))
        theme_mode = previous
        return false
    host._save_settings_draft()
    host._begin_settings_edit()
    view.rebuild(true)
    view.show_notice(text("更改已保存", "Changes saved", "変更を保存しました"))
    return true

func discard_settings() -> void:
    draft_theme = theme_mode
    host._begin_settings_edit()
    view.rebuild(true)

func text(zh: String, en: String, ja: String = "") -> String:
    match String(host.active_language):
        "zh_hans", "zh_hant": return zh
        "ja": return ja if not ja.is_empty() else en
        _: return en
