extends SceneTree
## Exercise the optional presenter against real host navigation and library models.
## All persistence and media fixtures live in a temporary directory.
const Library := preload("res://scripts/video_library.gd")

class TestHost:
    extends "res://scripts/main.gd"
    var launched := false
    var opened_video := ""
    var cover_picker_opened := false
    var launch_picker_opened := false
    var cover_cleared := false
    var removal_requested := ""
    var game_removal_requested := ""
    var text_runtime := ""
    var font_callback := Callable()
    func _game_runtime_kind(path: String) -> String:
        return text_runtime if not text_runtime.is_empty() else super._game_runtime_kind(path)
    func _choose_game_font(callback: Callable) -> void:
        font_callback = callback
    func _ready() -> void:
        ui_motion.reduced_motion = true
        add_child(ui_motion)
        _apply_ui_font()
        _build_ui()
        _refresh_games()
    func _process(_delta: float) -> void:
        pass
    func _refresh_games() -> void:
        _rebuild_game_cards()
    func _save_shell_settings() -> void:
        dirty_settings = false
    func _start_selected_game() -> void:
        launched = true
    func _open_video_player(item: Dictionary) -> void:
        opened_video = String(item.path)
    func _confirm_remove_video(item: Dictionary) -> void:
        removal_requested = String(item.path)
        super._confirm_remove_video(item)
    func _confirm_remove_selected() -> void:
        game_removal_requested = String(selected_game.path)
        super._confirm_remove_selected()
    func _update_game(path: String, values: Dictionary) -> void:
        # Exercise inline renaming without writing the shared game list.
        for game in known_games:
            if String(game.path) == path:
                game.merge(values, true)
                selected_game = game
                break
        _refresh_games()
    func _set_cover_for_selected() -> void:
        cover_picker_opened = true
    func _set_launch_file_for_selected() -> void:
        launch_picker_opened = true
    func _clear_cover_for_selected() -> void:
        # The host action also writes the shared user:// cover index. Keep this
        # presenter test in memory while verifying delegation and the new state.
        cover_cleared = true
        selected_game["coverPath"] = ""
        selected_game[GAME_AUTO_COVER_SCANNED_FIELD] = true
        _show_detail(selected_game)

class TestController:
    extends "res://scripts/ui/astryx/shell_interface.gd"
    var preference_path := ""
    func load_preferences(_path: String = "") -> void:
        super.load_preferences(preference_path)
    func save_preferences(_path: String = "") -> Error:
        return super.save_preferences(preference_path)

var failures := 0
var app: TestHost
var controller: TestController
var fixture: DirAccess

func _initialize() -> void:
    call_deferred("_run")

func _expect(value: bool, message: String) -> void:
    if not value:
        failures += 1
        push_error(message)

func _settle() -> void:
    await create_timer(0.25).timeout
    controller._process(0.2)
    for _frame in range(4):
        await process_frame

func _button(name_value: String) -> Button:
    var button := app.find_child(name_value, true, false) as Button
    _expect(button != null, "Missing control: " + name_value)
    return button

func _click(name_value: String) -> void:
    var button := _button(name_value)
    if button != null:
        button.pressed.emit()
    await _settle()

func _pointer_click(name_value: String) -> void:
    var position := _button(name_value).get_global_rect().get_center()
    var motion := InputEventMouseMotion.new()
    motion.position = position
    root.push_input(motion)
    var press := InputEventMouseButton.new()
    press.position = position
    press.button_index = MOUSE_BUTTON_LEFT
    press.pressed = true
    root.push_input(press)
    press.pressed = false
    root.push_input(press)
    await _settle()

func _check_tab_hover(name_value: String) -> void:
    var button := _button(name_value)
    var motion := InputEventMouseMotion.new()
    motion.position = button.get_global_rect().get_center()
    motion.global_position = motion.position
    root.push_input(motion)
    await process_frame
    _expect(button.is_hovered(), "Library tab receives pointer hover")
    var text_width := button.get_theme_font("font").get_string_size(
        button.text, HORIZONTAL_ALIGNMENT_LEFT, -1, button.get_theme_font_size("font_size")
    ).x
    for state in ["normal", "hover", "pressed"]:
        var available := button.size.x - button.get_theme_stylebox(state).get_minimum_size().x
        _expect(available >= text_width, "%s %s clips its final character" % [button.text, state])

func _check_scrollbar() -> void:
    var scroll: ScrollContainer = controller.view.scroll
    var bar := scroll.get_v_scroll_bar()
    _expect(bar.max_value > bar.page and bar.is_visible_in_tree(), "Overflow exposes a scrollbar")
    _expect(bar.size.x >= 8, "The scrollbar has a visible, draggable width")
    _expect(bar.get_global_rect().end.x <= controller.view.size.x + 1, "Scrollbar stays inside the page")

func _check_header_heights() -> void:
    var display: Control = controller.view.find_child("AstryxLibraryDisplay", true, false)
    var import_button := _button("AstryxImport")
    _expect(is_equal_approx(display.size.y, import_button.size.y), "Display switch and Import have matching heights")
    _expect(is_equal_approx(display.global_position.y, import_button.global_position.y), "Header actions align vertically")
    for mode in ["cards", "list"]:
        var segment := _button("AstryxDisplay_" + mode)
        _expect(is_equal_approx(segment.size.y, import_button.size.y), "The visible %s button matches Import, not just its outer track" % mode)
        _expect(is_equal_approx(segment.global_position.y, import_button.global_position.y), "The visible %s button aligns with Import" % mode)

func _check_settings_geometry() -> void:
    var view: Control = controller.view
    var detail: Control = view.find_child("AstryxSettingsDetail", true, false)
    _expect(detail != null, "Settings detail is present")
    _expect(view.get_global_rect().grow(1).encloses(detail.get_global_rect()), "Settings detail fits the viewport")
    var content: Control = view.content
    for label in view.find_children("AstryxSettingLabel_*", "Label", true, false):
        _expect(is_equal_approx(label.global_position.x, content.global_position.x), "Setting labels align to one content column")
    for editor in view.find_children("AstryxSettingEditor_*", "VBoxContainer", true, false):
        if editor.is_visible_in_tree():
            _expect(editor.get_global_rect().end.x <= detail.get_global_rect().end.x, "Expanded setting controls stay inside the pane")
    var menu: Control = view.find_child("AstryxSettingsMenu", true, false)
    if menu != null:
        var previous: Control
        for category in ["interface", "render", "compatibility", "diagnostics", "about"]:
            var item := _button("AstryxSection_" + category)
            if previous != null:
                _expect(item.global_position.y - previous.get_global_rect().end.y >= 7.5, "Settings selection and hover backgrounds stay separated")
            previous = item
    if menu != null and not view.settings_narrow:
        _expect(menu.get_global_rect().end.x <= detail.global_position.x, "Sidebar and settings never overlap")
        _expect(detail.size.x >= 420, "Two-pane settings leave room for readable controls")

func _select_value(name_value: String, value: String) -> void:
    var picker := controller.view.find_child(name_value, true, false) as OptionButton
    _expect(picker != null and picker.is_visible_in_tree(), "Visible selector: " + name_value)
    for index in range(picker.item_count):
        if String(picker.get_item_metadata(index)) == value:
            picker.select(index)
            picker.item_selected.emit(index)
            await _settle()
            return
    _expect(false, "Missing selector option: " + value)

