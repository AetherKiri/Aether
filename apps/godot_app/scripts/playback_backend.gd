extends RefCounted

# Keep the saved renderer value as the default Native selection.
const NATIVE := "Godot Native"
const GODOT := "Godot"
const VALUES := [NATIVE, GODOT, "GPU Bridge", "Debug CPU"]


static func label(backend: String) -> String:
    return "Native" if backend == NATIVE else backend


static func renderer(backend: String) -> String:
    return NATIVE if backend == GODOT else backend


static func uses_native_host(backend: String, runtime: String, player: Object) -> bool:
    return backend == NATIVE and runtime == "onscripter" and player != null \
        and player.has_method("has_ons_native_host") and player.has_ons_native_host()
