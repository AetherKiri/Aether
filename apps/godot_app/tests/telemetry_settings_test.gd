extends SceneTree

const ENDPOINT := "https://telemetry.example.invalid/v1/events"

class TestCollector:
    extends "res://scripts/telemetry.gd"
    var id_path := ""
    var allow_removal := true

    func _install_id_path() -> String:
        return id_path

    func _remove_install_id() -> bool:
        return allow_removal and super._remove_install_id()

    func _start_post(_body: String, _generation: int, _token: int) -> Error:
        return ERR_UNAVAILABLE

class TestHost:
    extends "res://scripts/main.gd"
    var preference_path := ""
    var endpoint := ""
    var announcement_offered := false

    func _startup_notices_suppressed() -> bool:
        return false

    func _maybe_show_notice() -> void:
        announcement_offered = true

    func _telemetry_preference_path() -> String:
        return preference_path

    func _telemetry_endpoint() -> String:
        return endpoint

    func _ready() -> void:
        ui_motion.reduced_motion = true
        add_child(ui_motion)
        _apply_ui_font()
        _build_ui()

    func _process(_delta: float) -> void:
        pass

class TestController:
    extends "res://scripts/ui/astryx/shell_interface.gd"

    func load_preferences(_path: String = "") -> void:
        pass

var failures := 0

func _initialize() -> void:
    _run.call_deferred()

