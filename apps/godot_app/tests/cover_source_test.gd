extends SceneTree
const Suite = preload("res://tests/astryx_shell_test.gd")
const Picker = preload("res://scripts/ui/astryx/cover_picker.gd")
const CoverConfig = preload("res://scripts/game_cover_config.gd")

class Host extends Suite.TestHost:
    var photo_platform := ""
    var photos_opened := false
    var covers_directory := ""
    var applied: Array[Dictionary] = []
    func _can_select_cover_photo() -> bool:
        return photo_platform in ["iOS", "Android"] if not photo_platform.is_empty() else super._can_select_cover_photo()
    func _select_cover_photo(_path: String) -> void:
        photos_opened = true
    func _cover_import_directory() -> String:
        return covers_directory
    func _record_selected_cover(path: String, cover: String) -> void:
        applied.append({"game": path, "cover": cover})
        _update_game(path, {"coverPath": _portable_cover_path(path, cover), GAME_AUTO_COVER_SCANNED_FIELD: true})

class FakePicker extends Picker:
    var body := PackedByteArray()
    var thumbnail := PackedByteArray()
    var network_error := OK
    var hold := false
    var calls: Array[Dictionary] = []
    signal response_ready
    func _request(url: String, payload: Dictionary = {}) -> Dictionary:
        calls.append({"url": url, "payload": payload})
        if hold:
            await response_ready
        else:
            await get_tree().process_frame
        return {"error": network_error, "body": thumbnail if url.contains("/cv.t/") else body}

var host: Host
var controller
var failures := 0
func _initialize() -> void:
    call_deferred("_run")
func _expect(ok: bool, message: String) -> void:
    if not ok:
        failures += 1
        push_error(message)
func _button(name_value: String) -> Button:
    var button := host.find_child(name_value, true, false) as Button
    _expect(button != null, "Missing button: " + name_value)
    return button
func _settle() -> void:
    await create_timer(0.25).timeout
    for frame in range(8):
        await process_frame
    controller._process(0.2)
func _click(name_value: String) -> void:
    _button(name_value).pressed.emit()
    await _settle()
func _capture(name_value: String) -> void:
    var destination := OS.get_environment("AETHERKIRI_ASTRYX_CAPTURE_DIR")
    if destination.is_empty() or DisplayServer.get_name() == "headless":
        return
    await RenderingServer.frame_post_draw
    root.get_texture().get_image().save_png(destination.path_join(name_value + ".png"))

