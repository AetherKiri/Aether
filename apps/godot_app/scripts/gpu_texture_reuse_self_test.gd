extends SceneTree

func _initialize() -> void:
    var player = ClassDB.instantiate("AetherRuntimePlayer")
    root.add_child(player)
    var worker := Thread.new()
    worker.start(Callable(player, "debug_gpu_texture_reuse_self_test"))
    while worker.is_alive():
        await process_frame
    var result: Dictionary = worker.wait_to_finish()
    print("GPU worker texture reuse self-test: %s" % JSON.stringify(result))
    var ok := bool(result.get("ok", false))
    if OS.get_name() == "macOS" and OS.get_environment("AETHERKIRI_GPU_TEXTURE_POOL_MB") != "0":
        ok = ok and bool(result.get("reused_texture", false))
    player.queue_free()
    await process_frame
    quit(0 if ok else 1)
