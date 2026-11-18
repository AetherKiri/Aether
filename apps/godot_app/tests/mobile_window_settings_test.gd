extends SceneTree

const MAIN_SCRIPT := preload("res://scripts/main.gd")
const SHELL_SCRIPT := preload("res://scripts/ui/astryx/shell_interface.gd")

class MobileHost extends "res://scripts/main.gd":
    func _mobile_runtime() -> bool:
        return true
    func _is_touch_platform() -> bool:
        return true
    func _apply_host_frame_rate_limit(_runtime_active: bool = false) -> void:
        pass

class WindowBridge extends Node:
    var active := false
    var pip := false
    var background := Color.BLACK
    func configure(game_active: bool, pip_enabled: bool, _player, shell_background: Color) -> void:
        active = game_active
        pip = pip_enabled
        background = shell_background

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
    for language in ["zh_hans", "zh_hant", "en", "ja", "ko", "es"]:
        app.active_language = language
        for key in ["settings.picture_in_picture", "settings.picture_in_picture_desc",
                "detail.delete_game", "dialog.delete_game_body", "message.game_delete_failed"]:
            assert(app._t(key) != key)
    app.free()
    _test_system_bars()
    print("MOBILE_WINDOW_SETTINGS_OK: default, draft, apply, localization, shell/game system bars")
    quit(0)

func _test_system_bars() -> void:
    assert(not ProjectSettings.get_setting("display/window/ios/hide_status_bar", true))
    var app := MobileHost.new()
    var bridge := WindowBridge.new()
    app.add_child(bridge)
    app.mobile_window = bridge
    var shell := SHELL_SCRIPT.new()
    shell.name = "ShellInterface"
    shell.host = app
    app.add_child(shell)
    for mode in ["light", "dark"]:
        shell.draft_theme = mode
        app._set_game_runtime_orientation(false)
        assert(not bridge.active)
        assert((bridge.background.get_luminance() > 0.5) == (mode == "light"))
        app._set_game_runtime_orientation(true)
        assert(bridge.active)
        app.picture_in_picture_enabled = false
        app._configure_mobile_window()
        assert(bridge.active and not bridge.pip) # Fullscreen does not depend on PiP.
        app._set_game_runtime_orientation(false)
        assert(not bridge.active)
    shell.enabled = false
    app.style_mode = app.STYLE_CLASSIC
    app._apply_style_mode(false)
    assert(bridge.background == app.color_bg)
    assert(not bridge.active)
    app.free()
