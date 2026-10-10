extends RefCounted

# macOS native menu bar integration through Godot's NativeMenu API.
#
# The module owns the global menu bar lifecycle and mirrors shell state
# (running game, fullscreen mode) into item enablement and check marks. It
# stays inert on platforms without a native global menu, so the desktop and
# mobile shells keep the existing in-window navigation only. All labels flow
# through the host translator, so the menu follows the in-app language.
#
# Host contract:
#   translate      -> Callable(key: String) -> String
#   state_provider -> Callable() -> Dictionary {game_running: bool, fullscreen: bool}
#   actions        -> Dictionary of action key -> Callable

var _host: Node = null
var _translate: Callable
var _state_provider: Callable
var _actions: Dictionary = {}
var _menu = null

var _main_menu_rid := RID()
var _application_menu_rid := RID()
var _help_menu_rid := RID()
var _file_menu_rid := RID()
var _view_menu_rid := RID()
var _game_menu_rid := RID()

# Submenu registry: key -> {"parent": RID, "index": int, "rid": RID, "label_key": String}
var _submenus: Dictionary = {}
# Item registry: key -> {"rid": RID, "index": int, "label_key": String, "ellipsis": bool}
var _items: Dictionary = {}

func is_supported() -> bool:
    if OS.get_name() != "macOS":
        return false
    return Engine.has_singleton("NativeMenu")

func setup(host: Node, translate: Callable, state_provider: Callable, actions: Dictionary) -> bool:
    if not is_supported():
        return false
    _host = host
    _translate = translate
    _state_provider = state_provider
    _actions = actions
    var menu = Engine.get_singleton("NativeMenu")
    if menu == null or not menu.has_feature(NativeMenu.FEATURE_GLOBAL_MENU):
        _log("native menu unavailable (global menu feature disabled)")
        return false
    _menu = menu
    _build()
    refresh_state()
    return true

func refresh_state() -> void:
    if _menu == null:
        return
    var state: Dictionary = {}
    if _state_provider.is_valid():
        state = _state_provider.call()
    var game_running := bool(state.get("game_running", false))
    var fullscreen := bool(state.get("fullscreen", false))
    var shell_enabled := not game_running
    _set_disabled("preferences", not shell_enabled)
    _set_disabled("import", not shell_enabled)
    _set_disabled("refresh", not shell_enabled)
    _set_disabled("library", not shell_enabled)
    _set_disabled("videos", not shell_enabled)
    _set_disabled("dashboard", not shell_enabled)
    _set_disabled("back_to_library", not game_running)
    _set_checked("fullscreen", fullscreen)

func retranslate() -> void:
    if _menu == null:
        return
    for key in _submenus:
        var submenu: Dictionary = _submenus[key]
        _menu.set_item_text(submenu["parent"], int(submenu["index"]), _t(String(submenu["label_key"])))
    for key in _items:
        var item: Dictionary = _items[key]
        var label := _t(String(item["label_key"]))
        if bool(item.get("ellipsis", false)):
            label += "…"
        _menu.set_item_text(item["rid"], int(item["index"]), label)

func _t(key: String) -> String:
    if not _translate.is_valid():
        return key
    return String(_translate.call(key))

func _invoke(action_key: String) -> void:
    _log("menu action=%s" % action_key)
    var action: Callable = _actions.get(action_key, Callable())
    if action.is_valid():
        action.call()

