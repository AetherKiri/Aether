extends SceneTree


func _initialize() -> void:
    var player = ClassDB.instantiate("AetherRuntimePlayer")
    root.add_child(player)
    var result: Dictionary = player.debug_runtime_audio_speed_self_test()
    print("runtime audio speed self-test: %s" % JSON.stringify(result))
    player.queue_free()
    await process_frame
    quit(0 if result.get("ok", false) else 1)
