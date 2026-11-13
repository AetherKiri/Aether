extends Node
## Source selection and explicit VNDB search; native pickers stay in the host.
const API_URL := "https://api.vndb.org/kana/vn"
var view
var host
var game: Dictionary
var dialog: PanelContainer
var stack: VBoxContainer
var generation := 0

func show_for(shell) -> void:
    view = shell
    host = view.host
    game = host.selected_game.duplicate(true)
    dialog = host._modal_dialog(Vector2(460, 316))
    dialog.name = "AstryxCoverSourceDialog"
    dialog.theme = view.design.native
    dialog.add_theme_stylebox_override("panel", view.design.box("surface", 24, "border", 1, Vector2(24, 24)))
    view.external_modal_id = dialog.get_instance_id()
    dialog.add_child(self)
    stack = view._vbox(20)
    dialog.add_child(stack)
    _sources()

func _text(zh: String, en: String, ja: String = "") -> String:
    return view._text(zh, en, ja)

func _alive(token: int) -> bool:
    return is_instance_valid(dialog) and not dialog.is_queued_for_deletion() and host.modal_layer.visible and host.active_modal_dialog == dialog and generation == token

func _header(title: String, back: bool = false) -> void:
    generation += 1
    view._clear(stack)
    var row: HBoxContainer = view._hbox(12)
    stack.add_child(row)
    if back:
        row.add_child(_icon_button("back", _sources, _text("返回", "Back", "戻る"), "AstryxCoverBack"))
    var label: Label = view._label(title, 20, false, true)
    label.name = "AstryxCoverDialogTitle"
    row.add_child(label)
    row.add_child(_icon_button("close", _close, _text("关闭", "Close", "閉じる"), "AstryxCoverClose"))

func _icon_button(icon: String, action: Callable, label: String, name_value: String) -> Button:
    var button: Button = view._button("", action, "quiet", name_value)
    button.custom_minimum_size = Vector2(44, 44)
    button.accessibility_name = label
    var center := CenterContainer.new()
    center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    center.mouse_filter = Control.MOUSE_FILTER_IGNORE
    center.add_child(view._icon(icon))
    button.add_child(center)
    return button

func _close() -> void:
    generation += 1
    host._dismiss_modal()

func _sources() -> void:
    _header(_text("选择封面来源", "Choose cover source", "カバーの取得元を選択"))
    var sources := [
        ["local", "folder", _text("本地搜索", "Browse local files", "ローカルを検索"), func(): view._dismiss_then(host._set_cover_for_selected)],
        ["vndb", "search", _text("VNDB 搜索", "Search VNDB", "VNDB を検索"), _vndb],
    ]
    if host._can_select_cover_photo():
        sources.append(["photos", "photo", _text("相册搜索", "Browse photos", "写真を選択"), func(): view._dismiss_then(host._select_cover_photo.bind(String(game.path)))])
    host._mark_centered_safe_dialog(dialog, Vector2(460, 112 + sources.size() * 68))
    host._layout_safe_dialog(dialog, host._ui_safe_rect(view.get_viewport_rect().size))
    var options: VBoxContainer = view._vbox(12)
    options.name = "AstryxCoverSources"
    stack.add_child(options)
    for source in sources:
        var button: Button = view._button("", source[3], "secondary", "AstryxCoverSource_" + source[0])
        button.accessibility_name = source[2]
        button.custom_minimum_size.y = 56
        button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        options.add_child(button)
        var pad: MarginContainer = view._margin(16, 0, 16, 0)
        pad.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
        pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
        button.add_child(pad)
        var row: HBoxContainer = view._hbox(12)
        row.mouse_filter = Control.MOUSE_FILTER_IGNORE
        pad.add_child(row)
        row.add_child(view._icon(source[1]))
        var label: Label = view._label(source[2], 16, false, true)
        label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
        row.add_child(label)
        row.add_child(view._icon("chevron_right", 20, "secondary"))