func _check_notice(message: String, single_line: bool = true) -> void:
    var view: Control = controller.view
    var toast: Control = view.find_child("AstryxNotice", true, false)
    _expect(toast != null, "Saving presents a non-blocking notification")
    if toast == null:
        return
    var label: Label = toast.find_child("AstryxNoticeMessage", true, false)
    var close := _button("AstryxDismissNotice")
    _expect(label.text == message, "Save feedback uses the newly applied language")
    if single_line:
        _expect(label.get_line_count() == 1, "Short save feedback stays horizontal in every language")
    _expect(toast.size.x > 300 and toast.size.y < 120, "Feedback is a horizontal card, not a narrow column")
    _expect(view.get_global_rect().grow(-15).encloses(toast.get_global_rect()), "Notification keeps viewport gutters")
    _expect(label.get_global_rect().end.x + 11 <= close.global_position.x, "Notification text leaves room for dismissal")
    _expect(toast.get_global_rect().encloses(label.get_global_rect()), "Notification text fits its surface")
    var navigation: Control = view.find_child("AstryxBottomNav", true, false)
    if navigation != null:
        _expect(toast.get_global_rect().end.y + 15 <= navigation.global_position.y, "Phone notification clears the bottom navigation")
    _expect(not view.settings_footer.visible and not controller.is_dirty(), "A successful save removes the unsaved actions")

func _exercise_saved_notice() -> void:
    var cases := [
        [Vector2i(1194, 834), "light", "ja", "変更を保存しました", "ipad"],
        [Vector2i(834, 1194), "light", "en", "Changes saved", "ipad-portrait"],
        [Vector2i(393, 852), "dark", "zh_hans", "更改已保存", "iphone"],
    ]
    for sample in cases:
        root.size = sample[0]
        app._fit_full_rects()
        controller.draft_theme = sample[1]
        controller.view.rebuild(true)
        await _settle()
        if controller.view.settings_narrow and not controller.view.settings_detail:
            await _click("AstryxSection_interface")
        if controller.view.editing_setting != "language":
            await _click("AstryxEdit_language")
        await _select_value("AstryxSetting_language", sample[2])
        await _click("AstryxSaveSettings")
        _expect(app.active_language == sample[2], "Language save applies the host preference")
        _check_notice(sample[3])
        await _capture("astryx-godot-%s-saved-notice" % sample[4])
        if sample[4] != "iphone":
            await _click("AstryxDismissNotice")
            _expect(controller.view.find_child("AstryxNotice", true, false) == null, "Notification can be dismissed immediately")
    # The same card also carries longer failure messages without overflowing.
    var long_message := "Could not save interface preferences. Try again."
    controller.view.show_notice(long_message)
    await _settle()
    _check_notice(long_message, false)
    _expect(controller.view.find_children("AstryxNotice", "PanelContainer", true, false).size() == 1, "A new notice replaces the previous one")
    var motion := InputEventMouseMotion.new()
    motion.position = Vector2(20, 20)
    root.push_input(motion)
    await create_timer(5.3).timeout
    _expect(controller.view.find_child("AstryxNotice", true, false) == null, "Notification dismisses itself after the reading interval")
    controller.draft_theme = "light"
    controller.save_settings()
    controller.view._dismiss_notice()
    root.size = Vector2i(1194, 834)
    app._fit_full_rects()
    await _settle()

func _check_custom_spacing() -> void:
    var view: Control = controller.view
    var steps := view.find_children("AstryxCustomStep_*", "VBoxContainer", true, false)
    var previous: Control
    for step in steps:
        if previous != null:
            _expect(step.global_position.y - previous.get_global_rect().end.y >= 15, "Custom algorithm rows have separate touch targets")
        _expect(step.get_global_rect().end.x <= view.scroll.get_global_rect().end.x, "Custom algorithms fit the settings pane")
        previous = step
    var add := _button("AstryxAddCustomStep")
    if previous != null:
        _expect(add.global_position.y - previous.get_global_rect().end.y >= 15, "Add action is separated from the last algorithm")

func _check_about_rows() -> void:
    var view: Control = controller.view
    for row in view.find_children("AstryxAboutRow_*", "MarginContainer", true, false):
        var copy: Control = row.find_child("Description", true, false)
        var action: Control = row.find_child("AstryxAbout_*", true, false)
        _expect(copy.get_global_rect().end.x + 15 <= action.global_position.x, "About descriptions and actions do not collide")
        _expect(is_equal_approx(copy.global_position.x, view.content.global_position.x), "About descriptions share the content leading edge")
        _expect(absf(action.get_global_rect().end.x - view.content.get_global_rect().end.x) <= 1, "About values and actions align to the trailing edge")
    if app._iap_supported_platform():
        _expect(_button("AstryxAbout_purchase_library").disabled, "An unavailable IAP remains disabled after moving its control")
        _expect(_button("AstryxAbout_purchase_library").pressed.get_connections().size() == 1, "The host purchase callback survives moving its control")

func _exercise_additional_settings() -> void:
    var original_chain: PackedStringArray = app._settings_draft_custom_chain().duplicate()
    await _click("AstryxSection_render")
    await _click("AstryxEdit_frame_enhancement_kind")
    await _select_value("AstryxSetting_frame_enhancement_kind", "custom")
    await _select_value("AstryxCustomAlgorithm_0", "lanczos")
    _expect(app._settings_draft_custom_chain()[0] == "lanczos", "Custom selector updates the real draft")
    await _click("AstryxAddCustomStep")
    _expect(app._settings_draft_custom_chain().size() == original_chain.size() + 1, "Adding creates a real draft step")
    await _click("AstryxRemoveCustomStep_1")
    _expect(app._settings_draft_custom_chain()[1] == original_chain[2], "Removing a step preserves the order of the remaining algorithms")
    var layouts := [Vector2i(1194, 834), Vector2i(834, 1194), Vector2i(393, 852)]
    var names := ["ipad", "ipad-portrait", "iphone"]
    for index in range(layouts.size()):
        root.size = layouts[index]
        app._fit_full_rects()
        await _settle()
        _check_settings_geometry()
        _check_custom_spacing()
        var chain: Control = controller.view.find_child("AstryxCustomChain", true, false)
        controller.view.scroll.scroll_vertical += int(chain.global_position.y - controller.view.scroll.global_position.y - 16)
        await _capture("astryx-godot-%s-custom" % names[index])
    await _click("AstryxCancelSettings")
    _expect(app._settings_draft_custom_chain() == original_chain, "Cancel restores the whole custom processing chain")
    await _click("AstryxSettingsBack")
    await _click("AstryxSection_about")
    for index in range(layouts.size()):
        root.size = layouts[index]
        app._fit_full_rects()
        await _settle()
        controller.view.scroll.scroll_vertical = 0
        _check_settings_geometry()
        _check_about_rows()
        await _capture("astryx-godot-%s-about" % names[index])
    root.size = Vector2i(1194, 834)
    app._fit_full_rects()
    await _settle()
    await _click("AstryxSection_interface")

func _check_detail_actions() -> void:
    var row: Control = controller.view.find_child("AstryxLaunchFileRow", true, false)
    var copy: Control = row.find_child("Description", true, false)
    var setting := _button("AstryxSetLaunchFile")
    var information: Control = controller.view.find_child("AstryxDetailBody_information", true, false)
    _expect(information.is_ancestor_of(setting), "Launch-file changes belong to Game information")
    _expect(setting.global_position.x - copy.get_global_rect().end.x >= 15, "Launch-file copy and action do not collide")
    _expect(is_equal_approx(setting.get_global_rect().end.x, row.get_global_rect().end.x), "Launch-file Set action aligns right")
    var actions: Control = controller.view.find_child("AstryxCoverActions", true, false)
    var body: Control = controller.view.find_child("AstryxDetailBody_cover", true, false)
    var path: Label = controller.view.find_child("AstryxCoverPath", true, false)
    var expected_path: String = app._resolve_cover_path(app.selected_game)
    _expect(path.text == (expected_path if not expected_path.is_empty() else "未设置封面"), "Cover location reflects the assigned file or empty state")
    _expect(path.max_lines_visible == 1 and body.get_global_rect().encloses(path.get_global_rect()), "A long cover path stays in one bounded row")
    var set_cover := _button("AstryxSetCover")
    _expect(actions.get_global_rect().encloses(set_cover.get_global_rect()), "Cover Set button fits its section")
    _expect(is_equal_approx(set_cover.size.x, body.size.x), "Set Cover fills the content width")
    _expect(set_cover.global_position.y - path.get_global_rect().end.y >= 11, "Cover location has space above the actions")
    var clear: Button = controller.view.find_child("AstryxClearCover", true, false)
    if clear != null:
        _expect(clear.global_position.y - set_cover.get_global_rect().end.y >= 11, "Cover actions occupy separate rows with spacing")
        _expect(is_equal_approx(clear.size.x, body.size.x), "Clear Cover fills the content width")
        _expect(clear.get_theme_stylebox("normal").bg_color != set_cover.get_theme_stylebox("normal").bg_color, "Set and Clear have distinct semantic colors")
        _expect(is_equal_approx(clear.size.y, set_cover.size.y), "Cover action heights match")
        _expect(actions.get_global_rect().encloses(clear.get_global_rect()), "Cover Clear button fits its section")
        _expect(actions.get_child_count() == 2, "A configured cover exposes Set and Clear")
    else:
        _expect(actions.get_child_count() == 1, "An unset cover exposes only Set")

