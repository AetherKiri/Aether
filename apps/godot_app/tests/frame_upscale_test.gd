extends SceneTree

var player = null
var view: TextureRect
var received_frames := 0

func _initialize() -> void:
    call_deferred("_run")

func _require(condition: bool, message: String) -> bool:
    if condition:
        return true
    printerr("Frame upscale test: %s" % message)
    quit(1)
    return false

func _on_ready(texture: Texture2D) -> void:
    received_frames += 1
    view.texture = texture

func _run() -> void:
    player = ClassDB.instantiate("AetherRuntimePlayer") as Node
    if not _require(player != null, "runtime player unavailable"):
        return
    root.add_child(player)
    view = TextureRect.new()
    view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    view.size = Vector2(256, 192)
    root.add_child(view)
    player.connect("frame_upscale_ready", _on_ready)
    player.set_frame_upscale_algorithm("metalfx_spatial")

    var image := Image.create(64, 48, false, Image.FORMAT_RGBA8)
    image.fill(Color(0.25, 0.5, 0.75, 1.0))
    var source := ImageTexture.create_from_image(image)
    var supported: bool = player.is_frame_upscale_available("metalfx_spatial")
    if not supported:
        var fallback: Texture2D = player.upscale_frame_texture(source, 128, 96)
        if not _require(fallback == source, "unsupported renderer must retain the source texture"):
            return
        if not _require(not player.get_frame_upscale_status().active, "fallback must be inactive"):
            return
        if not _require(OS.get_environment("AETHER_TEST_REQUIRE_UPSCALER") != "1", "native upscaler required by test"):
            return
        print("Frame upscale test: fallback passed; native scaler unavailable")
        player.queue_free()
        await process_frame
        quit(0)
        return

    var first_allocations := -1
    for frame in range(24):
        var color := Color(0.2, 0.6, 0.85, 1.0) if frame % 2 == 0 else Color(0.85, 0.25, 0.15, 1.0)
        image.fill(color)
        source.update(image)
        view.texture = player.upscale_frame_texture(source, 128, 96)
        await RenderingServer.frame_post_draw
        await process_frame
        var status: Dictionary = player.get_frame_upscale_status()
        if not _require(bool(status.active), "native scaler did not publish frame %d: %s" % [frame, status]):
            return
        if not _require(view.texture.get_size() == Vector2(128, 96), "incorrect output size"):
            return
        var output := view.texture.get_image()
        if not _require(output != null and not output.is_empty(), "empty output"):
            return
        var pixel := output.get_pixel(64, 48)
        if not _require(absf(pixel.r - color.r) < 0.025 and absf(pixel.g - color.g) < 0.025 and absf(pixel.b - color.b) < 0.025 and pixel.a > 0.99,
                "stale/incorrect frame %d: got %s expected %s" % [frame, pixel, color]):
            return
        var provider: Dictionary = status.provider
        if first_allocations < 0:
            first_allocations = int(provider.allocations)
        if not _require(int(provider.allocations) == first_allocations, "scaler recreated for an unchanged size"):
            return
        if not _require(int(provider.allocated_texture_count) == 2, "unexpected retained texture count"):
            return

    # Exercise real asynchronous submission: no image readback or GPU wait
    # between frames, so the earlier pixel checks cannot hide ordering bugs.
    for frame in range(120):
        image.fill(Color(0.8, 0.2, 0.1, 1.0) if frame % 2 == 0 else Color(0.1, 0.3, 0.8, 1.0))
        source.update(image)
        view.texture = player.upscale_frame_texture(source, 128, 96)
        await RenderingServer.frame_post_draw
        await process_frame
    var animated := view.texture.get_image().get_pixel(64, 48)
    if not _require(animated.b > 0.75 and animated.r < 0.15, "asynchronous output is stale"):
        return
    if not _require(int(player.get_frame_upscale_status().provider.allocations) == first_allocations, "asynchronous frames recreated resources"):
        return

    # Resizing rebuilds once and publishes the new dimensions, with the same
    # display-encoded colors. A submitted frame may safely outlive its owner.
    view.texture = player.upscale_frame_texture(source, 192, 144)
    await RenderingServer.frame_post_draw
    await process_frame
    if not _require(view.texture.get_size() == Vector2(192, 144), "resize did not reach presentation"):
        return
    if not _require(int(player.get_frame_upscale_status().provider.allocations) == first_allocations + 1, "resize allocation count"):
        return
    var screenshot := root.get_texture().get_image()
    if not _require(screenshot != null and screenshot.get_pixel(20, 20).b > 0.5, "presented frame is black"):
        return

    var large_image := Image.create(1280, 720, false, Image.FORMAT_RGBA8)
    large_image.fill(Color(0.2, 0.65, 0.4, 1.0))
    var large_source := ImageTexture.create_from_image(large_image)
    for frame in range(12):
        view.texture = player.upscale_frame_texture(large_source, 2560, 1440)
        await RenderingServer.frame_post_draw
        await process_frame
    if not _require(view.texture.get_size() == Vector2(2560, 1440), "1440p output size"):
        return
    var large_pixel := view.texture.get_image().get_pixel(1280, 720)
    if not _require(absf(large_pixel.g - 0.65) < 0.025, "1440p output color"):
        return

    # Native video/game bridges can publish BGRA; enhancement passes may use
    # half floats. Both must preserve the display-encoded RGB channels.
    var rd := RenderingServer.get_rendering_device()
    var format := RDTextureFormat.new()
    format.width = 64
    format.height = 48
    format.format = RenderingDevice.DATA_FORMAT_B8G8R8A8_UNORM
    format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
    var bytes := PackedByteArray()
    bytes.resize(64 * 48 * 4)
    for offset in range(0, bytes.size(), 4):
        bytes[offset] = 204
        bytes[offset + 1] = 153
        bytes[offset + 2] = 51
        bytes[offset + 3] = 255
    var bgra_rid := rd.texture_create(format, RDTextureView.new(), [bytes])
    var bgra_source := Texture2DRD.new()
    bgra_source.texture_rd_rid = bgra_rid
    view.texture = player.upscale_frame_texture(bgra_source, 128, 96)
    await RenderingServer.frame_post_draw
    await process_frame
    if not _require(player.get_frame_upscale_status().active and view.texture.get_size() == Vector2(128, 96), "BGRA source did not use native upscaling"):
        return
    var bgra_pixel := view.texture.get_image().get_pixel(64, 48)
    if not _require(absf(bgra_pixel.r - 0.2) < 0.025 and absf(bgra_pixel.b - 0.8) < 0.025, "BGRA channels changed"):
        return
    var half_image := Image.create(64, 48, false, Image.FORMAT_RGBAH)
    half_image.fill(Color(0.3, 0.5, 0.7, 1.0))
    var half_source := ImageTexture.create_from_image(half_image)
    view.texture = player.upscale_frame_texture(half_source, 128, 96)
    await RenderingServer.frame_post_draw
    await process_frame
    if not _require(player.get_frame_upscale_status().active and view.texture.get_size() == Vector2(128, 96), "half-float source did not use native upscaling"):
        return
    var half_pixel := view.texture.get_image().get_pixel(64, 48)
    if not _require(absf(half_pixel.r - 0.3) < 0.025 and absf(half_pixel.b - 0.7) < 0.025, "half-float colors changed"):
        return
    bgra_source.texture_rd_rid = RID()
    rd.free_rid(bgra_rid)

    view.texture = player.upscale_frame_texture(source, 32, 24)
    if not _require(view.texture == source and not player.get_frame_upscale_status().active, "downscaling must bypass native upscaling"):
        return
    if not _require(int(player.get_frame_upscale_status().provider.allocated_texture_count) == 0, "bypass retained textures"):
        return
    view.texture = player.upscale_frame_texture(source, 128, 96)
    player.set_frame_upscale_algorithm("")
    var frames_before_disable := received_frames
    await RenderingServer.frame_post_draw
    await process_frame
    if not _require(received_frames == frames_before_disable, "disabled scaler published a stale frame"):
        return
    if not _require(int(player.get_frame_upscale_status().provider.allocated_texture_count) == 0, "disabled scaler retained textures"):
        return
    for frame in range(12):
        await process_frame
    if not _require(int(player.get_frame_upscale_status().provider.retired_texture_sets) == 0, "deferred resources did not retire"):
        return
    print("Frame upscale test: native output, color, opacity, animation, reuse, resize, presentation and release passed")
    player.queue_free()
    await process_frame
    quit(0)
