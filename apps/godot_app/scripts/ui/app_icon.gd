extends RefCounted
## UI identity follows the interface version and Astryx light/dark theme.
const CLASSIC := preload("res://assets/icon.png")
const ASTRYX := preload("res://assets/icons/astryx/icon.png")
const ASTRYX_DARK := preload("res://assets/icons/astryx/dark/icon.png")

static func texture(astryx: bool, dark: bool = false) -> Texture2D:
    if not astryx:
        return CLASSIC
    return ASTRYX_DARK if dark else ASTRYX

static func apply(astryx: bool, dark: bool = false) -> void:
    # Editor previews and automated headless tests must never change the host
    # Godot application's Dock/Finder/launcher identity.
    if OS.has_feature("editor") or DisplayServer.get_name() == "headless":
        return
    var image := texture(astryx, dark).get_image()
    if OS.get_name() not in ["iOS", "Android"]:
        DisplayServer.set_icon(image)
    if ClassDB.class_exists("AetherAppIcon"):
        var native = ClassDB.instantiate("AetherAppIcon")
        native.apply(astryx, image.save_png_to_buffer(), dark)
