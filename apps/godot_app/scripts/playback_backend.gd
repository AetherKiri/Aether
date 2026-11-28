extends RefCounted

# Keep the existing renderer value as the persisted automatic host selection.
const GODOT_RENDERER := "Godot Native"
const AUTOMATIC := GODOT_RENDERER
const NATIVE := "Native Session"
const GODOT := "Godot"
const VALUES := [AUTOMATIC, NATIVE, GODOT, "GPU Bridge", "Debug CPU"]


static func label(selection: String) -> String:
    match selection:
        AUTOMATIC: return "Automatic Host"
        NATIVE: return "Native Host (Preview)"
        GODOT: return "Godot Host"
    return selection


static func renderer(selection: String) -> String:
    return GODOT_RENDERER if selection in [NATIVE, GODOT] else selection


static func uses_native_host(selection: String, runtime: String, player: Object, prerelease: bool) -> bool:
    var preview_requested := selection == NATIVE or (selection == AUTOMATIC and prerelease)
    return preview_requested and runtime == "onscripter" and player != null \
        and player.has_method("has_ons_native_host") and player.has_ons_native_host()
