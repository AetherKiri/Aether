extends SceneTree

const ShellTest := preload("res://tests/astryx_shell_test.gd")
const PATH := "/games/海边的来信.7z"
const ITEM := {"path": PATH, "name": "海边的来信.7z", "size": 4096}

class ArchiveFixture:
    extends "res://scripts/archive_import.gd"
    var inspections := 0
    var cancellations := 0
    var extracted_source := false

    func _ready() -> void:
        set_process(false)

    func _writable(path: String) -> bool:
        return DirAccess.dir_exists_absolute(path)

    func inspect(path: String) -> void:
        inspections += 1
        if String(state.path) != path:
            destination_dir = games_folder()
            layout = "smart"
            conflict = "keep"
        state = {"phase": "inspecting", "path": path, "name": path.get_file(), "destination": "", "progress": -1.0}
        changed.emit()

    func report(phase: String, fraction := -1.0, detail := "") -> void:
        state.merge({"phase": phase, "format": "7z", "destination": ProjectSettings.globalize_path("user://Games/海边的来信"),
            "placement": {"archive_name": "海边的来信", "common_directory": "海边的来信", "smart_subdir": "海边的来信", "can_strip": true, "has_launcher": true},
            "progress": fraction, "message": detail}, true)
        if phase == "done":
            extracted_source = true
            refresh()
        changed.emit()

    func extract(value: String) -> void:
        if value == "fixture":
            report("extracting")
        else:
            report("password", -1, "请重新输入密码" if not value.is_empty() else "")

    func cancel() -> void:
        cancellations += 1
        dismiss()

    func set_hide_extracted(value: bool) -> void:
        hide_extracted = value
        refresh()
        changed.emit()

    func refresh() -> void:
        entries.clear()
        if not extracted_source or not hide_extracted:
            entries.append(ITEM)
        entries_changed.emit()

class Host:
    extends ShellTest.TestHost
    func _ui_safe_rect(viewport_size: Vector2) -> Rect2:
        return Rect2(8, 36, viewport_size.x - 16, viewport_size.y - 70)

var failures := 0
var app := Host.new()
var service := ArchiveFixture.new()
var controller := ShellTest.TestController.new()
var fixture := DirAccess.create_temp("astryx-archives")

func _initialize() -> void:
    call_deferred("_run")

func expect(ok: bool, what: String) -> void:
    if not ok:
        failures += 1
        push_error(what)

func settle() -> void:
    for i in 5:
        await process_frame

func click_at(pos: Vector2) -> void:
    var move := InputEventMouseMotion.new()
    move.position = pos
    root.push_input(move)
    for down in [true, false]:
        var event := InputEventMouseButton.new()
        event.button_index = MOUSE_BUTTON_LEFT
        event.position = pos
        event.pressed = down
        root.push_input(event)
    await settle()

func drag_from(start: Vector2) -> void:
    var touch := InputEventScreenTouch.new()
    touch.index = 0
    touch.position = start
    touch.pressed = true
    root.push_input(touch)
    var drag := InputEventScreenDrag.new()
    drag.index = 0
    drag.relative = Vector2(0, 96)
    drag.position = start + drag.relative
    root.push_input(drag)
    touch.pressed = false
    touch.position = drag.position
    root.push_input(touch)
    await settle()

