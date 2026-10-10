extends SceneTree

# Native menu regression: menu label translation coverage must not fall back
# to raw keys, and the helper must stay a safe no-op when the platform or
# display server has no global menu (headless runs, non-Apple builds).

const MAIN_SCRIPT := preload("res://scripts/main.gd")
const NATIVE_MENU_SCRIPT := preload("res://scripts/native_menu.gd")

const MENU_KEYS := [
    "menu.file",
    "menu.view",
    "menu.game",
    "menu.fullscreen",
    "menu.back_to_library",
]
const LANGUAGES := ["zh_hans", "zh_hant", "en", "ja", "ko"]

func _initialize() -> void:
    var app = MAIN_SCRIPT.new()
    for language in LANGUAGES:
        app.active_language = language
        for key in MENU_KEYS:
            var text: String = String(app._t(key))
            assert(not text.is_empty(), "empty menu label %s/%s" % [language, key])
            assert(text != key, "untranslated menu label %s/%s" % [language, key])
    var bar = NATIVE_MENU_SCRIPT.new()
    assert(bar.is_supported() is bool)
    var result = bar.setup(null, Callable(), Callable(), {})
    assert(result is bool)
    # Both teardown-facing calls must be safe regardless of setup outcome.
    bar.refresh_state()
    bar.retranslate()
    print("native_menu_test: ok supported=%s setup=%s" % [str(bar.is_supported()), str(result)])
    quit()
