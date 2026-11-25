extends SceneTree

const Backend = preload("res://scripts/playback_backend.gd")

class Capabilities extends RefCounted:
    var ons := false

    func has_ons_native_host() -> bool:
        return ons

func _initialize() -> void:
    var player := Capabilities.new()
    if Backend.label(Backend.NATIVE) != "Native" or Backend.label(Backend.GODOT) != "Godot":
        printerr("The render selector must expose both host choices")
        quit(1)
        return
    if Backend.uses_native_host(Backend.NATIVE, "onscripter", player):
        printerr("ONS without native host support must use Godot")
        quit(1)
        return
    player.ons = true
    if not Backend.uses_native_host(Backend.NATIVE, "onscripter", player):
        printerr("Native must select the compiled ONS host")
        quit(1)
        return
    if Backend.uses_native_host(Backend.NATIVE, "kirikiri", player) \
            or Backend.uses_native_host(Backend.GODOT, "onscripter", player) \
            or Backend.uses_native_host("Debug CPU", "onscripter", player) \
            or Backend.uses_native_host("GPU Bridge", "onscripter", player) \
            or Backend.renderer(Backend.GODOT) != Backend.renderer(Backend.NATIVE):
        printerr("Godot must retain the legacy session and existing renderer")
        quit(1)
        return
    print("PLAYBACK_BACKEND_OK")
    quit(0)