func _vndb() -> void:
    _header(_text("VNDB 搜索", "Search VNDB", "VNDB を検索"), true)
    host._mark_centered_safe_dialog(dialog, Vector2(600, 620))
    host._layout_safe_dialog(dialog, host._ui_safe_rect(view.get_viewport_rect().size))
    var form: HBoxContainer = view._hbox(12)
    stack.add_child(form)
    var input := LineEdit.new()
    input.name = "AstryxCoverSearchInput"
    input.placeholder_text = _text("输入游戏名称", "Enter a game title", "ゲーム名を入力")
    input.accessibility_name = input.placeholder_text
    input.text = host._game_display_title(game)
    input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    input.custom_minimum_size.y = 44
    form.add_child(input)
    view.style_external_modal(input)
    var status: Label = view._label("", 14, true)
    status.name = "AstryxCoverSearchStatus"
    status.hide()
    var scroller := ScrollContainer.new()
    scroller.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    scroller.size_flags_vertical = Control.SIZE_EXPAND_FILL
    var results: VBoxContainer = view._vbox(12)
    results.name = "AstryxCoverSearchResults"
    scroller.add_child(results)
    var submit: Button = view._button(_text("搜索", "Search", "検索"), Callable(), "primary", "AstryxCoverSearch")
    form.add_child(submit)
    submit.pressed.connect(func(): _search(input, status, results, submit))
    input.text_submitted.connect(func(_query): _search(input, status, results, submit))
    stack.add_child(status)
    stack.add_child(scroller)
    input.grab_focus()

func _request(url: String, payload: Dictionary = {}) -> Dictionary:
    var request := HTTPRequest.new()
    request.timeout = 25
    request.body_size_limit = 16 * 1024 * 1024
    add_child(request)
    var error := request.request(url, PackedStringArray(["Content-Type: application/json"]) if not payload.is_empty() else PackedStringArray(), HTTPClient.METHOD_POST if not payload.is_empty() else HTTPClient.METHOD_GET, JSON.stringify(payload) if not payload.is_empty() else "")
    if error != OK:
        request.queue_free()
        return {"error": error, "body": PackedByteArray()}
    var response: Array = await request.request_completed
    request.queue_free()
    return {"error": OK if response[0] == HTTPRequest.RESULT_SUCCESS and response[1] == 200 else ERR_CANT_CONNECT, "body": response[3]}

static func parse_rows(body: PackedByteArray) -> Array[Dictionary]:
    var parsed = JSON.parse_string(body.get_string_from_utf8())
    var rows: Array[Dictionary] = []
    if not parsed is Dictionary or not parsed.get("results") is Array:
        return rows
    for item in parsed.results:
        if not item is Dictionary or not item.get("image") is Dictionary:
            continue
        var id := str(item.get("id", ""))
        var url := str(item.image.get("url", ""))
        if not id.begins_with("v") or not id.substr(1).is_valid_int() or not _image_url(url):
            continue
        var alternate = item.get("alttitle")
        var thumbnail := str(item.image.get("thumbnail", ""))
        rows.append({"id": id, "title": alternate if alternate is String and not alternate.is_empty() else str(item.get("title", id)),
            "url": url, "thumbnail": thumbnail if _image_url(thumbnail) else url})
    return rows

static func _image_url(url: String) -> bool:
    return url.begins_with("https://t.vndb.org/") or url.begins_with("https://s.vndb.org/")

static func decode_image(body: PackedByteArray) -> Image:
    var image := Image.new()
    var error := ERR_FILE_UNRECOGNIZED
    if body.size() >= 8 and body.slice(0, 8).hex_encode() == "89504e470d0a1a0a":
        error = image.load_png_from_buffer(body)
    elif body.size() >= 3 and body[0] == 255 and body[1] == 216:
        error = image.load_jpg_from_buffer(body)
    elif body.size() >= 12 and body.slice(8, 12).get_string_from_ascii() == "WEBP":
        error = image.load_webp_from_buffer(body)
    return image if error == OK and not image.is_empty() else null

