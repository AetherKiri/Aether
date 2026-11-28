extends VBoxContainer
## A live editor built from the active game's native modifier capabilities.

const Tools := preload("res://scripts/xsystem_tools.gd")
const Design := preload("res://scripts/ui/astryx/astryx_theme.gd")
var host
var profile: Dictionary = {}
var state: Dictionary = {}
var schema: Dictionary = {}
var _runtime := ""
var _game_path := ""
var _elapsed := 0.0
var _reporting := false
var _title: Label
var _status: Label
var _feedback: Label
var _body: VBoxContainer
var _locks: Dictionary = {}
var _gates: Array[Dictionary] = []
var _readouts: Dictionary = {}
var _editors: Array[Dictionary] = []
var _character_picker: OptionButton
var _character_form: VBoxContainer
var _character_ids: Array = []
var _characters: Array = []
var _streamer: CheckButton

func setup(owner_host) -> void:
    host = owner_host
    _runtime = String(host.active_runtime_kind)
    _game_path = String(host.selected_game.get("path", ""))
    name = "XSystemModifier"
    size_flags_horizontal = Control.SIZE_EXPAND_FILL
    size_flags_vertical = Control.SIZE_EXPAND_FILL
    add_theme_constant_override("separation", 12)
    theme = Design.new("dark" if host.ui_tokens.background.get_luminance() < 0.3 else "light").native
    var parsed = JSON.parse_string(FileAccess.get_file_as_string("res://data/xsystem_modifiers.json"))
    schema = parsed if parsed is Dictionary else {}
    var header := HBoxContainer.new()
    add_child(header)
    _title = _label(_text("修改器", "Modifier"), 22)
    header.add_child(_title)
    var done := _button(_text("完成", "Done"), func():
        stop()
        host._dismiss_modal()
    )
    done.custom_minimum_size.x = 72
    done.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    header.add_child(done)
    _status = _label(_text("正在读取游戏状态…", "Reading game state…"))
    add_child(_status)
    _feedback = _label("")
    _feedback.visible = false
    add_child(_feedback)
    var scroll := ScrollContainer.new()
    scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
    scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    add_child(scroll)
    _body = VBoxContainer.new()
    _body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _body.add_theme_constant_override("separation", 16)
    scroll.add_child(_body)
    _reporting = host.player.set_engine_option("modifier_state", "1") == 0
    if _reporting:
        _poll()
    else:
        _status.text = _text("当前构建不支持修改器。", "This build does not support the modifier.")

func _text(zh: String, en: String) -> String:
    return Tools.text(host, zh, en)

func _label(value: String, font_size := 14) -> Label:
    var label := Label.new()
    label.text = value
    label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    label.add_theme_font_size_override("font_size", font_size)
    return label

func _button(value: String, action: Callable) -> Button:
    var button := Button.new()
    button.text = value
    button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    button.custom_minimum_size.y = 44
    button.pressed.connect(action)
    return button

func _section(title: String) -> VBoxContainer:
    var box := VBoxContainer.new()
    box.add_theme_constant_override("separation", 8)
    _body.add_child(box)
    box.add_child(HSeparator.new())
    box.add_child(_label(title, 17))
    return box

func _process(delta: float) -> void:
    if not _reporting:
        return
    if not is_visible_in_tree() or not host.game_running or String(host.active_runtime_kind) != _runtime or String(host.selected_game.get("path", "")) != _game_path:
        stop()
        return
    _elapsed += delta
    if _elapsed >= 0.5:
        _elapsed = 0.0
        _poll()

func stop() -> void:
    if _reporting and is_instance_valid(host) and host.game_running and host.player != null and String(host.active_runtime_kind) == _runtime:
        host.player.set_engine_option("modifier_state", "0")
    _reporting = false

func _exit_tree() -> void:
    stop()

