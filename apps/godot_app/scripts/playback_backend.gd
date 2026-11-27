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


static func host_preference(selection: String) -> String:
    match selection:
        AUTOMATIC: return "automatic"
        NATIVE: return "native"
    return "legacy"