func _search(input: LineEdit, status: Label, results: VBoxContainer, submit: Button) -> void:
    var query := input.text.strip_edges()
    if query.is_empty() or submit.disabled:
        return
    generation += 1
    var token := generation
    input.release_focus()
    if OS.get_name() in ["iOS", "Android"]:
        DisplayServer.virtual_keyboard_hide()
    view._clear(results)
    status.show()
    status.text = _text("正在搜索…", "Searching…", "検索中…")
    submit.disabled = true
    var response: Dictionary = await _request(API_URL, {"filters": ["search", "=", query], "fields": "title,alttitle,image.url,image.thumbnail", "sort": "searchrank", "results": 20})
    if not _alive(token):
        return
    submit.disabled = false
    if response.error != OK:
        status.text = _text("搜索失败，请检查网络后重试。", "Search failed. Check the connection and retry.", "検索できません。接続を確認して再試行してください。")
        return
    var rows := parse_rows(response.body)
    status.text = _text("没有找到带封面的结果，请尝试其他名称。", "No covers found. Try another title.", "カバーが見つかりません。別の名前をお試しください。") if rows.is_empty() else _text("选择结果以设置封面。", "Choose a result to set its cover.", "結果を選択してカバーを設定します。")
    for row in rows:
        var button: Button = view._button("", Callable(), "secondary", "AstryxCoverResult_" + row.id)
        button.add_theme_stylebox_override("normal", view.design.box("surface", 12, "border", 1))
        button.add_theme_stylebox_override("hover", view.design.box("subtle", 12, "border", 1))
        button.add_theme_stylebox_override("pressed", view.design.box("selected", 12, "input_border", 1))
        button.accessibility_name = row.title
        button.custom_minimum_size.y = 108
        button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        button.pressed.connect(func(): _select_result(row, status, results, submit))
        results.add_child(button)
        var pad: MarginContainer = view._margin(12, 12, 12, 12)
        pad.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
        pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
        button.add_child(pad)
        var content: HBoxContainer = view._hbox(12)
        content.mouse_filter = Control.MOUSE_FILTER_IGNORE
        pad.add_child(content)
        var thumbnail := TextureRect.new()
        thumbnail.name = "AstryxCoverThumbnail_" + row.id
        thumbnail.custom_minimum_size = Vector2(60, 84)
        thumbnail.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
        thumbnail.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
        thumbnail.mouse_filter = Control.MOUSE_FILTER_IGNORE
        content.add_child(thumbnail)
        var label: Label = view._label(row.title, 16, false, true)
        label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
        label.max_lines_visible = 3
        label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
        content.add_child(label)
        content.add_child(view._icon("chevron_right", 20, "secondary"))
        _load_thumbnail(row.thumbnail, thumbnail, token)

func _load_thumbnail(url: String, target: TextureRect, token: int) -> void:
    if not _image_url(url):
        return
    var response: Dictionary = await _request(url)
    if not _alive(token) or not is_instance_valid(target) or response.error != OK:
        return
    var image := decode_image(response.body)
    if image != null:
        target.texture = ImageTexture.create_from_image(image)

func _select_result(row: Dictionary, status: Label, results: VBoxContainer, submit: Button) -> void:
    generation += 1
    var token := generation
    submit.disabled = true
    for child in results.get_children():
        if child is Button:
            child.disabled = true
    status.text = _text("正在下载封面…", "Downloading cover…", "カバーをダウンロード中…")
    var response: Dictionary = await _request(row.url)
    if not _alive(token):
        return
    var image: Image = decode_image(response.body) if response.error == OK else null
    var saved: Dictionary = host._save_cover_image(String(game.path), image, "vndb", row.id) if image != null else {"error": ERR_CANT_CONNECT}
    if saved.error != OK:
        submit.disabled = false
        for child in results.get_children():
            if child is Button:
                child.disabled = false
        status.text = host._t("message.cover_save_failed") if image != null else _text("封面下载失败，请重试。", "Could not download the cover. Retry.", "カバーを取得できません。再試行してください。")
        return
    view._dismiss_then(func(): host._show_detail(host.selected_game))
