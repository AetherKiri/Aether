extends RefCounted

# The provider supplies the game's native dialog labels, control types and
# layout. The host supplies platform widgets and returns their edited values.
var controls: Dictionary = {}
var buttons: Dictionary = {}
var completed: bool = false
var callback: Callable

static func valid(specification: Dictionary) -> bool:
    for dimension in ["width", "height"]:
        var value: Variant = specification.get(dimension)
        if not (value is int or value is float) or not is_finite(float(value)) or float(value) <= 0 or float(value) > 4096:
            return false
    var items: Variant = specification.get("items")
    if not items is Array or items.is_empty() or items.size() > 256:
        return false
    var ids := {}
    var has_button := false
    for item in items:
        if not item is Dictionary:
            return false
        var kind := String(item.get("kind", ""))
        if kind not in ["label", "button", "select", "multiline"]:
            return false
        var rectangle: Variant = item.get("rect")
        if not rectangle is Array or rectangle.size() != 4:
            return false
        for coordinate in rectangle:
            if not (coordinate is int or coordinate is float) or not is_finite(float(coordinate)) or float(coordinate) < 0 or float(coordinate) > 4096:
                return false
        if rectangle[2] <= 0 or rectangle[3] <= 0:
            return false
        var id := String(item.get("id", ""))
        if kind != "label":
            if id.is_empty() or ids.has(id):
                return false
            ids[id] = true
        if kind == "button":
            has_button = true
        if kind == "select":
            var options: Variant = item.get("options")
            var selected := int(item.get("selected", -1))
            if not options is Array or options.is_empty() or options.size() > 256 or selected < 0 or selected >= options.size():
                return false
        if String(item.get("text", "")).length() > 16384 or String(item.get("value", "")).length() > 16384:
            return false
    return has_button

func build(parent: Control, specification: Dictionary, on_complete: Callable) -> void:
    assert(valid(specification))
    callback = on_complete
    var box := VBoxContainer.new()
    box.add_theme_constant_override("separation", 16)
    parent.add_child(box)
    var title := Label.new()
    title.text = String(specification.get("title", ""))
    title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    title.add_theme_font_size_override("font_size", 24)
    box.add_child(title)
    var area := Control.new()
    area.name = "NativeDialogControls"
    area.size_flags_vertical = Control.SIZE_EXPAND_FILL
    area.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    box.add_child(area)
    var source_size := Vector2(float(specification.get("width", 1)), float(specification.get("height", 1)))
    var layout: Array[Dictionary] = []
    for raw in specification.get("items", []):
        var item: Dictionary = raw
        var id := String(item.get("id", ""))
        var kind := String(item.get("kind", ""))
        var widget: Control
        if kind == "label":
            var label := Label.new()
            label.text = String(item.get("text", ""))
            widget = label
        elif kind == "button":
            var button := Button.new()
            button.text = String(item.get("text", ""))
            button.pressed.connect(submit.bind(id))
            buttons[id] = button
            widget = button
        elif kind == "select":
            var choice := OptionButton.new()
            for option in item.get("options", []):
                choice.add_item(String(option))
            choice.select(int(item.get("selected", 0)))
            controls[id] = choice
            widget = choice
        elif kind == "multiline":
            var input := TextEdit.new()
            input.text = String(item.get("value", ""))
            input.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
            controls[id] = input
            widget = input
        else:
            push_error("Unsupported runtime form control: " + kind)
            continue
        widget.name = "NativeControl_" + id
        widget.add_theme_font_size_override("font_size", 18)
        area.add_child(widget)
        var rectangle: Array = item.get("rect", [0, 0, 1, 1])
        # Native combo-box height includes its open list. Its closed height
        # matches a normal button; the platform owns the popup list.
        var height := minf(float(rectangle[3]), 14.0) if kind == "select" else float(rectangle[3])
        layout.append({"widget": widget, "rect": Rect2(float(rectangle[0]), float(rectangle[1]), float(rectangle[2]), height)})
    var arrange := func() -> void:
        var scale := minf(area.size.x / maxf(1, source_size.x), area.size.y / maxf(1, source_size.y))
        var origin := (area.size - source_size * scale) * 0.5
        for entry in layout:
            var rectangle: Rect2 = entry.rect
            var widget: Control = entry.widget
            widget.position = origin + rectangle.position * scale
            widget.size = rectangle.size * scale
    area.resized.connect(arrange)
    arrange.call_deferred()
    if not controls.is_empty():
        controls.values()[0].call_deferred("grab_focus")

func values() -> Dictionary:
    var result: Dictionary = {}
    for id in controls:
        var widget: Control = controls[id]
        if widget is OptionButton:
            result[id] = widget.selected
        elif widget is TextEdit:
            result[id] = widget.text
    return result

func set_values(edits: Dictionary) -> bool:
    # Validate the complete edit before changing any control.
    for id in edits:
        if not controls.has(id):
            return false
        var widget: Control = controls[id]
        if widget is OptionButton:
            if not (edits[id] is int or edits[id] is float):
                return false
            var selected := int(edits[id])
            if selected < 0 or selected >= widget.item_count:
                return false
        elif widget is TextEdit and (not edits[id] is String or edits[id].length() > 16384):
            return false
    for id in edits:
        var widget: Control = controls[id]
        if widget is OptionButton:
            widget.select(int(edits[id]))
        elif widget is TextEdit:
            widget.text = String(edits[id])
    return true

func submit(id: String) -> void:
    if completed or not buttons.has(id):
        return
    completed = true
    callback.call({"result": id, "values": values()})

func cancel() -> void:
    # IDCANCEL is the native dialog's cancellation result.
    if buttons.has("2"):
        submit("2")