func _check_detail_geometry() -> void:
    var scroll: ScrollContainer = controller.view.scroll
    scroll.scroll_vertical = 0
    await process_frame
    var cover: Control = controller.view.find_child("AstryxDetailCover", true, false)
    _expect(scroll.get_global_rect().grow(1).encloses(cover.get_global_rect()), "The complete detail cover fits the initial viewport")
    var artwork := cover.find_child("CoverImage", true, false) as TextureRect
    if artwork != null:
        _expect(artwork.stretch_mode == TextureRect.STRETCH_KEEP_ASPECT_CENTERED, "Detail artwork remains fully visible without cropping")
        var ratio := artwork.texture.get_size().aspect()
        _expect(absf(cover.size.x - cover.size.y * ratio) <= 1.0, "The frame follows the source ratio without letterboxing")
        _expect(artwork.size.is_equal_approx(cover.size), "Artwork fills the entire detail frame")
        _expect(cover.get_theme_stylebox("panel") is StyleBoxEmpty, "Artwork has no gray backing panel")
        if ratio >= 1.0:
            _expect(absf(cover.size.x - cover.get_parent().size.x) <= 1.0, "Landscape artwork fills the gallery width")
    var back := _button("AstryxDetailBack")
    var label_width := back.get_theme_font("font").get_string_size(back.text, HORIZONTAL_ALIGNMENT_LEFT, -1, back.get_theme_font_size("font_size")).x
    var arrow_space := back.size.x - back.get_theme_stylebox("normal").get_minimum_size().x - label_width - back.get_theme_constant("h_separation")
    _expect(back.icon != null and arrow_space >= 20, "The back button reserves visible space for its left arrow")
    for section in ["information", "rendering", "cover"]:
        var trigger := _button("AstryxDetailSection_" + section)
        var body: Control = controller.view.find_child("AstryxDetailBody_" + section, true, false)
        if not body.visible:
            continue
        for state in ["normal", "hover", "pressed"]:
            var title_x := trigger.global_position.x + trigger.get_theme_stylebox(state).get_margin(SIDE_LEFT)
            _expect(is_equal_approx(title_x, body.global_position.x), "%s title aligns with its content in %s state" % [section, state])

func _check_library_history() -> void:
    var histories: Array[Node] = controller.view.content.find_children("AstryxGameHistory", "VBoxContainer", true, false)
    _expect(histories.size() == app.known_games.size(), "Every game exposes its play history in either display mode")
    _expect(histories[0].get_child(0).text == "已玩 2h 15m", "Library reads the stored cumulative duration")
    _expect(histories[0].get_child(1).text.begins_with("最近启动 "), "Played games expose their most recent launch")
    _expect(histories[1].get_child(1).text == "尚未启动", "Unplayed games do not invent a launch date")

func _check_detail_editor(key: String, control_name: String) -> void:
    var control: Control = controller.view.find_child(control_name, true, false)
    var save := _button("AstryxSaveDetail_" + key)
    var cancel := _button("AstryxCancelDetail_" + key)
    var edit_name := "AstryxRenameGame" if key == "name" else "AstryxEdit_game_" + key
    _expect(controller.view.find_child(edit_name, true, false) == null, "Expanded detail rows hide Edit rather than replacing it with Close")
    _expect(control.is_visible_in_tree() and save.is_visible_in_tree() and cancel.is_visible_in_tree(), "Editor exposes its own Save and Cancel")
    _expect(save.global_position.y - control.get_global_rect().end.y >= 15, "Save/Cancel sit below the complete editor with a gap")
    _expect(is_equal_approx(save.global_position.y, cancel.global_position.y) and cancel.global_position.x - save.get_global_rect().end.x >= 7.5, "Save/Cancel align in a spaced horizontal row")
    _expect(save.size.y >= 44 and cancel.size.y >= 44, "Inline actions retain touch target size")
    _expect(cancel.get_global_rect().end.x <= controller.view.scroll.get_global_rect().end.x, "Inline actions stay inside the phone/tablet content column")
    _expect(save.get_theme_stylebox("normal").bg_color != cancel.get_theme_stylebox("normal").bg_color, "Save is primary; Cancel is quiet")

