extends SceneTree

const MAIN_SCRIPT := preload("res://scripts/main.gd")

func _initialize() -> void:
    call_deferred("_run")

func _run() -> void:
    var app = MAIN_SCRIPT.new()
    assert(app.picture_in_picture_enabled)
    assert(not app.mobile_window_game_active)
    assert("picture_in_picture_enabled" in app.SETTINGS_DRAFT_KEYS)
    var snapshot: Dictionary = app._current_settings_snapshot()
    assert(snapshot.picture_in_picture_enabled)
    app._begin_settings_edit()
    app._on_setting_toggle("picture_in_picture", false)
    assert(not app.settings_draft.picture_in_picture_enabled)
    assert(app.picture_in_picture_enabled) # A draft must not change live behavior.
    snapshot.picture_in_picture_enabled = false
    app._apply_settings_snapshot(snapshot)
    assert(not app.picture_in_picture_enabled)
    assert(not app._current_settings_snapshot().picture_in_picture_enabled)
    app._apply_settings_snapshot({}) # Older snapshots preserve the current choice.
    assert(not app.picture_in_picture_enabled)
    for language in ["zh_hans", "zh_hant", "en", "ja", "ko"]:
        app.active_language = language
        for key in ["settings.picture_in_picture", "settings.picture_in_picture_desc",
                "detail.delete_game", "dialog.delete_game_body", "message.game_delete_failed"]:
            assert(app._t(key) != key)
    app.free()
    print("MOBILE_WINDOW_SETTINGS_OK: default, draft, apply, localization")
    quit(0)
