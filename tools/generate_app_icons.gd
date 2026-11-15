extends SceneTree
## Package the approved Astryx light/dark masters for Godot, Apple and Android.
## Run from the repository root: godot --headless --script tools/generate_app_icons.gd
const ROOT := "apps/godot_app/assets/"
const OUTPUT := ROOT + "icons/astryx/"

func _initialize() -> void:
    var classic := Image.load_from_file(ROOT + "icon.png")
    if classic == null:
        quit(1)
        return
    for variant in ["", "dark/"]:
        if not _package(OUTPUT + variant, classic, Color.BLACK if variant else Color("f1f1f1")):
            quit(1)
            return
    print("AETHER_APP_ICONS_PACKAGED")
    quit()

func _package(output: String, classic: Image, background_color: Color) -> bool:
    var master := Image.load_from_file(output + "master.png")
    if master == null:
        return false
    master.resize(1024, 1024, Image.INTERPOLATE_LANCZOS)
    master.convert(Image.FORMAT_RGB8)
    master.save_png(output + "app_store_1024x1024.png")
    # Desktop / in-app icons use the existing tile's exact alpha mask. Apple
    # mobile icons remain opaque, letting the OS supply its own corner mask.
    var rounded: Image = master.duplicate()
    rounded.convert(Image.FORMAT_RGBA8)
    for y in range(1024):
        for x in range(1024):
            var pixel := rounded.get_pixel(x, y)
            pixel.a = classic.get_pixel(x, y).a
            rounded.set_pixel(x, y, pixel)
    rounded.save_png(output + "icon.png")
    for side in [40, 58, 60, 76, 80, 87, 114, 120, 128, 136, 152, 167, 180, 192]:
        var sized: Image = master.duplicate()
        sized.resize(side, side, Image.INTERPOLATE_LANCZOS)
        sized.save_png(output + "icon_%dx%d.png" % [side, side])
    # Android applies launcher-specific masks to the 108dp adaptive viewport.
    # Keep the whole tile within the 66dp safe zone instead of cropping a whale.
    var foreground := Image.create(432, 432, false, Image.FORMAT_RGBA8)
    foreground.fill(Color.TRANSPARENT)
    var tile: Image = rounded.duplicate()
    tile.resize(264, 264, Image.INTERPOLATE_LANCZOS)
    foreground.blit_rect(tile, Rect2i(0, 0, 264, 264), Vector2i(84, 84))
    foreground.save_png(output + "icon_adaptive_fg.png")
    var background := Image.create(432, 432, false, Image.FORMAT_RGB8)
    background.fill(background_color)
    background.save_png(output + "icon_adaptive_bg.png")
    return true