func _exercise_game_render_settings() -> void:
    var global_settings: Dictionary = app._current_settings_snapshot().duplicate(true)
    var global_draft: Dictionary = app.settings_draft.duplicate(true)
    var game: Dictionary = app.selected_game.duplicate(true)
    var config_path: String = app._read_game_render_config(game).path
    _expect(_button("AstryxDetailSection_rendering").text == "画面与渲染", "Detail rendering section replaces Compatibility")
    for key in ["upscale_algorithm", "output_resolution", "frame_enhancement_kind"]:
        var picker: OptionButton = controller.view.find_child("AstryxSetting_game_" + key, true, false)
        _expect(picker.get_item_metadata(0) == "" and picker.get_item_text(0) == "跟随系统", "Each game setting has an empty inheritance option")
        var expected: Array = app.GameRenderConfig.PRIMARY_OPTIONS[key].duplicate()
        if key == "upscale_algorithm" and OS.get_name() not in ["macOS", "iOS"]:
            expected.erase("metalfx_spatial")
        var actual: Array = []
        for index in range(1, picker.item_count):
            actual.append(picker.get_item_metadata(index))
        _expect(actual == expected, "Game choices match the platform's global catalog plus inheritance")
    await _click("AstryxEdit_game_upscale_algorithm")
    await _select_value("AstryxSetting_game_upscale_algorithm", "nearest")
    _check_detail_editor("upscale_algorithm", "AstryxSetting_game_upscale_algorithm")
    _expect(not FileAccess.file_exists(config_path), "Editing alone does not create a config")
    await _click("AstryxCancelDetail_upscale_algorithm")
    _expect(not FileAccess.file_exists(config_path) and app._read_game_render_config(game).rendering.upscale_algorithm == "", "Cancel leaves inherited settings and disk untouched")
    await _click("AstryxEdit_game_upscale_algorithm")
    await _select_value("AstryxSetting_game_upscale_algorithm", "nearest")
    await _click("AstryxSaveDetail_upscale_algorithm")
    _expect(controller.view.detail_edit_key.is_empty() and _button("AstryxEdit_game_upscale_algorithm") != null, "Save returns the row to summary/Edit")
    await _click("AstryxEdit_game_output_resolution")
    await _select_value("AstryxSetting_game_output_resolution", "4k")
    await _click("AstryxSaveDetail_output_resolution")
    await _click("AstryxEdit_game_frame_enhancement_kind")
    await _select_value("AstryxSetting_game_frame_enhancement_kind", "preset")
    await _select_value("AstryxSetting_game_frame_enhancement_mode", "chain_light")
    _check_detail_editor("frame_enhancement_kind", "AstryxGameEnhancementEditor")
    _expect(app._read_game_render_config(game).rendering.frame_enhancement_kind == "", "Preset and kind remain a draft until their shared Save")
    controller.view.scroll.ensure_control_visible(_button("AstryxSaveDetail_frame_enhancement_kind"))
    await _capture("astryx-godot-ipad-game-preset-editor")
    await _click("AstryxSaveDetail_frame_enhancement_kind")
    var stored: Dictionary = app._read_game_render_config(game).rendering
    _expect(stored.upscale_algorithm == "nearest" and stored.output_resolution == "4k" and stored.frame_enhancement_mode == "chain_light", "Inline Save writes the selected game settings")
    var body: Control = controller.view.find_child("AstryxDetailBody_rendering", true, false)
    controller.view.scroll.scroll_vertical += int(body.global_position.y - controller.view.scroll.global_position.y - 64)
    await _capture("astryx-godot-ipad-game-rendering")
    await _click("AstryxEdit_game_output_resolution")
    await _select_value("AstryxSetting_game_output_resolution", "2k")
    app._show_detail(app.known_games[2])
    await _settle()
    var other: OptionButton = controller.view.find_child("AstryxSetting_game_upscale_algorithm", true, false)
    _expect(other.get_item_metadata(other.selected) == "" and controller.view.detail_edit_key.is_empty(), "Switching games discards the old draft")
    app._show_detail(game)
    await _settle()
    _expect(app._read_game_render_config(game).rendering.output_resolution == "4k", "Leaving a detail editor does not implicitly save")
    var reopened: OptionButton = controller.view.find_child("AstryxSetting_game_upscale_algorithm", true, false)
    _expect(reopened.get_item_metadata(reopened.selected) == "nearest", "Reopening details reads the saved choices")
    await _click("AstryxEdit_game_frame_enhancement_kind")
    await _select_value("AstryxSetting_game_frame_enhancement_kind", "custom")
    await _select_value("AstryxGameCustomAlgorithm_0", "lanczos")
    await _click("AstryxGameAddCustomStep")
    await _click("AstryxGameRemoveCustomStep_1")
    _expect(app._read_game_render_config(game).rendering.frame_enhancement_kind == "preset", "Custom chain changes are staged with the enhancement kind")
    var layouts := [Vector2i(1194, 834), Vector2i(834, 1194), Vector2i(393, 852)]
    var names := ["ipad", "ipad-portrait", "iphone"]
    for index in range(layouts.size()):
        root.size = layouts[index]
        app._fit_full_rects()
        await _settle()
        var chain: Control = controller.view.find_child("AstryxGameCustomChain", true, false)
        var previous: Control
        for step in chain.find_children("AstryxGameCustomStep_*", "VBoxContainer", true, false):
            _expect(step.get_global_rect().end.x <= controller.view.scroll.get_global_rect().end.x, "Game enhancement editors fit the detail column")
            if previous != null:
                _expect(step.global_position.y - previous.get_global_rect().end.y >= 15, "Game enhancement steps retain spacing")
            previous = step
        _check_detail_editor("frame_enhancement_kind", "AstryxGameEnhancementEditor")
        _expect(controller.view.detail_edit_draft.frame_enhancement_custom_chain[0] == "lanczos", "Rotation retains unsaved custom edits")
        controller.view.scroll.ensure_control_visible(_button("AstryxSaveDetail_frame_enhancement_kind"))
        await _capture("astryx-godot-%s-game-custom" % names[index])
    await _click("AstryxCancelDetail_frame_enhancement_kind")
    _expect(app._read_game_render_config(game).rendering == stored, "Cancel restores the entire enhancement group without any disk change")
    await _click("AstryxEdit_game_frame_enhancement_kind")
    await _select_value("AstryxSetting_game_frame_enhancement_kind", "custom")
    _expect(controller.view.detail_edit_draft.frame_enhancement_custom_chain[0] == "anime4k_upscale_s", "Cancelled custom edits do not reappear")
    await _select_value("AstryxGameCustomAlgorithm_0", "lanczos")
    await _click("AstryxSaveDetail_frame_enhancement_kind")
    _expect(app._read_game_render_config(game).rendering.frame_enhancement_custom_chain[0] == "lanczos", "Saving commits the custom chain and its mode together")
    # A real file error must keep the editor/draft available for retry or cancel.
    var original := FileAccess.get_file_as_string(config_path)
    await _click("AstryxEdit_game_output_resolution")
    await _select_value("AstryxSetting_game_output_resolution", "2k")
    var file := FileAccess.open(config_path, FileAccess.WRITE)
    file.store_string("malformed config fixture")
    file.close()
    await _click("AstryxSaveDetail_output_resolution")
    _expect(controller.view.detail_edit_key == "output_resolution" and controller.view.detail_edit_draft.output_resolution == "2k", "Save failure preserves the draft")
    _expect(controller.view.find_child("AstryxDetailEditError", true, false).is_visible_in_tree(), "Save failure is reported inline")
    _expect(FileAccess.get_file_as_string(config_path) == "malformed config fixture", "A failed save never destroys the existing file")
    file = FileAccess.open(config_path, FileAccess.WRITE)
    file.store_string(original)
    file.close()
    await _click("AstryxCancelDetail_output_resolution")
    for key in ["upscale_algorithm", "output_resolution", "frame_enhancement_kind"]:
        await _click("AstryxEdit_game_" + key)
        await _select_value("AstryxSetting_game_" + key, "")
        await _click("AstryxSaveDetail_" + key)
    stored = app._read_game_render_config(game).rendering
    _expect(stored.upscale_algorithm == "" and stored.output_resolution == "" and stored.frame_enhancement_kind == "", "Saving Follow system writes empty strings")
    _expect(app._current_settings_snapshot() == global_settings and app.settings_draft == global_draft, "Detail drafts never modify global state")
    await _click("AstryxEdit_game_upscale_algorithm")
    await _select_value("AstryxSetting_game_upscale_algorithm", "linear")
    await _click("AstryxDetailSection_rendering")
    await _click("AstryxDetailSection_rendering")
    _expect(controller.view.detail_edit_key.is_empty() and app._read_game_render_config(game).rendering.upscale_algorithm == "", "Collapsing the section cancels pending edits")
    body = controller.view.find_child("AstryxDetailBody_rendering", true, false)
    controller.view.scroll.scroll_vertical += int(body.global_position.y - controller.view.scroll.global_position.y - 64)
    await _capture("astryx-godot-iphone-game-rendering")
    root.size = Vector2i(1194, 834)
    app._fit_full_rects()
    await _settle()

