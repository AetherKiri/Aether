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

    print("app_updater_test: PASS")
    quit(0)

func _assert(condition: bool, msg: String) -> void:
    if not condition:
        push_error("Assertion failed: " + msg)
        printerr("app_updater_test: FAIL - " + msg)
        quit(1)
