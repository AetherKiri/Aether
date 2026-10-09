extends SceneTree

func _initialize() -> void:
    var expected := OS.get_environment("EXPECT_RENPY_DEVICE_PROFILE") == "1"
    var feature := OS.has_feature("renpy_ios_device_gles")
    var base := str(ProjectSettings.get_setting("rendering/renderer/rendering_method"))
    var selected := str(ProjectSettings.get_setting_with_override("rendering/renderer/rendering_method"))
    var valid := feature == expected and base == "mobile" and not OS.has_feature("ios_simulator")
    valid = valid and selected == ("gl_compatibility" if expected else "mobile")
    print("DEVICE_PROFILE_EVIDENCE=" + JSON.stringify({
        "feature": feature, "base": base, "selected": selected,
        "ios_simulator": OS.has_feature("ios_simulator"), "valid": valid,
        "scope": "Real Godot project/PCK settings; no iOS graphics or gameplay execution"
    }))
    quit(0 if valid else 1)