func _exercise_game_text_settings() -> void:
    var game: Dictionary = app.selected_game.duplicate(true)
    var config_path: String = app._read_game_render_config(game).path
    var before := FileAccess.get_file_as_string(config_path)
    app.text_runtime = "yuris"
    controller.view.refresh_content(true)
    await _settle()
    await _click("AstryxEdit_game_encoding")
    _check_detail_editor("encoding", "AstryxSetting_game_encoding")
    await _select_value("AstryxSetting_game_encoding", "GB18030")
    _expect(FileAccess.get_file_as_string(config_path) == before, "Encoding selection is only a draft until saved")
    await _click("AstryxCancelDetail_encoding")
    _expect(FileAccess.get_file_as_string(config_path) == before, "Cancelling encoding leaves the config unchanged")
    await _click("AstryxEdit_game_encoding")
    await _select_value("AstryxSetting_game_encoding", "GBK")
    await _click("AstryxSaveDetail_encoding")
    _expect(app._read_game_text_config(game).text.encoding == "GBK", "Saving encoding reaches the game's JSON file")
    await _click("AstryxEdit_game_font_file")
    await _click("AstryxChooseGameFont")
    var stale_callback := app.font_callback
    await _click("AstryxCancelDetail_font_file")
    var imported: Dictionary = app.GameTextConfig.load_font("res://assets/fonts/Figtree-Regular.ttf")
    stale_callback.call(imported)
    _expect(controller.view.detail_edit_key.is_empty(), "A delayed picker result cannot restore cancelled font edits")
    await _click("AstryxEdit_game_font_file")
    await _click("AstryxChooseGameFont")
    app.font_callback.call(imported)
    await _settle()
    _expect(not DirAccess.dir_exists_absolute(String(game.path).path_join("aether_fonts")), "Picking a font does not yet import into the game")
    for sample in [[Vector2i(1194, 834), "ipad"], [Vector2i(834, 1194), "ipad-portrait"], [Vector2i(393, 852), "iphone"]]:
        root.size = sample[0]
        app._fit_full_rects()
        await _settle()
        _check_detail_editor("font_file", "AstryxGameFontEditor")
        var choose := _button("AstryxChooseGameFont")
        var reset := _button("AstryxResetGameFont")
        _expect(is_equal_approx(choose.size.y, reset.size.y), "Font actions have equal height")
        _expect(reset.get_global_rect().end.x <= controller.view.scroll.get_global_rect().end.x, "Font actions fit phone/tablet width")
        _expect(controller.view.find_child("AstryxGameFontPreview", true, false).get_theme_font("font") == imported.font, "Preview uses the font actually selected")
        controller.view.scroll.ensure_control_visible(_button("AstryxSaveDetail_font_file"))
        await _capture("astryx-godot-%s-game-font" % sample[1])
    await _click("AstryxSaveDetail_font_file")
    var selected: Dictionary = app._read_game_text_config(game).text
    _expect(selected.encoding == "GBK" and selected.font_file.ends_with("Figtree-Regular.ttf"), "Font save preserves the independent encoding")
    _expect(not app.GameTextConfig.font_path(game.path, selected.font_file).is_empty(), "Font Save imports a usable file into the game")
    await _click("AstryxEdit_game_font_file")
    await _click("AstryxResetGameFont")
    await _click("AstryxCancelDetail_font_file")
    _expect(app._read_game_text_config(game).text.font_file == selected.font_file, "Cancel also discards a pending reset")
    await _click("AstryxEdit_game_font_file")
    await _click("AstryxResetGameFont")
    await _click("AstryxSaveDetail_font_file")
    _expect(app._read_game_text_config(game).text.font_file == "", "Saving default font clears only the override")
    await _click("AstryxEdit_game_encoding")
    await _select_value("AstryxSetting_game_encoding", "")
    await _click("AstryxSaveDetail_encoding")
    app.text_runtime = "entisgls"
    controller.view.refresh_content(true)
    await _settle()
    _expect(controller.view.find_child("AstryxEdit_game_encoding", true, false) == null, "EntisGLS has no inapplicable encoding selector")
    _expect(_button("AstryxEdit_game_font_file").is_visible_in_tree(), "EntisGLS can still edit its font")
    app.text_runtime = ""
    var file := FileAccess.open(config_path, FileAccess.WRITE)
    file.store_string(before)
    file.close()
    controller.view.refresh_content(true)
    root.size = Vector2i(1194, 834)
    app._fit_full_rects()
    await _settle()
    _expect(controller.view.find_child("AstryxGameTextSettings", true, false) == null, "Other engines keep the previous game information UI")

func _check_game_information_actions() -> void:
    var game_path: String = app.selected_game.path
    var original_title: String = app._game_display_title(app.selected_game)
    var original_cover: String = app.selected_game.coverPath
    await _click("AstryxRenameGame")
    _expect(not app.modal_layer.visible, "Game name now edits inline")
    var input: LineEdit = controller.view.find_child("AstryxGameNameInput", true, false)
    _expect(input.text == original_title, "Rename starts with the current display title")
    input.text = "取消的名字"
    input.text_changed.emit(input.text)
    await _click("AstryxCancelDetail_name")
    _expect(app._game_display_title(app.selected_game) == original_title, "Cancelling a name edit preserves the stored title")
    await _click("AstryxRenameGame")
    input = controller.view.find_child("AstryxGameNameInput", true, false)
    input.text = "  "
    input.text_changed.emit(input.text)
    _expect(_button("AstryxSaveDetail_name").disabled, "Empty names cannot be saved")
    input.text = "新的游戏名字"
    input.text_changed.emit(input.text)
    _check_detail_editor("name", "AstryxGameNameInput")
    controller.view.scroll.ensure_control_visible(_button("AstryxSaveDetail_name"))
    await _capture("astryx-godot-ipad-name-editor")
    root.size = Vector2i(393, 852)
    app._fit_full_rects()
    await _settle()
    _check_detail_editor("name", "AstryxGameNameInput")
    _expect(controller.view.find_child("AstryxGameNameInput", true, false).text == "新的游戏名字", "Rotation preserves the unsaved game name")
    controller.view.scroll.ensure_control_visible(_button("AstryxSaveDetail_name"))
    await _capture("astryx-godot-iphone-name-editor")
    root.size = Vector2i(1194, 834)
    app._fit_full_rects()
    await _settle()
    await _click("AstryxSaveDetail_name")
    _expect(controller.view.find_child("AstryxGameName", true, false).text == "新的游戏名字", "Saving the inline name refreshes game information")
    _expect(String(app.selected_game.path) == game_path and String(app.selected_game.coverPath) == original_cover, "Renaming preserves game identity and its cover")
    await _click("AstryxRemoveGame")
    _expect(app.modal_layer.visible and app.game_removal_requested == game_path, "Delete opens the existing confirmation for the selected game")
    for action in app.active_modal_dialog.find_children("*", "Button", true, false):
        if action.text == app._t("dialog.cancel"):
            action.pressed.emit()
            break
    await _settle()
    _expect(not app.modal_layer.visible and app.shell_route == "detail", "Cancelling deletion stays on the game detail")
    _expect(app.known_games.size() == 6 and FileAccess.file_exists(original_cover), "Cancelling preserves the library and original cover file")
    app._update_game(game_path, {"title": original_title})
    app._show_detail(app.selected_game)
    await _settle()

func _check_detail_scroll() -> void:
    _check_scrollbar()
    var scroll: ScrollContainer = controller.view.scroll
    scroll.scroll_vertical = 0
    var position := scroll.get_global_rect().position + Vector2(100, 200)
    var motion := InputEventMouseMotion.new()
    motion.position = position
    root.push_input(motion)
    var wheel := InputEventMouseButton.new()
    wheel.position = position
    wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
    wheel.pressed = true
    root.push_input(wheel)
    await _settle()
    _expect(scroll.scroll_vertical > 0, "Wheel over the cover scrolls the active detail page")
    var before := scroll.scroll_vertical
    var pan := InputEventPanGesture.new()
    pan.position = position
    pan.delta = Vector2(0, 2)
    root.push_input(pan)
    await _settle()
    _expect(scroll.scroll_vertical > before, "Trackpad pan scrolls the active detail page")
    var bar := scroll.get_v_scroll_bar()
    # Press the thumb at the top, drag down, then release through normal GUI input.
    scroll.scroll_vertical = 0
    await process_frame
    var start := bar.get_global_rect().position + Vector2(bar.size.x / 2, 20)
    var press := InputEventMouseButton.new()
    press.position = start
    press.button_index = MOUSE_BUTTON_LEFT
    press.pressed = true
    root.push_input(press)
    motion = InputEventMouseMotion.new()
    motion.position = start + Vector2(0, 100)
    motion.relative = Vector2(0, 100)
    motion.button_mask = MOUSE_BUTTON_MASK_LEFT
    root.push_input(motion)
    press.position = motion.position
    press.pressed = false
    root.push_input(press)
    await _settle()
    _expect(scroll.scroll_vertical > 0, "The scrollbar thumb can be dragged")
    scroll.scroll_vertical = int(bar.max_value - bar.page)
    await _settle()
    var cover: Control = controller.view.find_child("AstryxDetailCover", true, false)
    _expect(cover.get_global_rect().end.y <= scroll.get_global_rect().end.y + 1,
        "The bottom of the cover is reachable by scrolling")