func _poll() -> void:
    var value = JSON.parse_string(host.player.get_plugin_debug_info())
    if not value is Dictionary:
        return
    state = value
    var id := String(state.get("game", ""))
    if id != String(profile.get("id", "")) or _body.get_child_count() == 0:
        profile = {}
        for candidate in schema.get("games", []):
            if candidate.id == id and candidate.engine == _runtime:
                profile = candidate
                break
        _build()
    _status.text = _text("当前游戏暂不支持修改器。", "The current game has no modifier profile.") if profile.is_empty() else (
        _text("修改即时生效；锁定开关会持续保持数值。", "Changes apply in game; locks keep the selected values.") if bool(state.get("inGame", false)) else _text("请先进入游戏，相关操作会自动解锁。", "Enter the game to enable the available actions."))
    for bit in _locks:
        _locks[bit].set_pressed_no_signal((int(state.get("locks", 0)) & int(bit)) != 0)
    if is_instance_valid(_streamer):
        _streamer.disabled = not bool(state.get("streamerModeSupported", false))
        _streamer.set_pressed_no_signal(bool(state.get("streamerMode", false)))
    for gate in _gates:
        if is_instance_valid(gate.control):
            gate.control.disabled = not _allowed(gate.requirement)
    for key in _readouts:
        _readouts[key].text = str(state.get(key, "—"))
    for editor in _editors:
        if not is_instance_valid(editor.input) or editor.character:
            continue
        _sync_editor(editor, state)
    _sync_characters()

func _allowed(requirement: String) -> bool:
    return requirement.is_empty() or bool(state.get(requirement, false))

func _gate(control: BaseButton, requirement := "inGame") -> void:
    control.disabled = not _allowed(requirement)
    _gates.append({"control": control, "requirement": requirement})

func _build() -> void:
    for child in _body.get_children():
        _body.remove_child(child)
        child.queue_free()
    _locks.clear()
    _gates.clear()
    _readouts.clear()
    _editors.clear()
    _character_picker = null
    _character_form = null
    _character_ids.clear()
    _characters.clear()
    _streamer = null
    _title.text = _text("修改器", "Modifier") + (" · " + String(profile.get("name", "")) if not profile.is_empty() else "")
    if profile.is_empty():
        _body.add_child(_label(_text("此游戏没有可用的修改项目。", "No modifier actions are available for this game.")))
        return
    if profile.id == "rance10":
        var streaming := _section(_text("主播模式", "Streamer mode"))
        _streamer = CheckButton.new()
        _streamer.text = _text("主播模式", "Streamer mode")
        _streamer.custom_minimum_size.y = 44
        _streamer.toggled.connect(_set_streamer)
        streaming.add_child(_streamer)
    if not profile.get("locks", []).is_empty():
        var locks := _section(_text("实时锁定", "Live locks"))
        for item in profile.locks:
            var row := HBoxContainer.new()
            locks.add_child(row)
            row.add_child(_label(item.label))
            var toggle := CheckButton.new()
            toggle.custom_minimum_size = Vector2(64, 44)
            toggle.accessibility_name = item.label
            toggle.toggled.connect(func(enabled: bool): _toggle_lock(int(item.bit), enabled))
            row.add_child(toggle)
            _locks[int(item.bit)] = toggle
        locks.add_child(_button(_text("关闭所有锁定", "Turn off all locks"), func():
            var bits := 0
            for item in profile.locks: bits |= int(item.bit)
            _set_mask(int(state.get("locks", 0)) & ~bits)
        ))
    _actions(profile.get("actions", []), _section(_text("快捷操作", "Quick actions")), "inGame")
    if not profile.get("battle_actions", []).is_empty():
        _actions(profile.battle_actions, _section(_text("战斗", "Battle")), "inBattle")
    if profile.has("resources"):
        _resource_section(String(profile.get("resource_title", _text("资源修改", "Resources"))), profile.resources, "inGame", profile.get("resource_action", {}))
    for panel in profile.get("panels", []):
        _resource_section(panel.label, panel.fields, "inBattle" if panel.get("battle", false) else "inGame")
    if profile.has("characters"):
        var characters := _section(_text("角色属性", "Character attributes"))
        _character_picker = OptionButton.new()
        _character_picker.custom_minimum_size.y = 44
        _character_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        _character_picker.fit_to_longest_item = false
        _character_picker.item_selected.connect(_select_character)
        characters.add_child(_character_picker)
        _gate(_character_picker)
        _character_form = VBoxContainer.new()
        _character_form.add_theme_constant_override("separation", 8)
        characters.add_child(_character_form)
    if not profile.get("readonly", []).is_empty():
        var readings := _section(_text("实时数值", "Live values"))
        for item in profile.readonly:
            var row := HBoxContainer.new()
            readings.add_child(row)
            row.add_child(_label(item.label))
            var value := _label("—")
            value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
            row.add_child(value)
            _readouts[item.key] = value
    if profile.get("codes", false):
        _codes()

