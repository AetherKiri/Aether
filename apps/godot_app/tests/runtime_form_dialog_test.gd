extends SceneTree

const Form = preload("res://scripts/runtime_form_dialog.gd")
var responses: Array = []

func _initialize() -> void:
    call_deferred("run")

func run() -> void:
    var panel := PanelContainer.new()
    panel.size = Vector2(900, 430)
    root.add_child(panel)
    assert(not Form.valid({}))
    assert(not Form.valid({"width": 1, "height": 1, "items": [{"kind": "button", "id": "ok", "rect": [0, 0]}]}))
    var form := Form.new()
    form.build(panel, {
        "title": "Native fixture", "width": 300, "height": 100,
        "items": [
            {"kind": "label", "id": "label", "text": "Name", "rect": [5, 5, 35, 10]},
            {"kind": "select", "id": "name", "options": ["Alpha", "Beta"], "selected": 0, "rect": [45, 5, 65, 80]},
            {"kind": "multiline", "id": "body", "value": "Original", "rect": [5, 30, 290, 40]},
            {"kind": "button", "id": "1", "text": "OK", "rect": [180, 78, 50, 15]},
            {"kind": "button", "id": "2", "text": "Cancel", "rect": [240, 78, 50, 15]},
        ],
    }, func(value: Dictionary) -> void: responses.append(value))
    await process_frame
    await process_frame
    assert(form.values() == {"name": 0, "body": "Original"})
    assert(not form.set_values({"missing": "ignored"}))
    assert(not form.set_values({"name": 2}))
    assert(not form.set_values({"body": "Should stay original", "name": 2}))
    assert(form.values().body == "Original")
    assert(form.set_values({"name": 1, "body": "第一行\nSecond & <third>"}))
    assert(form.controls.name.size.y < form.controls.body.size.y)
    for widget in form.controls.values():
        assert(widget.position.x >= 0 and widget.position.y >= 0)
        assert(widget.get_rect().end.x <= widget.get_parent().size.x)
        assert(widget.get_rect().end.y <= widget.get_parent().size.y)
    form.buttons["1"].pressed.emit()
    form.buttons["2"].pressed.emit()
    assert(responses.size() == 1)
    assert(responses[0] == {"result": "1", "values": {"name": 1, "body": "第一行\nSecond & <third>"}})
    panel.free()
    print("runtime_form_dialog_test: PASS")
    quit(0)
