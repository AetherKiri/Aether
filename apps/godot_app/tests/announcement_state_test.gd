extends SceneTree

const AnnouncementState = preload("res://scripts/announcement_state.gd")
const MAIN_SCRIPT = preload("res://scripts/main.gd")

class AnnouncementApp:
    extends "res://scripts/main.gd"

    func _ready() -> void:
        pass

    func _notification(_what: int) -> void:
        pass

func _initialize() -> void:
    call_deferred("_run")

func _run() -> void:
    var path := "user://announcement-test-%d-%d.cfg" % [OS.get_process_id(), Time.get_ticks_usec()]
    var state := AnnouncementState.new(path)
    var id: String = MAIN_SCRIPT.NOTICE_ID
    var now := 1000000
    assert(state.should_show(id, 1, now))

    # Existing weekly/today snoozes only apply to the original announcement.
    var legacy := ConfigFile.new()
    legacy.set_value(id, "snoozed_until", now + 7 * 86400)
    assert(legacy.save(path) == OK)
    assert(not state.should_show(id, 1, now))
    assert(state.should_show(id, 1, now + 7 * 86400))
    assert(state.should_show(id, 2, now))

    # Permanent dismissal survives restart and the passage of weeks or years.
    assert(state.dismiss(id, 1) == OK)
    state = AnnouncementState.new(path)
    assert(not state.should_show(id, 1, now))
    assert(not state.should_show(id, 1, now + 365 * 86400))
    assert(state.should_show(id, 2, now))
    assert(state.should_show("another-announcement", 1, now))

    # Today's choice expires at its deadline and never hides a new revision.
    assert(state.snooze(id, 2, now + 3600) == OK)
    state = AnnouncementState.new(path)
    assert(not state.should_show(id, 2, now + 3599))
    assert(state.should_show(id, 2, now + 3600))
    assert(state.should_show(id, 3, now))
    assert(not state.should_show(id, 1, now + 365 * 86400))
    assert(state.dismiss(id, 2) == OK)
    assert(state.dismiss(id, 1) == OK)
    assert(not state.should_show(id, 2, now + 365 * 86400))
    assert(not state.should_show(id, 1, now))
    assert(state.should_show(id, 3, now))
    assert(DirAccess.remove_absolute(path) == OK)

    # Exercise the actual left-hand button with an isolated preference file.
    var app = AnnouncementApp.new()
    app.process_mode = Node.PROCESS_MODE_DISABLED
    app.announcement_state = AnnouncementState.new(path)
    app.active_language = "zh_hans"
    app.ui_motion.reduced_motion = true
    app.modal_layer = Control.new()
    app.add_child(app.modal_layer)
    root.add_child(app)
    app._show_notice()
    var dismiss := app.modal_layer.find_child("DismissAnnouncement", true, false) as Button
    var today := app.modal_layer.find_child("SnoozeAnnouncementToday", true, false) as Button
    assert(dismiss != null and today != null)
    assert(dismiss.text == "不再展示")
    assert(dismiss.get_index() < today.get_index())
    dismiss.pressed.emit()
    state = AnnouncementState.new(path)
    assert(not state.should_show(id, app.NOTICE_VERSION, now + 365 * 86400))
    assert(state.should_show(id, app.NOTICE_VERSION + 1, now))

    # All supported UI languages name both choices without falling back.
    for language in ["zh_hans", "zh_hant", "en", "ja", "ko"]:
        for key in ["notice.title", "notice.dismiss", "notice.dismiss_hint", "notice.skip_today", "notice.save_failed"]:
            assert(app.UI_TEXT[language].has(key))

    assert(DirAccess.remove_absolute(path) == OK)
    app._show_notice()
    await process_frame
    today = app.modal_layer.find_child("SnoozeAnnouncementToday", true, false) as Button
    today.pressed.emit()
    var current_time := int(Time.get_unix_time_from_system())
    assert(not state.should_show(id, app.NOTICE_VERSION, current_time))
    assert(state.should_show(id, app.NOTICE_VERSION + 1, current_time))
    assert(state.should_show(id, app.NOTICE_VERSION, current_time + 86400))

    app.modal_layer.free()
    app.ui_motion.free()
    app.free()
    assert(DirAccess.remove_absolute(path) == OK)
    print("ANNOUNCEMENT_STATE_OK")
    quit(0)