func _actions(actions: Array, parent: Control, requirement: String) -> void:
    for item in actions:
        var button := _button(item.label, func(): _send(item.action))
        parent.add_child(button)
        var needs := requirement
        if item.action is Dictionary and (item.action.has("r01UnlockGallery") or item.action.has("r02UnlockGallery")):
            needs = ""
        elif item.action is Dictionary and item.action.has("srResetAllActions"):
            needs = "inGame"
        _gate(button, needs)

func _resource_section(title: String, fields: Array, requirement: String, quick: Dictionary = {}) -> void:
    var section := _section(title)
    var form := VBoxContainer.new()
    form.visible = false
    form.add_theme_constant_override("separation", 8)
    var expand := _button(_text("编辑数值", "Edit values"), func():
        if form.get_child_count() == 0:
            _fields(form, fields, state, {}, requirement)
            if not quick.is_empty():
                _actions([quick], form, requirement)
        form.visible = not form.visible
    )
    _gate(expand, requirement)
    section.add_child(expand)
    section.add_child(form)

func _fields(parent: Control, fields: Array, initial: Dictionary, target: Dictionary, requirement := "inGame") -> void:
    var entries: Array[Dictionary] = []
    for field in fields:
        var row := HBoxContainer.new()
        row.add_theme_constant_override("separation", 12)
        parent.add_child(row)
        row.add_child(_label(field.label))
        var input := LineEdit.new()
        input.name = "Value_" + String(field.key)
        input.custom_minimum_size = Vector2(120, 44)
        input.placeholder_text = "—"
        input.accessibility_name = field.label
        input.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_NUMBER
        input.max_length = 12
        input.set_meta("dirty", false)
        input.text_changed.connect(func(_value): input.set_meta("dirty", true))
        row.add_child(input)
        var editor := {"input": input, "field": field, "character": not target.is_empty()}
        _sync_editor(editor, initial)
        entries.append(editor)
        _editors.append(editor)
    var apply := _button(_text("应用修改", "Apply changes"), func():
        var changes := {}
        for editor in entries:
            if not editor.input.get_meta("dirty", false):
                continue
            var value: String = editor.input.text.strip_edges()
            if not value.is_valid_int() or int(value) < -2147483648 or int(value) > 2147483647:
                _notice(_text("请输入有效整数（−2147483648 至 2147483647）。", "Enter an integer from −2147483648 to 2147483647."))
                return
            changes[editor.field.key] = int(value)
        if changes.is_empty():
            _notice(_text("请先修改需要调整的数值。", "Change a value before applying."))
            return
        _send(_character_action(target, changes) if not target.is_empty() else changes)
        for editor in entries:
            editor.input.set_meta("dirty", false)
    )
    _gate(apply, requirement)
    parent.add_child(apply)

func _sync_editor(editor: Dictionary, values: Dictionary) -> void:
    if not editor.input.has_focus() and not editor.input.get_meta("dirty", false):
        editor.input.text = str(values[editor.field.state]) if values.has(editor.field.state) else ""

func _sync_characters() -> void:
    if not is_instance_valid(_character_picker):
        return
    var prefix: String = profile.characters.prefix
    var rows: Array = state.get(prefix + "Characters", [])
    var characters: Array = []
    var ids: Array = []
    for row in rows:
        var index := int(row.get("charIdx" if prefix == "sr" else "index", -1))
        if index < 0 or (prefix == "sr" and not row.has("factionIdx")):
            continue
        var target := {"charIdx" if prefix == "sr" else "target": index}
        if prefix == "sr": target["factionIdx"] = int(row.factionIdx)
        characters.append({"target": target, "state": row, "name": String(row.get("name", "#%d" % index))})
        ids.append(target)
    if not characters.is_empty():
        var all_target: Dictionary = characters[0].target.duplicate()
        all_target["charIdx" if prefix == "sr" else "target"] = -1
        characters.push_front({"target": all_target, "state": {}, "name": _text("全体角色", "All characters")})
        ids.push_front(all_target)
    _characters = characters
    if ids != _character_ids:
        var selected: Dictionary = _character_ids[_character_picker.selected] if _character_picker.selected >= 0 and _character_picker.selected < _character_ids.size() else {}
        _character_ids = ids
        _character_picker.clear()
        for character in characters:
            _character_picker.add_item(character.name)
        if characters.is_empty():
            _character_picker.add_item(_text("暂无角色数据", "No character data yet"))
        _character_picker.select(maxi(0, ids.find(selected)))
        _select_character(_character_picker.selected)
    _character_picker.disabled = characters.is_empty() or not bool(state.get("inGame", false))
    if _character_picker.selected >= 0 and _character_picker.selected < characters.size():
        for editor in _editors:
            if is_instance_valid(editor.input) and editor.character:
                _sync_editor(editor, characters[_character_picker.selected].state)