func _run() -> void:
    create_timer(80).timeout.connect(func(): quit(1))
    var fixture := DirAccess.create_temp("aether-cover-sources")
    var game_root := fixture.get_current_dir().path_join("游戏")
    DirAccess.make_dir_recursive_absolute(game_root)
    host = Host.new()
    host.active_language = host.LANG_ZH_HANS
    host.language_mode = host.LANG_ZH_HANS
    host.covers_directory = fixture.get_current_dir().path_join("Covers")
    host.known_games = [{"name": "封面测试", "path": game_root, "type": "Directory"}]
    controller = Suite.TestController.new()
    controller.name = "ShellInterface"
    controller.preference_path = fixture.get_current_dir().path_join("preferences.cfg")
    host.add_child(controller)
    root.size = Vector2i(1194, 834)
    root.content_scale_size = Vector2i.ZERO
    root.add_child(host)
    await _settle()
    controller.set_enabled(true, false)
    host._show_detail(host.known_games[0])
    await _settle()
    await _click("AstryxDetailSection_cover")
    await _click("AstryxSetCover")
    _expect(host.find_child("AstryxCoverSource_photos", true, false) == null, "Actual desktop runtime hides photos")
    await _capture("astryx-godot-desktop-cover-sources")
    await _click("AstryxCoverClose")
    for platform in ["macOS", "Windows", "Linux", "Web", "iOS", "Android"]:
        host.photo_platform = platform
        await _click("AstryxSetCover")
        var photo := host.find_child("AstryxCoverSource_photos", true, false)
        _expect((photo != null) == (platform in ["iOS", "Android"]), "Photo source is mobile-only: " + platform)
        _expect(host.find_child("AstryxCoverDialogTitle", true, false).text == "选择封面来源", "Source dialog has the requested title")
        _expect(not host.cover_picker_opened and not host.photos_opened, "Opening sources does not launch a picker")
        await _click("AstryxCoverClose")
    host.photo_platform = "iOS"
    await _click("AstryxSetCover")
    for sample in [[Vector2i(1194, 834), "ipad"], [Vector2i(834, 1194), "ipad-portrait"], [Vector2i(393, 852), "iphone"]]:
        root.size = sample[0]
        host._fit_full_rects()
        await _settle()
        var dialog: Control = host.active_modal_dialog
        _expect(Rect2(Vector2.ZERO, root.size).grow(-15).encloses(dialog.get_global_rect()), "Source dialog fits after rotation")
        var previous: Button
        for mode in ["local", "vndb", "photos"]:
            var button := _button("AstryxCoverSource_" + mode)
            _expect(button.size.y >= 56 and dialog.get_global_rect().encloses(button.get_global_rect()), "Source touch target fits the sheet")
            if previous != null:
                _expect(is_equal_approx(button.size.y, previous.size.y) and button.global_position.y - previous.get_global_rect().end.y >= 11.5, "Source rows have equal height and clear gaps")
            previous = button
        await _capture("astryx-godot-%s-cover-sources" % sample[1])
    await _click("AstryxCoverSource_photos")
    _expect(host.photos_opened and not host.modal_layer.visible, "Photo action dismisses the source sheet and opens the native picker")
    await _click("AstryxSetCover")
    await _click("AstryxCoverSource_local")
    _expect(host.cover_picker_opened and not host.modal_layer.visible, "Local action delegates to the existing file picker")
    controller.draft_theme = "dark"
    controller.view.rebuild(true)
    await _settle()
    await _click("AstryxSetCover")
    await _capture("astryx-godot-iphone-cover-sources-dark")
    await _click("AstryxCoverClose")
    controller.draft_theme = "light"
    controller.view.rebuild(true)
    await _settle()
    var picker := FakePicker.new()
    picker.show_for(controller.view)
    await _settle()
    await _click("AstryxCoverSource_vndb")
    var input: LineEdit = host.find_child("AstryxCoverSearchInput", true, false)
    _expect(input.text == "封面测试", "VNDB search starts with the game's display name")
    _expect(host.find_child("AstryxCoverSearchResults", true, false).get_child_count() == 0 and not host.find_child("AstryxCoverSearchStatus", true, false).visible, "Before search the result area is blank")
    await _capture("astryx-godot-iphone-cover-search-empty")
    input.text = "自定义关键词"
    var image := Image.create(60, 84, false, Image.FORMAT_RGB8)
    image.fill(Color.SKY_BLUE)
    picker.thumbnail = image.save_png_to_buffer()
    picker.body = JSON.stringify({"results": [{"id": "v17", "title": "A title", "alttitle": "搜索结果", "image": {"url": "https://t.vndb.org/cv/17.jpg", "thumbnail": "https://t.vndb.org/cv.t/17.jpg"}}, {"id": "v20", "image": null}]}).to_utf8_buffer()
    await _click("AstryxCoverSearch")
    _expect(picker.calls[0].payload.filters[2] == "自定义关键词", "Search sends the entered title")
    _expect(_button("AstryxCoverResult_v17") != null and host.applied.is_empty(), "Search results wait for an explicit choice")
    _expect(host.find_child("AstryxCoverThumbnail_v17", true, false).texture != null, "Search results display a decoded thumbnail")
    picker.network_error = ERR_CANT_CONNECT
    await _click("AstryxCoverResult_v17")
    _expect(host.applied.is_empty() and not _button("AstryxCoverResult_v17").disabled, "Download failure keeps the previous cover and permits retry")
    picker.network_error = OK
    picker.body = image.save_png_to_buffer()
    var invalid := FileAccess.open(game_root.path_join("aether_config.json"), FileAccess.WRITE)
    invalid.store_string("{invalid")
    invalid.close()
    await _click("AstryxCoverResult_v17")
    _expect(host.applied.is_empty() and host.modal_layer.visible and DirAccess.get_files_at(game_root).size() == 1, "Save failure keeps the dialog and old cover without leaving a downloaded file")
    DirAccess.remove_absolute(game_root.path_join("aether_config.json"))
    await _click("AstryxCoverResult_v17")
    _expect(host.applied.size() == 1 and host.applied[0].game == game_root, "Result applies only to the selected game")
    _expect(FileAccess.file_exists(host.applied[0].cover) and Image.load_from_file(host.applied[0].cover) != null, "Selected cover is a valid local image")
    _expect(host.applied[0].cover.get_base_dir() == game_root, "Selected cover is saved inside the game folder")
    var saved := CoverConfig.read(game_root)
    _expect(saved.configured and saved.document.cover.vndb_id == "v17" and saved.document.cover.source == "vndb" and saved.path == host.applied[0].cover, "Selecting a result updates the per-game cover configuration")
    var imported_count := DirAccess.get_files_at(game_root).size()
    picker = FakePicker.new()
    picker.show_for(controller.view)
    await _settle()
    await _click("AstryxCoverSource_vndb")
    picker.network_error = ERR_CANT_CONNECT
    await _click("AstryxCoverSearch")
    _expect(host.find_child("AstryxCoverSearchStatus", true, false).text.begins_with("搜索失败"), "Failed search gives a retryable error")
    _expect(not _button("AstryxCoverSearch").disabled, "Failed search enables retry")
    picker.network_error = OK
    picker.body = '{"results":[]}'.to_utf8_buffer()
    await _click("AstryxCoverSearch")
    _expect(host.find_child("AstryxCoverSearchStatus", true, false).text.begins_with("没有找到"), "Empty search has an explicit state")
    picker.hold = true
    _button("AstryxCoverSearch").pressed.emit()
    await _click("AstryxCoverClose")
    picker.response_ready.emit()
    await _settle()
    _expect(host.applied.size() == 1 and DirAccess.get_files_at(game_root).size() == imported_count, "Cancelled network results never change the cover or create files")
    _expect(Picker.parse_rows('{"results":[{"id":"v1","image":{"url":"file:///tmp/image.png"}}]}'.to_utf8_buffer()).is_empty(), "Only VNDB image hosts become results")
    if OS.get_environment("AETHERKIRI_COVER_LIVE") == "1":
        await _live_search(game_root)
    host.queue_free()
    await process_frame
    fixture = null
    print("COVER_SOURCES_OK" if failures == 0 else "COVER_SOURCES_FAILED: %d" % failures)
    quit(0 if failures == 0 else 1)

