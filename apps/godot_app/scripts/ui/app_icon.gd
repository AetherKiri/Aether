extends RefCounted
## UI identity follows the saved interface version, independently of light/dark.
const CLASSIC := preload("res://assets/icon.png")
const ASTRYX := preload("res://assets/icons/astryx/icon.png")

static func texture(astryx: bool) -> Texture2D:
    return ASTRYX if astryx else CLASSIC

static func apply(astryx: bool) -> void:
    # Editor previews and automated headless tests must never change the host
    # Godot application's Dock/Finder/launcher identity.
    if OS.has_feature("editor") or DisplayServer.get_name() == "headless":
        return
    var image := texture(astryx).get_image()
    if OS.get_name() not in ["iOS", "Android"]:
        DisplayServer.set_icon(image)
    if ClassDB.class_exists("AetherAppIcon"):
        var native = ClassDB.instantiate("AetherAppIcon")
        native.apply(astryx, image.save_png_to_buffer())