func _expect(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error(message)

func _settle() -> void:
    for _i in range(6):
        await process_frame

func _expect_disclosure(root_node: Node, app: TestHost) -> void:
    var labels := root_node.find_children("*", "Label", true, false)
    var visible_text := PackedStringArray()
    for label: Label in labels:
        visible_text.append(label.text)
    var items := app._t("settings.telemetry_desc").split("\n", false)
    for item in items:
        _expect(visible_text.has(item.trim_prefix("• ")), "Disclosure presents each paragraph or list item separately")
    _expect(visible_text.count("•") == 5, "Each of the five data categories has its own anchored bullet")

func _expect_switch_layout(toggle: Button, app: TestHost) -> void:
    var header := toggle.get_parent() as HBoxContainer
    _expect(header != null and header.name == "TelemetryConsentHeader", "Switch is in a horizontal title row")
    if header == null:
        return
    var title := header.get_child(0) as Label
    _expect(title != null and title.text == app._t("settings.telemetry") and title.get_index() < toggle.get_index(),
        "Switch sits after the localized title")
    var copy := header.get_parent().get_node_or_null("TelemetryDisclosure") as VBoxContainer
    _expect(copy != null and copy.get_index() > header.get_index(), "Disclosure uses the full width below the title and switch")
    if copy != null:
        _expect_disclosure(copy, app)

func _run() -> void:
    var base := "user://telemetry-settings-test-%s" % Time.get_ticks_usec()
    if DirAccess.make_dir_absolute(base) != OK:
        quit(1)
        return
    var app := TestHost.new()
    app.active_language = app.LANG_EN
    app.preference_path = base.path_join("preferences.cfg")
    var collector := TestCollector.new()
    collector.id_path = base.path_join("install_id")
    collector.configure(ENDPOINT, "1.0.0", "dev", "dev")
    app.telemetry = collector
    app.add_child(collector)
    var controller := TestController.new()
    controller.name = "ShellInterface"
    app.add_child(controller)
    root.add_child(app)
    await _settle()

    _expect(not app.telemetry_enabled and not FileAccess.file_exists(collector.id_path), "A fresh install remains off and creates no identity")
    _expect(not FileAccess.file_exists(app.preference_path), "No consent preference is written on startup")
    for language in [app.LANG_ZH_HANS, app.LANG_ZH_HANT, app.LANG_EN, app.LANG_JA, app.LANG_KO, app.LANG_ES]:
        for key in ["settings.section.privacy", "settings.telemetry", "settings.telemetry_desc", "settings.telemetry_unavailable", "settings.telemetry_enable_error", "settings.telemetry_revoke_error", "settings.telemetry_cleanup_error", "settings.telemetry_retry_disable"]:
            _expect(app.UI_TEXT[language].has(key) and not String(app.UI_TEXT[language][key]).is_empty(), "%s provides %s" % [language, key])

    controller.set_enabled(false, false)
    app._show_settings()
    await _settle()
    var classic := app.settings_view.find_child("TelemetryConsentSwitch", true, false) as Button
    var status := app.settings_view.find_child("TelemetryConsentStatus", true, false) as Label
    _expect(classic != null and classic.is_visible_in_tree() and classic.disabled and not classic.button_pressed,
        "Classic Settings shows a disabled switch when no service is configured")
    _expect(status != null and status.is_visible_in_tree() and status.text.contains("no telemetry service"),
        "The unavailable state is explained in the current language")
    if classic != null:
        _expect_switch_layout(classic, app)

    app.endpoint = ENDPOINT
    controller.set_enabled(true, false)
    await _settle()
    _expect(not app.shell_content.visible, "Astryx uses its own active Settings presenter")
    var category := controller.view.find_child("AstryxSection_privacy", true, false) as Button
    _expect(category != null and category.is_visible_in_tree(), "Astryx exposes a Privacy category")
    if category != null:
        category.pressed.emit()
    await _settle()
    var astryx := controller.view.find_child("AstryxTelemetryConsentSwitch", true, false) as Button
    _expect(astryx != null and astryx.is_visible_in_tree() and not astryx.disabled and not astryx.button_pressed,
        "Astryx shows the configured switch off by default")
    if astryx != null:
        _expect_switch_layout(astryx, app)
        astryx.button_pressed = true
    _expect(app.telemetry_enabled and FileAccess.file_exists(collector.id_path), "Explicit opt-in enables the collector immediately")
    _expect(FileAccess.file_exists(app.preference_path) and not app.dirty_settings, "Opt-in persists separately from ordinary settings")
    app._discard_settings_draft()
    _expect(app.telemetry_enabled, "Discarding ordinary Settings changes preserves opt-in")

    var restarted := TestHost.new()
    restarted.preference_path = app.preference_path
    restarted.endpoint = ENDPOINT
    restarted._load_telemetry_preference()
    _expect(restarted.telemetry_enabled, "Consent loads on restart for the same endpoint and notice")
    restarted.endpoint = "https://other.example.invalid/v1/events"
    restarted._load_telemetry_preference()
    _expect(not restarted.telemetry_enabled, "A different endpoint requires fresh consent")
    restarted.endpoint = ENDPOINT
    var cfg := ConfigFile.new()
    _expect(cfg.load(app.preference_path) == OK, "The privacy preference is a readable ConfigFile")
    cfg.set_value("telemetry", "notice_version", app.TELEMETRY_NOTICE_VERSION + 1)
    _expect(cfg.save(app.preference_path) == OK, "A newer notice can be represented in the preference file")
    restarted._load_telemetry_preference()
    _expect(not restarted.telemetry_enabled, "A different notice version requires fresh consent")

    controller.set_enabled(false, false)
    await _settle()
    classic = app.settings_view.find_child("TelemetryConsentSwitch", true, false) as Button
    _expect(classic != null and classic.button_pressed and not classic.disabled, "Classic Settings shows the consent set in Astryx")
    collector.allow_removal = false
    app.telemetry_engine = "kirikiri"
    app.telemetry_game_name = "Fixture game"
    if classic != null:
        classic.button_pressed = false
    _expect(not app.telemetry_enabled and not collector._consent and collector._events.is_empty(),
        "Opting out stops and purges telemetry even when identity cleanup fails")
    _expect(app.telemetry_engine.is_empty() and app.telemetry_game_name.is_empty(), "Opt-out clears retained game metadata")
    restarted._load_telemetry_preference()
    _expect(not restarted.telemetry_enabled, "Opt-out persists despite identity cleanup failure")
    var retry := app.settings_view.find_child("TelemetryConsentRetry", true, false) as Button
    _expect(retry != null and retry.is_visible_in_tree(), "Settings exposes cleanup retry without raw diagnostics")
    collector.allow_removal = true
    if retry != null:
        retry.pressed.emit()
    _expect(not FileAccess.file_exists(collector.id_path) and not app.telemetry_enabled, "Cleanup retry removes the ID without enabling telemetry")

    var preference_path := app.preference_path
    app.preference_path = base.path_join("absent/preferences.cfg")
    if classic != null:
        classic.button_pressed = true
    _expect(classic != null and not classic.button_pressed and not collector._consent and collector._events.is_empty(),
        "If consent cannot be saved, the switch returns to off and no queued data survives")
    _expect(not FileAccess.file_exists(collector.id_path), "A failed opt-in leaves no identity")
    app.preference_path = preference_path

    controller.set_enabled(true, false)
    await _exercise_startup_notice(app, restarted, collector, base)
    restarted.free()
    app.queue_free()
    await _settle()
    DirAccess.remove_absolute(base.path_join("preferences.cfg"))
    DirAccess.remove_absolute(base)
    if failures == 0:
        print("TELEMETRY_SETTINGS_OK")
    quit(failures)

func _exercise_startup_notice(app: TestHost, restarted: TestHost, collector: TestCollector, base: String) -> void:
    app.preference_path = base.path_join("startup.cfg")
    restarted.preference_path = app.preference_path
    app._load_telemetry_preference()
    for language in app.UI_TEXT:
        for key in ["notice.telemetry_title", "notice.telemetry_optional", "notice.telemetry_decline", "notice.telemetry_accept", "notice.telemetry_decline_error"]:
            _expect(app.UI_TEXT[language].has(key), "%s provides %s" % [language, key])
    _expect(not app._should_offer_telemetry_at_startup(), "The notice waits for the legal gate")
    app.legal_gate_completed = true
    app.legal_accepted_version = app.LEGAL_AGREEMENT_VERSION
    app.ios_statement_accepted_version = app.IOS_STATEMENT_VERSION
    app.endpoint = ""
    _expect(not app._should_offer_telemetry_at_startup(), "Unconfigured builds do not ask for consent")
    app.endpoint = ENDPOINT
    _expect(app._should_offer_telemetry_at_startup(), "The configured build offers consent after the legal gate")
    app._maybe_show_startup_notices()
    await _settle()
    var dialog := app.active_modal_dialog
    _expect(dialog != null and dialog.name == "TelemetryConsentNotice" and not app.announcement_offered,
        "The startup notice appears before the existing announcement")
    if dialog == null:
        return
    var disclosure := dialog.find_child("TelemetryConsentNoticeDisclosure", true, false) as VBoxContainer
    _expect(disclosure != null, "The notice discloses the Settings data categories")
    if disclosure != null:
        _expect_disclosure(disclosure, app)
    app._handle_go_back_request()
    await create_timer(0.3).timeout
    _expect(app.announcement_offered and app._should_offer_telemetry_at_startup() and not FileAccess.file_exists(app.preference_path),
        "Back continues to the existing announcement and leaves the next startup eligible without saving consent")

    app._show_telemetry_consent_notice()
    var accept := app.active_modal_dialog.find_child("AcceptTelemetryConsent", true, false) as Button
    _expect(accept != null, "The consent notice offers explicit opt-in")
    if accept != null:
        accept.pressed.emit()
    await create_timer(0.3).timeout
    restarted._load_telemetry_preference()
    _expect(app.telemetry_enabled and restarted.telemetry_enabled and not app._should_offer_telemetry_at_startup(),
        "Agree enables and persists consent without re-prompting")
    app._set_telemetry_preference(false)
    restarted._load_telemetry_preference()
    _expect(not restarted.telemetry_enabled and restarted.telemetry_prompt_dismissed,
        "Turning telemetry off in Settings suppresses future prompts")

    DirAccess.remove_absolute(app.preference_path)
    app._load_telemetry_preference()
    app._show_telemetry_consent_notice()
    var decline := app.active_modal_dialog.find_child("DeclineTelemetryConsent", true, false) as Button
    _expect(decline != null, "The consent notice offers permanent rejection")
    if decline != null:
        decline.pressed.emit()
    await create_timer(0.3).timeout
    restarted._load_telemetry_preference()
    _expect(not app.modal_layer.visible and not restarted.telemetry_enabled and restarted.telemetry_prompt_dismissed,
        "Explicit rejection continues and survives restart")
    _expect(not collector._consent and not FileAccess.file_exists(collector.id_path), "Rejection keeps telemetry off and leaves no identity")
    _expect(not app._should_offer_telemetry_at_startup(), "Rejected prompts stay suppressed")
    DirAccess.remove_absolute(app.preference_path)
