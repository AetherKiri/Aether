extends SceneTree

const APP_UPDATER_SCRIPT = preload("res://scripts/app_updater.gd")

func _init() -> void:
    call_deferred("_run")

func _run() -> void:
    # 1. Test version comparison
    _assert(APP_UPDATER_SCRIPT.compare_versions("1.0.6", "1.0.5") == 1, "1.0.6 should be greater than 1.0.5")
    _assert(APP_UPDATER_SCRIPT.compare_versions("1.0.5", "1.0.6") == -1, "1.0.5 should be less than 1.0.6")
    _assert(APP_UPDATER_SCRIPT.compare_versions("1.0.5", "1.0.5") == 0, "1.0.5 should equal 1.0.5")
    _assert(APP_UPDATER_SCRIPT.compare_versions("v1.0.6", "1.0.5") == 1, "v1.0.6 should be greater than 1.0.5")
    _assert(APP_UPDATER_SCRIPT.compare_versions("1.1.0", "1.0.9") == 1, "1.1.0 should be greater than 1.0.9")
    _assert(APP_UPDATER_SCRIPT.compare_versions("2.0.0", "1.99.99") == 1, "2.0.0 should be greater than 1.99.99")
    _assert(APP_UPDATER_SCRIPT.compare_versions("1.0.6-alpha.1", "1.0.6") == -1, "1.0.6-alpha.1 should be less than 1.0.6")
    _assert(APP_UPDATER_SCRIPT.compare_versions("1.0.6", "1.0.6-alpha.1") == 1, "1.0.6 should be greater than 1.0.6-alpha.1")
    _assert(APP_UPDATER_SCRIPT.compare_versions("1.0.6-alpha.2", "1.0.6-alpha.1") == 1, "alpha.2 should be greater than alpha.1")
    _assert(APP_UPDATER_SCRIPT.compare_versions("1.0.6-alpha.10", "1.0.6-alpha.2") == 1, "alpha.10 should be greater than alpha.2")
    _assert(APP_UPDATER_SCRIPT.compare_versions("1.0.6-alpha.2", "1.0.6-alpha.10") == -1, "alpha.2 should be less than alpha.10")
    _assert(APP_UPDATER_SCRIPT.compare_versions("1.0.6-alpha.beta", "1.0.6-alpha.1") == 1, "non-numeric should have higher precedence than numeric")
    _assert(APP_UPDATER_SCRIPT.compare_versions("1.0.6-beta", "1.0.6-alpha") == 1, "beta should be greater than alpha")

    # 2. Test release picking logic with prerelease filtering
    var mock_releases: Array = [
        {"tag_name": "v1.0.7-beta.1", "prerelease": true, "body": "Beta notes"},
        {"tag_name": "v1.0.6", "prerelease": false, "body": "Stable notes"},
        {"tag_name": "v1.0.5", "prerelease": false, "body": "Older stable notes"}
    ]

    var stable_picked: Dictionary = APP_UPDATER_SCRIPT._pick_release(mock_releases, false)
    _assert(stable_picked.get("tag_name") == "v1.0.6", "Should pick stable v1.0.6 when include_prerelease is false")

    var beta_picked: Dictionary = APP_UPDATER_SCRIPT._pick_release(mock_releases, true)
    _assert(beta_picked.get("tag_name") == "v1.0.7-beta.1", "Should pick beta v1.0.7-beta.1 when include_prerelease is true")

    # 3. Test markdown to bbcode conversion
    var sample_md := "### What's Changed\n* Added **cool feature** in `app.gd` by @developer\n[Link](https://github.com)"
    var bb := APP_UPDATER_SCRIPT.markdown_to_bbcode(sample_md)
    _assert(bb.contains("[b]What's Changed[/b]"), "Heading 3 should become bold")
    _assert(bb.contains("• Added [b]cool feature[/b] in [code]app.gd[/code] by [b]@developer[/b]"), "Bullet and bold/code/mention should convert")
    _assert(bb.contains("[url=https://github.com]Link[/url]"), "Markdown link should convert to bbcode url")

    # 4. Test macOS direct zip URL and Android APK URL parsing
    var mock_release_data := {
        "tag_name": "1.0.6",
        "body": "Test release",
        "assets": [
            {"name": "AetherKiri-1.0.6-android.apk", "browser_download_url": "https://custom.com/apk"},
            {"name": "AetherKiri-1.0.6-macos.zip", "browser_download_url": "https://custom.com/macos.zip"},
            {"name": "AetherKiri-1.0.6-macos-app-store.pkg", "browser_download_url": "https://custom.com/pkg"}
        ]
    }
    var res_tracker: Array = [false]
    var test_cb := func(status: int, info: Dictionary):
        res_tracker[0] = true
        _assert(status == APP_UPDATER_SCRIPT.CheckStatus.SUCCESS_HAS_UPDATE, "Should report update")
        _assert(info.get("github_macos_url") == "https://custom.com/macos.zip", "Should extract github_macos_url")
        _assert(info.get("github_apk_url") == "https://custom.com/apk", "Should extract github_apk_url")

    APP_UPDATER_SCRIPT._finish_with_release_data(mock_release_data, "1.0.5", "github", test_cb)
    _assert(res_tracker[0], "Callback should be invoked")

    # 5. Test is_mac_app_store callable without crash
    var mas_check: bool = APP_UPDATER_SCRIPT.is_mac_app_store()
    _assert(mas_check is bool, "is_mac_app_store should return a boolean")

    # 6. Test is_prerelease detection
    _assert(APP_UPDATER_SCRIPT.is_prerelease("1.0.7-alpha.1") == true, "1.0.7-alpha.1 should be recognized as prerelease")
    _assert(APP_UPDATER_SCRIPT.is_prerelease("v1.0.6-beta.2") == true, "v1.0.6-beta.2 should be recognized as prerelease")
    _assert(APP_UPDATER_SCRIPT.is_prerelease("1.0.6") == false, "1.0.6 should not be recognized as prerelease")
    _assert(APP_UPDATER_SCRIPT.is_prerelease("v1.0.5") == false, "v1.0.5 should not be recognized as prerelease")

    # 7. Test Apple TestFlight update bypass (iOS and macOS TestFlight)
    OS.set_environment("AETHERKIRI_SIMULATE_TESTFLIGHT", "1")
    _assert(APP_UPDATER_SCRIPT.is_apple_testflight("1.0.6") == true, "AETHERKIRI_SIMULATE_TESTFLIGHT should force TestFlight mode")
    _assert(APP_UPDATER_SCRIPT.is_ios_testflight("1.0.6") == true, "is_ios_testflight alias should work")
    var tf_callback_invoked := [false]
    var dummy_node := Node.new()
    root.add_child(dummy_node)
    APP_UPDATER_SCRIPT.check_for_updates(
        dummy_node,
        "1.0.7-alpha.1",
        true,
        false,
        func(status: int, info: Dictionary):
            tf_callback_invoked[0] = true
            _assert(status == APP_UPDATER_SCRIPT.CheckStatus.SUCCESS_NO_UPDATE, "TestFlight build should report no update")
            _assert(bool(info.get("is_testflight", false)) == true, "info should contain is_testflight = true")
    )
    _assert(tf_callback_invoked[0], "TestFlight update callback should execute immediately without network")
    dummy_node.queue_free()
    OS.set_environment("AETHERKIRI_SIMULATE_TESTFLIGHT", "")

    # 8. Test macOS channels: Mac App Store vs Mac TestFlight vs GitHub
    OS.set_environment("AETHERKIRI_SIMULATE_APP_STORE", "1")
    _assert(APP_UPDATER_SCRIPT.is_mac_app_store() == true, "Simulated MAS receipt should return true")
    _assert(APP_UPDATER_SCRIPT.is_apple_testflight("1.0.7-alpha.1") == true, "Mac MAS build with alpha should be treated as Mac TestFlight")
    _assert(APP_UPDATER_SCRIPT.is_apple_testflight("1.0.6") == false, "Mac MAS build with clean version should be treated as production MAS")
    OS.set_environment("AETHERKIRI_SIMULATE_APP_STORE", "")

    # 9. Test Aether-prefixed assets parsing
    var mock_aether_assets := {
        "tag_name": "v1.0.7",
        "body": "Aether release",
        "assets": [
            {"name": "Aether-1.0.7-android.apk", "browser_download_url": "https://github.com/Aether/apk"},
            {"name": "Aether-1.0.7-macos.zip", "browser_download_url": "https://github.com/Aether/macos.zip"},
        ]
    }
    var aether_tracker := [false]
    APP_UPDATER_SCRIPT._finish_with_release_data(mock_aether_assets, "1.0.6", "github", func(status: int, info: Dictionary):
        aether_tracker[0] = true
        _assert(status == APP_UPDATER_SCRIPT.CheckStatus.SUCCESS_HAS_UPDATE, "Should report update")
        _assert(info.get("github_macos_url") == "https://github.com/Aether/macos.zip", "Should extract Aether-1.0.7-macos.zip")
        _assert(info.get("github_apk_url") == "https://github.com/Aether/apk", "Should extract Aether-1.0.7-android.apk")
    )
    _assert(aether_tracker[0], "Aether asset parsing callback should be invoked")

    print("app_updater_test: PASS")
    quit(0)

func _assert(condition: bool, msg: String) -> void:
    if not condition:
        push_error("Assertion failed: " + msg)
        printerr("app_updater_test: FAIL - " + msg)
        quit(1)