func _live_search(game_root: String) -> void:
    var picker := Picker.new()
    picker.show_for(controller.view)
    await _settle()
    await _click("AstryxCoverSource_vndb")
    host.find_child("AstryxCoverSearchInput", true, false).text = "planetarian"
    _button("AstryxCoverSearch").pressed.emit()
    var deadline := Time.get_ticks_msec() + 30000
    while _button("AstryxCoverSearch").disabled and Time.get_ticks_msec() < deadline:
        await create_timer(0.1).timeout
    var result: Button = host.find_child("AstryxCoverResult_v34", true, false)
    _expect(result != null, "Live VNDB search returns the expected title")
    if result == null:
        return
    var thumbnail: TextureRect = host.find_child("AstryxCoverThumbnail_v34", true, false)
    for item in host.find_children("AstryxCoverThumbnail_*", "TextureRect", true, false):
        while item.texture == null and Time.get_ticks_msec() < deadline:
            await create_timer(0.1).timeout
        _expect(item.texture != null, "Each live result displays its thumbnail")
    _expect(thumbnail.texture != null, "Live result renders the real cover thumbnail")
    await _capture("astryx-godot-iphone-cover-search")
    result.pressed.emit()
    deadline = Time.get_ticks_msec() + 30000
    while host.modal_layer.visible and Time.get_ticks_msec() < deadline:
        await create_timer(0.1).timeout
    var saved := CoverConfig.read(game_root)
    _expect(not host.modal_layer.visible and saved.document.cover.vndb_id == "v34" and FileAccess.file_exists(saved.path), "Live selection downloads the image and commits per-game configuration")