func _select_character(index: int) -> void:
    _gates = _gates.filter(func(item): return is_instance_valid(item.control) and not _character_form.is_ancestor_of(item.control))
    for child in _character_form.get_children():
        _character_form.remove_child(child)
        child.queue_free()
    _editors = _editors.filter(func(item): return not item.character)
    if index < 0 or index >= _characters.size():
        return
    var character: Dictionary = _characters[index]
    _fields(_character_form, profile.characters.fields, character.state, character.target)
    var boost := _button(_text("一键强化", "Boost attributes"), func(): _send(_character_action(character.target, profile.characters.boost)))
    _gate(boost)
    _character_form.add_child(boost)

func _character_action(target: Dictionary, values: Dictionary) -> Dictionary:
    var payload := values.duplicate()
    if profile.characters.prefix == "sr" and payload.has("resetAction"):
        payload.resetAction = int(payload.resetAction) != 0
    payload.merge(target, true)
    return {String(profile.characters.prefix) + "CharEdit": payload}

func _toggle_lock(bit: int, enabled: bool) -> void:
    var mask := int(state.get("locks", 0))
    _set_mask((mask | bit) if enabled else (mask & ~bit))

func _set_mask(mask: int) -> void:
    var key := "modifier_lock_mask" if _runtime == "xsystem35" else "modifier_lock_mask." + String(profile.id)
    if host.player.set_engine_option(key, str(mask)) == 0:
        state["locks"] = mask
    else:
        _notice(_text("锁定设置未成功，请重试。", "Could not change the lock. Try again."))

func _set_streamer(enabled: bool) -> void:
    _toggle_lock(1 << 11, not enabled)
    _send({"streamerMode": 1} if enabled else {"streamerMode": 0, "streamerPopup": true})

func _send(action) -> void:
    if not _reporting or not host.game_running:
        return
    if profile.get("id", "") == "rance10" and action is Dictionary and action.get("perFindTreasure", 0) == 999:
        _toggle_lock(1 << 10, true)
    var payload: String = action if action is String else JSON.stringify(action)
    var result: int = host.player.set_engine_option("modifier_action", payload)
    _notice(_text("操作已提交，返回游戏后查看效果。", "Action submitted. Return to the game to see the result.") if result == 0 else _text("操作未成功，请确认游戏状态后重试。", "Action failed. Check the game state and try again."))
    _elapsed = 0.4

func _notice(message: String) -> void:
    _feedback.text = message
    _feedback.visible = true

func _codes() -> void:
    var section := _section(_text("作弊码", "Cheat codes"))
    var code := LineEdit.new()
    code.placeholder_text = "whosyourdaddy / 餐券10"
    code.custom_minimum_size.y = 44
    section.add_child(code)
    var presets := OptionButton.new()
    presets.custom_minimum_size.y = 44
    presets.fit_to_longest_item = false
    presets.add_item(_text("常用作弊码…", "Common cheat codes…"))
    for item in schema.get("codes", []): presets.add_item(item.label)
    presets.item_selected.connect(func(index: int):
        if index > 0: code.text = String(schema.codes[index - 1].code)
    )
    section.add_child(presets)
    var execute := func():
        var value := code.text.strip_edges().trim_prefix('"').trim_suffix('"').strip_edges()
        if value.is_empty():
            _notice(_text("请输入作弊码。", "Enter a cheat code."))
        elif value in ["关闭主播模式", "灌注Eins陈谢谢喵", "关注Eins陈谢谢喵"]:
            _set_streamer(false)
        elif value == "开启主播模式":
            _set_streamer(true)
        else:
            _send({"cheatCode": value})
    code.text_submitted.connect(func(_value): execute.call())
    section.add_child(_button(_text("执行", "Run"), execute))
