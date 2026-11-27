extends SceneTree

const Backend = preload("res://scripts/playback_backend.gd")

func _initialize() -> void:
    var cases := {
        Backend.AUTOMATIC: "automatic",
        Backend.NATIVE: "native",
        Backend.GODOT: "legacy",
        "Debug CPU": "legacy",
        "GPU Bridge": "legacy",
    }
    for selection: String in cases:
        if Backend.host_preference(selection) != cases[selection]:
            printerr("Unexpected host preference for %s" % selection)
            quit(1)
            return
    for selection in [Backend.NATIVE, Backend.GODOT]:
        if Backend.renderer(selection) != Backend.renderer(Backend.AUTOMATIC):
            printerr("The session host selection changed the configured renderer")
            quit(1)
            return
    print("PLAYBACK_BACKEND_OK")
    quit(0)
