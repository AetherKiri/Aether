extends SceneTree

const MAIN_SCRIPT := preload("res://scripts/main.gd")
const ACCESS_POLICY := preload("res://scripts/app_access_policy.gd")

class CoffeePlayer:
    extends RefCounted

    var requested_products: Array[String] = []

    func iap_refresh_entitlement(product_id: String) -> int:
        requested_products.append(product_id)
        return 1

class SoftPalAccessApp:
    extends "res://scripts/main.gd"

    var enforce_beta_access := true
    var launched := false
    var denied := false

    func _game_runtime_kind(_path: String) -> String:
        return RUNTIME_SOFTPAL

    func _beta_access_enforcement_enabled(_platform_name: String = "") -> bool:
        return enforce_beta_access

    func _iap_supported_platform() -> bool:
        return true

    func _start_selected_game_after_entitlements() -> void:
        launched = true

    func _show_system_alert(_message: String, _title: String = "Aether") -> void:
        denied = true

var failures := 0

# Assertions are stripped from Release exports; keep these checks active there.
func _expect(passed: bool) -> void:
    if not passed:
        failures += 1
        push_error("IAP catalog/access policy check failed")

func _initialize() -> void:
    # Verify Release policy explicitly; the editor itself is a debug build.
    for platform_name in ["Linux", "Android"]:
        for debug_build in [true, false]:
            for unlocked in [true, false]:
                _expect(not ACCESS_POLICY.catalog_limit_enabled(platform_name, debug_build, unlocked))
            _expect(not ACCESS_POLICY.beta_access_enforced(platform_name, debug_build))
        _expect(not ACCESS_POLICY.purchases_supported(platform_name))
        _expect(ACCESS_POLICY.coffee_sponsorship_available(platform_name))
    for platform_name in ["iOS", "macOS"]:
        _expect(ACCESS_POLICY.catalog_limit_enabled(platform_name, false, false))
        _expect(not ACCESS_POLICY.catalog_limit_enabled(platform_name, true, false))
        _expect(not ACCESS_POLICY.catalog_limit_enabled(platform_name, false, true))
        _expect(ACCESS_POLICY.beta_access_enforced(platform_name, false))
        _expect(not ACCESS_POLICY.beta_access_enforced(platform_name, true))
        _expect(not ACCESS_POLICY.coffee_sponsorship_available(platform_name))
    var app = MAIN_SCRIPT.new()
    var games: Array[Dictionary] = [
        {"path": "/games/first"},
        {"path": "/games/second"},
    ]
    var videos: Array[Dictionary] = [
        {"path": "/videos/first.mp4"},
        {"path": "/videos/second.mp4"},
    ]
    app.known_games = games
    app.known_videos = videos

    _expect(app._iap_item_is_first("game", {"path": "/games/first"}))
    _expect(not app._iap_item_is_first("game", {"path": "/games/second"}))
    _expect(app._iap_item_is_first("video", {"path": "/videos/first.mp4"}))
    _expect(not app._iap_item_is_first("video", {"path": "/videos/second.mp4"}))
    _expect(not app._iap_item_is_first("video", {"path": "/videos/missing.mp4"}))

    # Debug artifacts and Linux releases have no catalog or beta-access limits.
    app.modal_layer = Control.new()
    app.modal_layer.visible = false
    _expect(OS.is_debug_build() or OS.get_name() == "Linux")
    if OS.get_name() == "Linux":
        _expect(not app._iap_supported_platform())
    _expect(not app._iap_enforcement_enabled())
    for intent in ["detail", "launch"]:
        _expect(not app._begin_iap_checked_access("game", games[1], intent))
        _expect(not app._begin_iap_checked_access("video", videos[1], intent))
    _expect(app.iap_pending_launch.is_empty())
    _expect(not app.modal_layer.visible)
    _expect(not app._runtime_requires_beta_access(app.RUNTIME_ONSCRIPTER))
    _expect(app._runtime_requires_beta_access(app.RUNTIME_MINORI))
    _expect(app._runtime_requires_beta_access(app.RUNTIME_SOFTPAL))
    _expect(not app._runtime_requires_beta_access(app.RUNTIME_KIRIKIRI))
    # CatSystem2 is a released runtime and must not enter the coffee-only
    # entitlement path.  WA2 remains the explicitly provider-gated runtime.
    _expect(not app._runtime_requires_beta_access(app.RUNTIME_CATSYSTEM2))
    _expect(not app._runtime_requires_beta_access("rfvp"))
    _expect(not app._beta_access_enforcement_enabled("Android"))
    _expect(not app._beta_access_enforcement_enabled("Linux"))
    _expect(app._beta_access_enforcement_enabled("iOS") == (not OS.is_debug_build()))
    _expect(app._beta_access_enforcement_enabled("macOS") == (not OS.is_debug_build()))
    _expect(app._coffee_sponsorship_available("Android"))
    _expect(app._coffee_sponsorship_available("Linux"))
    _expect(not app._coffee_sponsorship_available("iOS"))
    _expect(not app._coffee_sponsorship_available("macOS"))

    var settings_action := Button.new()
    app._configure_settings_action_button(settings_action)
    _expect(settings_action.custom_minimum_size == Vector2(150, 54))
    _expect(settings_action.size_flags_horizontal == Control.SIZE_SHRINK_END)
    _expect(settings_action.size_flags_vertical == Control.SIZE_SHRINK_CENTER)

    for language in ["zh_hans", "zh_hant", "en", "ja", "ko"]:
        app.active_language = language
        _expect(not String(app._t("iap.list_limit.title")).is_empty())
        _expect(not String(app._t("iap.limit_body")).is_empty())
        _expect(not String(app._t("iap.restore")).is_empty())
        _expect(not String(app._t("iap.coffee.title")).is_empty())
        _expect(not String(app._t("iap.coffee.desc")).is_empty())
        _expect(not String(app._t("iap.coffee.active_until", ["2030-01-01"])).is_empty())
        _expect(not String(app._t("iap.runtime_unavailable")).is_empty())
        _expect(not String(app._t("iap.beta_runtime_unavailable")).is_empty())

    settings_action.free()
    app.modal_layer.free()
    app.ui_motion.free()
    app.free()
    _check_softpal_launch_access()
    if failures == 0:
        print("IAP_CATALOG_LIMIT_OK")
    quit(1 if failures else 0)

func _check_softpal_launch_access() -> void:
    # Exercise the launch/entitlement round trip without StoreKit or a game.
    # The platform matrix above verifies which builds enforce this flow.
    for enforce in [true, false]:
        for entitled in [true, false]:
            var app = SoftPalAccessApp.new()
            var coffee_player = CoffeePlayer.new()
            app.player = coffee_player
            app.selected_game = {"path": "/games/softpal"}
            app.enforce_beta_access = enforce
            app.iap_coffee_state = {"entitled": entitled}
            app._start_selected_game_after_iap()
            if enforce:
                _expect(coffee_player.requested_products == ["com.aether.coffee"])
                _expect(not app.launched)
                _expect(app.iap_pending_beta_check_id > 0)
                _expect(not app.iap_pending_beta_game.is_empty())
                app._complete_runtime_beta_check()
                _expect(app.launched == entitled)
                _expect(app.denied == (not entitled))
                _expect(app.iap_pending_beta_game.is_empty())
            else:
                _expect(coffee_player.requested_products.is_empty())
                _expect(app.launched)
                _expect(not app.denied)
            app.player = null
            app.ui_motion.free()
            app.free()