func _media(title: String) -> Button:
    for button in controller.view.find_children("*", "Button", true, false):
        if button.accessibility_name == title:
            return button
    _expect(false, "Missing media row: " + title)
    return null

func _check_media_actions() -> void:
    for row in controller.view.find_children("AstryxMediaRow_*", "HBoxContainer", true, false):
        var play: Button = row.find_child("AstryxPlayMedia", true, false)
        var remove: Button = row.find_child("AstryxDeleteMedia", true, false)
        _expect(play.size.is_equal_approx(Vector2(44, 44)), "Media open/play has a square touch target")
        if remove != null:
            _expect(play.size.is_equal_approx(remove.size), "Media play and delete have equal sizes")
            _expect(is_equal_approx(play.global_position.y, remove.global_position.y), "Media play and delete align vertically")
        _expect(controller.view.scroll.get_global_rect().end.x >= row.get_global_rect().end.x, "Media actions fit the phone/tablet pane")
    var trail: Control = controller.view.find_child("AstryxBreadcrumbs", true, false)
    if trail != null:
        for crumb in trail.find_children("AstryxBreadcrumb_*", "Button", true, false):
            _expect(trail.get_global_rect().encloses(crumb.get_global_rect()), "Breadcrumbs wrap within the content width")

func _capture_announcement() -> void:
    if OS.get_environment("AETHERKIRI_ASTRYX_CAPTURE_DIR").is_empty() or DisplayServer.get_name() == "headless":
        return
    for sample in [[Vector2i(1194, 834), "light", "ipad"], [Vector2i(393, 852), "light", "iphone"], [Vector2i(393, 852), "dark", "iphone-dark"]]:
        root.size = sample[0]
        app._fit_full_rects()
        controller.draft_theme = sample[1]
        controller.view.rebuild()
        await _settle()
        app._show_notice()
        await _capture("astryx-godot-%s-announcement" % sample[2])
        app._dismiss_modal()
        await _settle()
    controller.draft_theme = controller.theme_mode
    root.size = Vector2i(1194, 834)
    app._fit_full_rects()
    await _settle()

func _write(path: String) -> void:
    DirAccess.make_dir_recursive_absolute(path.get_base_dir())
    var file := FileAccess.open(path, FileAccess.WRITE)
    file.store_string("UI fixture")

func _capture(name_value: String) -> void:
    var output := OS.get_environment("AETHERKIRI_ASTRYX_CAPTURE_DIR")
    if output.is_empty() or DisplayServer.get_name() == "headless":
        return
    await _settle()
    # macOS can suspend automatic drawing when another app covers the test window.
    RenderingServer.force_draw(false)
    root.get_texture().get_image().save_png(output.path_join(name_value + ".png"))