func _build() -> void:
    _main_menu_rid = _menu.get_system_menu(NativeMenu.MAIN_MENU_ID)
    _application_menu_rid = _menu.get_system_menu(NativeMenu.APPLICATION_MENU_ID)
    _help_menu_rid = _menu.get_system_menu(NativeMenu.HELP_MENU_ID)

    _file_menu_rid = _menu.create_menu()
    _view_menu_rid = _menu.create_menu()
    _game_menu_rid = _menu.create_menu()

    if _main_menu_rid.is_valid():
        _add_submenu("file", _main_menu_rid, "menu.file", _file_menu_rid)
        _add_submenu("view", _main_menu_rid, "menu.view", _view_menu_rid)
        _add_submenu("game", _main_menu_rid, "menu.game", _game_menu_rid)

    if _application_menu_rid.is_valid():
        _add_item("preferences", _application_menu_rid, "settings.title", true,
            "settings", KEY_MASK_CMD_OR_CTRL | KEY_COMMA)
        _menu.add_separator(_application_menu_rid)

    _add_item("import", _file_menu_rid, "home.import", true,
        "import", KEY_MASK_CMD_OR_CTRL | KEY_O)
    _add_item("refresh", _file_menu_rid, "home.refresh", false,
        "refresh", KEY_MASK_CMD_OR_CTRL | KEY_R)

    _add_item("library", _view_menu_rid, "nav.library", false,
        "library", KEY_MASK_CMD_OR_CTRL | KEY_1)
    _add_item("videos", _view_menu_rid, "nav.videos", false,
        "videos", KEY_MASK_CMD_OR_CTRL | KEY_2)
    _add_item("dashboard", _view_menu_rid, "nav.dashboard", false,
        "dashboard", KEY_MASK_CMD_OR_CTRL | KEY_3)
    _menu.add_separator(_view_menu_rid)
    _add_check_item("fullscreen", _view_menu_rid, "menu.fullscreen", "fullscreen",
        KEY_MASK_CTRL | KEY_MASK_CMD_OR_CTRL | KEY_F)

    _add_item("back_to_library", _game_menu_rid, "menu.back_to_library", false,
        "back_to_library", 0)

    if _help_menu_rid.is_valid():
        _add_item("qq_group", _help_menu_rid, "settings.qq_group", false,
            "qq_group", 0)

    _log("native menu ready submenus=%d items=%d app_menu_items=%d" % [
        _submenus.size(),
        _items.size(),
        _menu.get_item_count(_application_menu_rid),
    ])

func _add_submenu(key: String, parent: RID, label_key: String, rid: RID) -> void:
    var index: int = _menu.add_submenu_item(parent, _t(label_key), rid)
    if index < 0:
        return
    _submenus[key] = {
        "parent": parent,
        "index": index,
        "rid": rid,
        "label_key": label_key,
    }

func _add_item(
    key: String,
    rid: RID,
    label_key: String,
    ellipsis: bool,
    action_key: String,
    accelerator: int
) -> void:
    var label := _t(label_key)
    if ellipsis:
        label += "…"
    var callback := func(_tag = null): _invoke(action_key)
    var index: int = _menu.add_item(rid, label, callback)
    if index < 0:
        return
    if accelerator != 0:
        _menu.set_item_accelerator(rid, index, accelerator)
    _items[key] = {
        "rid": rid,
        "index": index,
        "label_key": label_key,
        "ellipsis": ellipsis,
    }

func _add_check_item(
    key: String,
    rid: RID,
    label_key: String,
    action_key: String,
    accelerator: int
) -> void:
    var callback := func(_tag = null): _invoke(action_key)
    var index: int = _menu.add_check_item(rid, _t(label_key), callback)
    if index < 0:
        return
    if accelerator != 0:
        _menu.set_item_accelerator(rid, index, accelerator)
    _items[key] = {
        "rid": rid,
        "index": index,
        "label_key": label_key,
        "ellipsis": false,
    }

func _set_disabled(key: String, disabled: bool) -> void:
    var item: Dictionary = _items.get(key, {})
    if item.is_empty():
        return
    _menu.set_item_disabled(item["rid"], int(item["index"]), disabled)

func _set_checked(key: String, checked: bool) -> void:
    var item: Dictionary = _items.get(key, {})
    if item.is_empty():
        return
    _menu.set_item_checked(item["rid"], int(item["index"]), checked)

func _log(line: String) -> void:
    if not OS.is_debug_build():
        return
    print(line)
    if _host != null and _host.has_method("_append_log"):
        _host._append_log(line)
