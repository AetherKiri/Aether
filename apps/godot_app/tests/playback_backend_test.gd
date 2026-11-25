extends SceneTree

const Backend = preload("res://scripts/playback_backend.gd")

class Capabilities extends RefCounted:
    var ons := false

    func has_ons_native_host() -> bool:
        return ons

func _initialize() -> void:
    var player := Capabilities.new()
    var cases := [
        [Backend.AUTOMATIC, "onscripter", false, true, false],
        [Backend.AUTOMATIC, "onscripter", true, true, true],
        [Backend.AUTOMATIC, "onscripter", true, false, false],
        [Backend.NATIVE, "onscripter", false, true, true],
        [Backend.NATIVE, "onscripter", false, false, false],
        [Backend.NATIVE, "kirikiri", true, true, false],
        [Backend.GODOT, "onscripter", true, true, false],
        ["Debug CPU", "onscripter", true, true, false],
        ["GPU Bridge", "onscripter", true, true, false],
    ]
    for test: Array in cases:
        player.ons = test[3]
        if Backend.uses_native_host(test[0], test[1], player, test[2]) != test[4]:
            printerr("Unexpected session host for %s" % [test])
            quit(1)
            return
    for selection in [Backend.NATIVE, Backend.GODOT]:
        if Backend.renderer(selection) != Backend.renderer(Backend.AUTOMATIC):
            printerr("The session host selection changed the configured renderer")
            quit(1)
            return
    print("PLAYBACK_BACKEND_OK")
    quit(0)