func _run() -> void:
    create_timer(45).timeout.connect(func(): push_error("Archive dialog test timed out"); quit(1))
    root.content_scale_size = Vector2i.ZERO
    root.size = Vector2i(393, 852)
    app.archive_import = service
    app.add_child(service)
    app.active_language = app.LANG_ZH_HANS
    app.language_mode = app.LANG_ZH_HANS
    app.cache_base = fixture.get_current_dir()
    controller.preference_path = fixture.get_current_dir().path_join("shell.cfg")
    controller.name = "ShellInterface"
    app.add_child(controller)
    root.add_child(app)
    await settle()
    app._show_library("game", false)
    controller.sync_state()
    service.refresh()
    await settle()
    var view = controller.view
    app.known_games.assign([{"name": "测试游戏", "path": fixture.get_current_dir(), "type": "Directory", "lastPlayed": 1000}])
    view.query = "other"
    view.refresh_content()
    expect(view.find_child("AstryxArchiveCard", true, false) == null, "A library search filters archives")
    view.query = "来信"
    view.recent_only = true
    view.refresh_content()
    expect(view.find_child("AstryxArchiveCard", true, false) == null, "An archive is never a recently played game")
    view.query = ""
    view.recent_only = false
    view.refresh_content()
    await settle()
    var card := view.find_child("AstryxArchiveCard", true, false) as Button
    var game := view.find_child("AstryxGameCard", true, false) as Button
    expect(card != null and game != null, "The archive and game both appear as cards")
    if card == null or game == null:
        quit(1)
        return
    expect(card.get_parent() == game.get_parent() and card.get_parent() is GridContainer, "The archive shares the game grid")
    expect(game.get_index() < card.get_index(), "Recently played games keep their position ahead of archive files")
    var archive_cover := card.find_child("AstryxCardCover", true, false) as Control
    var game_cover := game.find_child("AstryxCardCover", true, false) as Control
    expect(absf(archive_cover.size.x - game_cover.size.x) <= 1.0 and absf(archive_cover.size.y - game_cover.size.y) <= 2.0, "The archive and game cover sizes differ only by grid rounding (%s, %s)" % [archive_cover.size, game_cover.size])
    controller.set_library_display("list")
    await settle()
    var row := view.find_child("AstryxArchiveRow", true, false) as Button
    var game_row := view.find_child("AstryxGameRow", true, false) as Button
    expect(row != null and game_row != null and row.get_parent() == game_row.get_parent(), "The list toggle shows both kinds together")
    controller.set_library_display("cards")
    await settle()
    card = view.find_child("AstryxArchiveCard", true, false) as Button
    await click_at(card.get_global_rect().get_center())
    var dialog = app.active_modal_dialog
    expect(dialog != null and service.inspections == 1, "Tapping the archive icon opens the dialog and inspects once")
    if dialog == null:
        quit(1)
        return
    expect(dialog.phase == "inspecting" and dialog.progress.indeterminate, "Inspection uses indeterminate progress")
    service.report("ready")
    await settle()
    _geometry(dialog)
    expect(dialog.destination_group.get_parent() == dialog.stack, "The path preview stays above the actions on a portrait phone")
    expect(dialog.destination.text == "游戏目录 / 海边的来信" and dialog.destination.tooltip_text == service.state.destination, "The destination shows a readable Games path and retains its full location")
    expect(dialog.layouts.item_count == 4 and dialog.conflicts.item_count == 4 and dialog.locations.item_count >= 2, "The confirmation offers destination, four eligible layouts and four conflict policies")
    dialog.layouts.item_selected.emit(2)
    dialog.conflicts.item_selected.emit(3)
    expect(service.layout == "folder" and service.conflict == "replace" and dialog.replace_warning.visible and dialog.primary.text == "解压并替换", "Replace is explicit in both the warning and confirmation")
    expect(service.choose_destination(fixture.get_current_dir()), "A different destination can be selected")
    expect(dialog.destination.tooltip_text == fixture.get_current_dir().path_join("海边的来信"), "The preview follows the selected destination and layout")
    dialog.layouts.item_selected.emit(3)
    expect(dialog.destination.tooltip_text == fixture.get_current_dir(), "Strip previews the contents directly in the destination")
    await click_at(dialog.primary.get_global_rect().get_center())
    expect(dialog.password.secret and dialog.password_group.visible and dialog.primary.disabled, "An empty masked password cannot submit")
    dialog.password.insert_text_at_caret("wrong")
    service.changed.emit()
    expect(dialog.password.text.length() == 5, "A state notification preserves an in-progress password")
    await click_at(dialog.primary.get_global_rect().get_center())
    expect(service.layout == "strip" and service.conflict == "replace" and service.destination_dir == fixture.get_current_dir(), "A password retry retains the full extraction plan")
    expect(dialog.message.visible and dialog.password.text.is_empty() and dialog.primary.disabled, "A failure clears the attempted password and enables retry after new input")
    dialog.password.insert_text_at_caret("fixture")
    dialog.password.text_submitted.emit(dialog.password.text)
    service.report("extracting", 0.42)
    await settle()
    expect(is_equal_approx(dialog.progress.value, 0.42) and dialog.progress_label.text.contains("42%"), "Determinate progress displays the reported percentage")
    await click_at(dialog.cancel_button.get_global_rect().get_center())
    expect(service.cancellations == 1 and not app.modal_layer.visible, "Cancelling stops the operation and closes the dialog")

    root.size = Vector2i(1194, 834)
    app._fit_full_rects()
    controller.theme_mode = "dark"
    controller.draft_theme = "dark"
    view.rebuild()
    await settle()
    view.open_archive(PATH)
    dialog = app.active_modal_dialog
    service.report("error", -1, "缺少分卷")
    await settle()
    _geometry(dialog)
    expect(dialog.get_theme_stylebox("panel").bg_color == view.design.color("surface"), "The dialog uses the dark surface token")
    service.report("error", -1, "缺少分卷\n".repeat(80))
    await settle()
    var scroll := dialog.find_child("ArchiveBodyScroll", true, false) as ScrollContainer
    expect(scroll.get_v_scroll_bar().max_value > scroll.get_v_scroll_bar().page, "Long error details scroll above the actions")
    _geometry(dialog)
    await click_at(dialog.primary.get_global_rect().get_center())
    expect(service.inspections == 3 and dialog.phase == "inspecting", "Retry inspects the same archive again")
    service.report("done", 1.0)
    await settle()
    expect(dialog.title.text == "解压完成" and view.find_child("AstryxArchiveCard", true, false) == null, "A success remains readable after its library row disappears")
    await click_at(dialog.primary.get_global_rect().get_center())
    expect(not app.modal_layer.visible, "Done returns to the library")
    view.navigate("settings")
    await settle()
    var category: Button = view.find_child("AstryxSection_archive", true, false)
    await click_at(category.get_global_rect().get_center())
    var visibility: Button = view.find_child("AstryxArchiveVisibility", true, false)
    var bounds := visibility.get_global_rect()
    await click_at(Vector2(bounds.position.x + 14, bounds.get_center().y))
    expect(not service.hide_extracted and not view.archive_toggle.button_pressed, "Tapping the setting text restores the original archive row")
    await click_at(view.archive_toggle.get_global_rect().get_center())
    expect(service.hide_extracted and view.archive_toggle.button_pressed, "Tapping the track toggles exactly once")
    service.set_hide_extracted(false)
    view.navigate("library")
    await settle()
    expect(view.find_child("AstryxArchiveCard", true, false) != null, "Returning to a cached library shows the restored original")
    view.open_archive(PATH)
    service.report("password")
    app._handle_go_back_request()
    if app.modal_layer.visible:
        await app.modal_layer.visibility_changed
    await settle()
    expect(service.state.phase == "idle" and not app.modal_layer.visible, "System Back dismisses both the dialog and the password request")
    view.open_archive(PATH)
    service.report("ready")
    await settle()
    dialog = app.active_modal_dialog
    expect(dialog.find_child("ArchiveHandle", true, false) == null, "The centered dialog has no drag handle")
    await drag_from(dialog.title.get_global_rect().get_center())
    expect(app.modal_layer.visible and service.state.phase == "ready", "Dragging inside the dialog keeps it open")
    await click_at(Vector2(12, 42))
    expect(not app.modal_layer.visible and service.state.phase == "idle", "Tapping the scrim dismisses the ready dialog")
    service.inspect(PATH)
    service.report("extracting", 0.25)
    var inspections := service.inspections
    view.open_archive("/another.zip")
    dialog = app.active_modal_dialog
    expect(service.inspections == inspections and dialog.current_path == PATH, "Opening another archive during extraction presents the running job")
    dialog.cancel_button.pressed.emit()
    app.queue_free()
    await settle()
    print("Astryx archive dialog failures: ", failures)
    quit(0 if failures == 0 else 1)

func _geometry(dialog: Panel) -> void:
    var safe := app._ui_safe_rect(Vector2(root.size))
    var panel := dialog.get_global_rect()
    var action := (dialog.find_child("ArchivePrimary", true, false) as Button).get_global_rect()
    expect(panel.get_center().distance_to(safe.get_center()) <= 1.0, "The dialog is centered on both axes inside the safe area")
    expect(panel.size.x <= 480.0 and safe.grow(-15).encloses(panel), "The dialog respects its width cap and safe area gutters")
    expect(panel.encloses(action), "The primary action stays visible inside the dialog")