func _run() -> void:
    create_timer(120).timeout.connect(func():
        push_error("Astryx test timed out")
        quit(1)
    )
    root.size = Vector2i(1194, 834)
    root.content_scale_size = Vector2i.ZERO
    root.gui_embed_subwindows = true
    fixture = DirAccess.create_temp("aether-astryx-ui")
    var base := fixture.get_current_dir()
    var nested := base.path_join("动画收藏/特别篇/夏日回忆.mp4")
    _write(nested)
    _write(base.path_join("动画收藏/第一话.mp4"))
    _write(base.path_join("Opening Movie.mp4"))
    DirAccess.make_dir_recursive_absolute(base.path_join("动画收藏/待整理"))
    app = TestHost.new()
    app.active_language = app.LANG_ZH_HANS
    app.language_mode = app.LANG_ZH_HANS
    app.known_games = [{"name": "Aether Demo", "path": base.path_join("game"), "type": "Directory", "coverPath": ProjectSettings.globalize_path("res://../../tools/astryx-preview/public/demo-cover.svg")}]
    for title in ["【双端KR】是谁杀死了知更鸟", "恋爱少不了撒娇", "戦国†恋姫X", "秽翼的尤斯蒂娅", "レゾナ＆板野奏Ver"]:
        app.known_games.append({"name": title, "path": base.path_join(title), "type": "Directory"})
    app.known_games[2]["coverPath"] = ProjectSettings.globalize_path("res://../../tools/astryx-preview/public/demo-landscape.svg")
    for game in app.known_games:
        DirAccess.make_dir_recursive_absolute(game.path)
    app.known_games[0].merge({"playDurationSeconds": 8100, "lastPlayed": int(Time.get_unix_time_from_system()) - 7200})
    app.known_games[2].merge({"playDurationSeconds": 2520, "lastPlayed": int(Time.get_unix_time_from_system()) - 86400})
    app.video_progress_data = {"fixture": {}}
    app.video_library = Library.new(base.path_join("videos.json"), base.path_join("hidden.json"))
    app.flash_library = Library.new(base.path_join("flash.json"), base.path_join("flash-hidden.json"), ["swf"])
    app.video_library.add_source(base.path_join("动画收藏"))
    app.video_library.add_source(base.path_join("Opening Movie.mp4"))
    controller = TestController.new()
    controller.name = "ShellInterface"
    controller.preference_path = base.path_join("astryx.cfg")
    app.add_child(controller)
    root.add_child(app)
    await _settle()
    _expect(not controller.enabled, "Classic remains the default")
    app._show_settings()
    await _settle()
    _expect(app.find_child("ShellInterfaceSwitch", true, false) != null, "Classic settings expose the optional switch")
    controller.set_enabled(true)
    await _settle()
    _expect(not app.shell_content.visible, "Classic content is hidden under the new presenter")
    _expect(controller.view.find_child("AstryxSearch", true, false) == null, "Settings have no search input")
    _expect(controller.view.find_child("AstryxNav_dashboard", true, false) == null, "Overview is absent")
    _expect(not controller.view.phone, "iPad uses the sidebar composition")
    _expect(not controller.view.settings_narrow, "Landscape settings keep the category sidebar")
    _expect(not controller.view.settings_footer.visible, "Clean settings do not reserve a save bar")
    _check_settings_geometry()
    await _capture("astryx-godot-ipad-light")
    await _check_tab_hover("AstryxSection_render")
    _check_settings_geometry()
    await _capture("astryx-godot-ipad-settings-hover")
    await _capture_announcement()
    await _exercise_saved_notice()
    await _exercise_additional_settings()
    await _click("AstryxEdit_language")
    var language_picker := controller.view.find_child("AstryxSetting_language", true, false) as OptionButton
    _expect(language_picker.is_visible_in_tree(), "Edit reveals the real selector")
    var before_language: String = app.settings_draft.language
    var changed_language := (language_picker.selected + 1) % language_picker.item_count
    language_picker.select(changed_language)
    language_picker.item_selected.emit(changed_language)
    await _settle()
    _expect(controller.is_dirty() and controller.view.settings_footer.visible, "Editing a setting exposes save actions")
    root.size = Vector2i(834, 1194)
    app._fit_full_rects()
    await _settle()
    _expect(not controller.view.settings_narrow, "Large iPad portrait keeps two comfortable panes")
    _expect(app.settings_draft.language != before_language, "Rotation preserves the settings draft")
    _expect(controller.view.find_child("AstryxSetting_language", true, false).is_visible_in_tree(), "Rotation preserves the open editor")
    _check_settings_geometry()
    await _capture("astryx-godot-ipad-portrait-edit")
    await _click("AstryxCancelSettings")
    _expect(app.settings_draft.language == before_language, "Cancel restores real host settings as well as the theme")
    await _capture("astryx-godot-ipad-portrait-light")
    root.size = Vector2i(768, 1024)
    app._fit_full_rects()
    await _settle()
    _expect(controller.view.settings_narrow, "Smaller iPad portrait uses the template drill-down layout")
    await _click("AstryxSettingsBack")
    _expect(controller.view.find_child("AstryxSettingsDetail", true, false) == null, "Back shows only the category menu")
    await _capture("astryx-godot-ipad-small-portrait-menu")
    await _click("AstryxSection_render")
    _check_settings_geometry()
    await _capture("astryx-godot-ipad-small-portrait-detail")
    root.size = Vector2i(1194, 834)
    app._fit_full_rects()
    await _settle()
    await _click("AstryxSection_interface")
    await _click("AstryxNav_library")
    _check_header_heights()
    var rail: Control = controller.view.find_child("AstryxSideNav", true, false)
    _expect(is_equal_approx(rail.size.x, 48), "Sidebar starts as an icon rail")
    app.ui_motion.reduced_motion = false
    await _pointer_click("AstryxToggleSidebar")
    _expect(controller.view.sidebar_expanded, "App icon expands the sidebar")
    _expect(not _button("AstryxToggleSidebar").has_focus(), "Pointer activation does not leave a focus ring on the App icon")
    rail = controller.view.find_child("AstryxSideNav", true, false)
    _expect(is_equal_approx(rail.size.x, 260), "Expanded sidebar reaches the Astryx width")
    _expect(controller.view.find_child("AstryxNavLabel_library", true, false).text == "游戏库", "Expanded navigation shows full labels")
    _expect(controller.view.scroll.global_position.x >= rail.get_global_rect().end.x, "Expanded sidebar pushes content without overlap")
    await _capture("astryx-godot-ipad-sidebar-expanded")
    await _click("AstryxNav_videos")
    _expect(controller.view.sidebar_expanded, "Sidebar expansion survives route navigation")
    await _click("AstryxNav_library")
    _button("AstryxToggleSidebar").grab_focus()
    var key := InputEventKey.new()
    key.keycode = KEY_SPACE
    key.pressed = true
    root.push_input(key)
    key.pressed = false
    root.push_input(key)
    await _settle()
    _expect(not controller.view.sidebar_expanded, "Clicking the App icon again collapses the sidebar")
    _expect(_button("AstryxToggleSidebar").has_focus(), "Keyboard activation preserves focus after sidebar rebuild")
    _button("AstryxToggleSidebar").release_focus()
    _expect(controller.view.find_child("AstryxNavLabel_library", true, false) == null, "Collapsed navigation hides the full labels")
    app.ui_motion.reduced_motion = true
    await _check_tab_hover("AstryxAllGames")
    await _check_tab_hover("AstryxRecentGames")
    await _capture("astryx-godot-ipad-library-light")
    _check_library_history()
    _expect(controller.library_display == "cards", "The default library uses cards")
    await _click("AstryxDisplay_list")
    _expect(controller.view.find_child("AstryxGameList", true, false) != null, "List mode uses game rows")
    _expect(controller.view.find_child("AstryxGameList", true, false).get_child_count() == app.known_games.size(), "List mode shows every game")
    controller.view.search.text = "知更鸟"
    controller.view.search.text_changed.emit("知更鸟")
    await _settle()
    _expect(controller.view.find_child("AstryxGameList", true, false).get_child_count() == 1, "List mode applies the game search")
    await _click("AstryxDisplay_cards")
    _expect(controller.view.search.text == "知更鸟", "Switching display preserves the current search")
    await _click("AstryxDisplay_list")
    controller.view.search.text = ""
    controller.view.search.text_changed.emit("")
    await _settle()
    await _capture("astryx-godot-ipad-list-light")
    _check_library_history()
    var reloaded := TestController.new()
    reloaded.preference_path = controller.preference_path
    reloaded.load_preferences()
    _expect(reloaded.library_display == "list", "Display preference survives a relaunch")
    reloaded.free()
    _media("【双端KR】是谁杀死了知更鸟").pressed.emit()
    await _settle()
    _expect(app.shell_route == "detail" and app.selected_game.name == "【双端KR】是谁杀死了知更鸟", "A list row opens the selected game's detail")
    await _click("AstryxDetailBack")
    _expect(controller.view.find_child("AstryxGameList", true, false) != null, "Returning from detail preserves list mode")
    await _click("AstryxDisplay_cards")
    await _click("AstryxNav_settings")
    await _click("AstryxEdit_theme")
    await _click("AstryxTheme_dark")
    _expect(controller.is_dirty() and controller.theme_mode == "light", "Theme is previewed without saving")
    await _click("AstryxCancelSettings")
    _expect(controller.draft_theme == "light" and not controller.is_dirty(), "Cancel restores the saved theme")
    await _click("AstryxEdit_theme")
    await _click("AstryxTheme_dark")
    await _click("AstryxNav_videos")
    _expect(app.shell_route == "settings" and app.modal_layer.visible, "Dirty navigation prompts before leaving")
    await _click("AstryxKeepEditing")
    _expect(app.shell_route == "settings", "Keep editing preserves the route")
    await _click("AstryxNav_videos")
    await _click("AstryxSaveAndLeave")
    _expect(app.shell_route == "videos" and controller.theme_mode == "dark", "Save-and-leave applies the theme and navigates")
    _expect(FileAccess.file_exists(controller.preference_path), "Interface preferences persist separately")
    _expect(_media("动画收藏") != null and _media("Opening Movie") != null, "Folders and loose videos coexist")
    _check_media_actions()
    var remove: Button = _media("Opening Movie").get_parent().find_child("AstryxDeleteMedia", true, false)
    remove.pressed.emit()
    await _settle()
    _expect(app.modal_layer.visible and app.removal_requested == base.path_join("Opening Movie.mp4"), "Delete opens the existing confirmation for the correct file")
    _expect(app.opened_video.is_empty(), "Clicking delete never triggers playback")
    for action in app.active_modal_dialog.find_children("*", "Button", true, false):
        if action.text == app._media_text("dialog.cancel"):
            action.pressed.emit()
            break
    await _settle()
    _expect(not app.modal_layer.visible and FileAccess.file_exists(base.path_join("Opening Movie.mp4")), "Cancel leaves the media source untouched")
    _media("动画收藏").pressed.emit()
    await _settle()
    _expect(app.video_library.current_directory.ends_with("动画收藏"), "Folder row enters the real directory")
    _media("特别篇").pressed.emit()
    await _settle()
    _expect(_button("AstryxBreadcrumb_2").text == "特别篇" and _button("AstryxBreadcrumb_2").disabled, "Breadcrumbs identify the current nested folder")
    await _click("AstryxBreadcrumb_1")
    _expect(app.video_library.current_directory == base.path_join("动画收藏"), "An ancestor breadcrumb returns directly to its folder")
    controller.view.search.text = "夏日"
    controller.view.search.text_changed.emit("夏日")
    await _settle()
    _media("夏日回忆").pressed.emit()
    _expect(app.opened_video == nested, "Recursive search launches the actual nested path")
    controller.view.query = ""
    controller.view.refresh_content()
    _media("待整理").pressed.emit()
    await _settle()
    _expect(app.video_library.entries.is_empty(), "Empty folders stay navigable")
    await _click("AstryxBreadcrumb_1")
    for sample in [[Vector2i(1194, 834), "ipad"], [Vector2i(834, 1194), "ipad-portrait"], [Vector2i(393, 852), "iphone"]]:
        root.size = sample[0]
        app._fit_full_rects()
        await _settle()
        _check_media_actions()
        await _capture("astryx-godot-%s-videos" % sample[1])
    controller.view.search.text = "第一话"
    controller.view.search.text_changed.emit("第一话")
    await _settle()
    await _click("AstryxBreadcrumb_0")
    _expect(app.video_library.current_directory.is_empty() and controller.view.query.is_empty(), "The root breadcrumb returns to the library and clears search")
    _expect(controller.view.find_child("AstryxBreadcrumbs", true, false) == null, "The library root does not repeat its title as a breadcrumb")
    root.size = Vector2i(1194, 834)
    app._fit_full_rects()
    await _settle()
    await _click("AstryxNav_library")
    await _capture("astryx-godot-ipad-library-dark")
    _check_scrollbar()
    app._show_detail(app.known_games[0])
    await _settle()
    await _check_game_information_actions()
    await _check_detail_geometry()
    await _click("AstryxDetailSection_rendering")
    _expect(controller.view.find_child("AstryxDetailBody_rendering", true, false).visible, "Game detail accordion expands")
    await _exercise_game_render_settings()
    await _exercise_game_text_settings()
    await _check_detail_geometry()
    await _click("AstryxDetailSection_cover")
    await _check_detail_geometry()
    _check_detail_actions()
    _expect(_button("AstryxDetailSection_cover").text == "封面", "The last section is named Cover")
    controller.view.scroll.ensure_control_visible(_button("AstryxClearCover"))
    await _capture("astryx-godot-ipad-cover-actions")
    await _click("AstryxSetLaunchFile")
    _expect(app.launch_picker_opened, "Launch-file Set delegates to the host picker")
    await _click("AstryxSetCover")
    _expect(app.modal_layer.visible and app.active_modal_dialog.name == "AstryxCoverSourceDialog", "Set Cover first asks for its source")
    await _click("AstryxCoverSource_local")
    _expect(app.cover_picker_opened, "Cover Set delegates to the host picker")
    var original_cover: String = app.selected_game.coverPath
    await _click("AstryxClearCover")
    _expect(app.cover_cleared and String(app.selected_game.coverPath).is_empty(), "Delete clears the cover association through the host")
    _expect(controller.view.find_child("AstryxClearCover", true, false) == null, "Delete disappears after removing the cover")
    _expect(controller.view.find_child("AstryxDetailCover", true, false).find_child("CoverImage", true, false) == null, "Removing the cover refreshes the hero to its placeholder")
    _expect(not controller.view.detail_backdrop.visible and controller.view.detail_backdrop.texture == null, "Clearing the cover also removes the backdrop without leaving stale artwork")
    _check_detail_actions()
    app.selected_game["coverPath"] = original_cover
    app._show_detail(app.selected_game)
    await _settle()
    _expect(controller.view.find_child("AstryxClearCover", true, false) != null, "Setting a cover restores Delete")
    _expect(controller.view.detail_backdrop.visible and controller.view.detail_backdrop.texture != null, "Setting a cover restores its backdrop immediately")
    root.size = Vector2i(834, 1194)
    app._fit_full_rects()
    await _settle()
    _check_detail_actions()
    controller.view.scroll.ensure_control_visible(_button("AstryxClearCover"))
    await _capture("astryx-godot-ipad-portrait-cover-actions")
    root.size = Vector2i(1194, 834)
    app._fit_full_rects()
    await _settle()
    await _click("AstryxDetailSection_cover")
    await _click("AstryxLaunchGame")
    _expect(app.launched, "Launch delegates to the existing runtime action")
    await _capture("astryx-godot-ipad-detail")
    app._show_detail(app.known_games[2])
    await _settle()
    await _check_detail_geometry()
    await _capture("astryx-godot-ipad-detail-landscape")
    app._show_detail(app.known_games[0])
    await _settle()
    root.size = Vector2i(1440, 810)
    app._fit_full_rects()
    await _settle()
    await _check_detail_geometry()
    root.size = Vector2i(1440, 600)
    app._fit_full_rects()
    await _settle()
    await _check_detail_geometry()
    await _check_detail_scroll()
    await _capture("astryx-godot-detail-scrolled")
    root.size = Vector2i(393, 852)
    app._fit_full_rects()
    await _settle()
    _expect(controller.view.phone, "iPhone uses bottom navigation")
    await _check_detail_geometry()
    await _capture("astryx-godot-iphone-detail")
    await _click("AstryxDetailSection_cover")
    _check_detail_actions()
    controller.view.scroll.ensure_control_visible(_button("AstryxClearCover"))
    await _capture("astryx-godot-iphone-cover-actions")
    var previous_detail_theme: String = controller.draft_theme
    controller.draft_theme = "light"
    controller.view.rebuild(true)
    await _settle()
    _check_detail_actions()
    controller.view.scroll.ensure_control_visible(_button("AstryxClearCover"))
    await _capture("astryx-godot-iphone-cover-actions-light")
    controller.draft_theme = previous_detail_theme
    controller.view.rebuild(true)
    await _settle()
    await _click("AstryxDetailSection_cover")
    await _check_detail_scroll()
    app._show_detail(app.known_games[2])
    await _settle()
    await _check_detail_geometry()
    await _capture("astryx-godot-iphone-detail-landscape")
    await _click("AstryxNav_library")
    await _check_tab_hover("AstryxRecentGames")
    _check_header_heights()
    _expect(controller.view.find_child("AstryxToggleSidebar", true, false) == null, "Phone keeps bottom navigation without a sidebar toggle")
    await _capture("astryx-godot-iphone-library-dark")
    _check_library_history()
    await _click("AstryxDisplay_list")
    _expect(controller.view.find_child("AstryxGameList", true, false) != null, "Phone also supports list mode")
    _expect(controller.view.find_child("AstryxLibraryDisplay", true, false).get_global_rect().end.x <= app.size.x, "Phone display switch fits beside the import button")
    await _capture("astryx-godot-iphone-list-dark")
    await _click("AstryxNav_settings")
    _expect(controller.view.find_child("AstryxSearch", true, false) == null, "Phone settings also have no search")
    _expect(controller.view.find_child("AstryxBottomNav", true, false).get_global_rect().end.x <= app.size.x + 1, "Phone navigation fits the viewport")
    _expect(controller.view.find_child("AstryxSettingsDetail", true, false) == null, "Entering phone settings starts at the category menu")
    await _capture("astryx-godot-iphone-settings-menu")
    await _click("AstryxSection_render")
    _expect(controller.view.find_child("AstryxSetting_backend", true, false) != null, "Existing renderer setting is available")
    await _click("AstryxEdit_backend")
    _expect(controller.view.find_child("AstryxSetting_backend", true, false).is_visible_in_tree(), "Phone renderer editor is usable")
    _check_settings_geometry()
    _check_scrollbar()
    for category in ["compatibility", "diagnostics", "about"]:
        await _click("AstryxSettingsBack")
        await _click("AstryxSection_" + category)
        _check_settings_geometry()
        if category == "about":
            _check_about_rows()
            await _capture("astryx-godot-iphone-about-dark")
    await _click("AstryxSettingsBack")
    await _click("AstryxSection_interface")
    _check_settings_geometry()
    await _capture("astryx-godot-iphone-dark")
    await _click("AstryxEdit_theme")
    await _click("AstryxTheme_light")
    await _click("AstryxSettingsBack")
    _expect(controller.view.settings_footer.visible and controller.is_dirty(), "Returning to categories retains unsaved changes and actions")
    await _click("AstryxCancelSettings")
    await _click("AstryxSection_interface")
    await _click("AstryxSwitchToClassic")
    _expect(not controller.enabled and app.shell_content.visible, "Switching back restores classic UI")
    controller.load_preferences()
    _expect(not controller.enabled and controller.theme_mode == "dark", "Relaunch preferences preserve classic choice and new theme")
    app.queue_free()
    await process_frame
    fixture = null
    print("ASTRYX_SHELL_OK" if failures == 0 else "ASTRYX_SHELL_FAILED: %d" % failures)
    quit(0 if failures == 0 else 1)
