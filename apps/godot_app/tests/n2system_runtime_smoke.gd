extends SceneTree

# Run after building the desktop extension with AETHERKIRI_ENABLE_N2SYSTEM.
# This checks the complete Godot -> provider -> NativeAOT -> GPU -> RGBA path.
var player: Object
var failures := 0
var fixture: DirAccess

func _expect(condition: bool, message: String) -> bool:
    if not condition:
        failures += 1
        push_error("%s: %s" % [message, player.get_last_error() if player != null else ""])
    return condition

func _initialize() -> void:
    call_deferred("_run")

func _run() -> void:
    fixture = DirAccess.create_temp("aether-n2system-host")
    if not _expect(fixture != null, "Create isolated writable directory"):
        quit(1)
        return
    var game_dir := ProjectSettings.globalize_path("res://../../tests/fixtures/n2system_smoke")
    if not _expect(ClassDB.class_exists("AetherRuntimePlayer"), "Load the native runtime extension"):
        quit(1)
        return
    player = ClassDB.instantiate("AetherRuntimePlayer")
    root.add_child(player as Node)
    _expect(int(player.probe_runtime("n2system", game_dir)) > 0, "Register and probe N2System")
    for cycle in range(2):
        var writable := fixture.get_current_dir().path_join("cycle%d" % cycle)
        DirAccess.make_dir_recursive_absolute(writable)
        if not _expect(player.initialize_engine(writable, writable.path_join("cache")), "Initialize engine"):
            break
        _expect(player.set_engine_option("runtime", "n2system") == 0, "Select the N2System provider")
        # Deliberately use a larger presentation size: hit testing follows
        # the profile's logical size, and the runtime must not create a window.
        _expect(player.set_surface_size(1280, 720) == 0, "Set presentation surface")
        if not _expect(player.open_game(game_dir, true) == 0, "Open asynchronously"):
            break
        for frame in range(1800):
            if player.get_startup_state() in [2, 3]:
                break
            await process_frame
        if not _expect(player.get_startup_state() == 2, "Finish asynchronous startup"):
            break
        if not await _wait_color(Color.BLUE):
            break
        for frame in range(5):
            _expect(player.tick(1.0 / 60.0) == 0, "Wait for the first input barrier")
            await process_frame
        var before: Dictionary = player.read_frame_rgba()
        _expect(player.pause() == 0, "Pause")
        for frame in range(3):
            _expect(player.tick(1.0 / 60.0) == 0, "Tick while paused")
        _expect(player.read_frame_rgba().get("rgba") == before.get("rgba"), "Pause preserves the frame")
        _expect(player.resume() == 0, "Resume")
        _expect(player.send_key_event(true, 13, 0, 0) == 0, "Send Return press")
        _expect(player.tick(1.0 / 60.0) == 0, "Consume Return")
        _expect(player.send_key_event(false, 13, 0, 0) == 0, "Send Return release")
        if not await _wait_color(Color.RED):
            break
        for frame in range(5):
            _expect(player.tick(1.0 / 60.0) == 0, "Wait for the pointer input barrier")
            await process_frame
        _expect(player.send_pointer_event(2, 0, 160, 90, 0, 0, 0) == 0, "Move pointer")
        _expect(player.send_pointer_event(1, 0, 160, 90, 0, 0, 0) == 0, "Send pointer press")
        _expect(player.tick(1.0 / 60.0) == 0, "Consume pointer press")
        _expect(player.send_pointer_event(3, 0, 160, 90, 0, 0, 0) == 0, "Send pointer release")
        if not await _wait_color(Color8(0, 128, 0)):
            break
        _expect(String(player.get_renderer_info()).contains("n2system"), "Report the N2System renderer")
        player.destroy_engine()
        _expect(not player.is_initialized(), "Destroy before reopening")
    player.destroy_engine()
    player.free()
    player = null
    fixture = null
    print("N2SYSTEM_RUNTIME_SMOKE_OK" if failures == 0 else "N2SYSTEM_RUNTIME_SMOKE_FAILED")
    quit(0 if failures == 0 else 1)

func _wait_color(expected: Color) -> bool:
    var last_color := Color.TRANSPARENT
    for frame in range(180):
        if not _expect(player.tick(1.0 / 60.0) == 0, "Tick N2System"):
            return false
        var image: Dictionary = player.read_frame_rgba()
        var pixels: PackedByteArray = image.get("rgba", PackedByteArray())
        var width := int(image.get("width", 0))
        var height := int(image.get("height", 0))
        if width > 0 and height > 0 and pixels.size() >= width * height * 4:
            var offset := (height / 2 * width + width / 2) * 4
            var color := Color8(pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3])
            last_color = color
            if color.is_equal_approx(expected):
                return true
        await process_frame
    return _expect(false, "Read expected GPU frame color %s (last %s)" % [expected, last_color])
