extends SceneTree

const MAIN := preload("res://scripts/main.gd")

class UpscalePlayer extends Node:
    var algorithm := ""
    var active := false

    func set_frame_upscale_algorithm(value: String) -> void:
        algorithm = value
        if value.is_empty():
            active = false

    func get_frame_upscale_status() -> Dictionary:
        return {"active": active}

func _initialize() -> void:
    call_deferred("_run")

func _run() -> void:
    var app = MAIN.new()
    var player := UpscalePlayer.new()
    var view := TextureRect.new()
    view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    root.add_child(view)
    app.player = player
    app.viewport = view
    var image := Image.create(64, 48, false, Image.FORMAT_RGBA8)
    image.fill(Color.WHITE)
    var source := ImageTexture.create_from_image(image)
    view.texture = source
    app.frame_upscale_source_texture = source
    app.last_texture_size = Vector2i(64, 48)
    app.settings_draft = app._current_settings_snapshot()
    app._select_upscale_algorithm("metalfx_spatial")
    assert(app.settings_draft.upscale_algorithm == "metalfx_spatial")
    app.upscale_algorithm = "metalfx_spatial"
    app._apply_upscale_algorithm()
    assert(player.algorithm == "metalfx_spatial")
    assert(view.material == app._resampling_frame_material("bicubic"))
    player.active = true
    app._apply_upscale_algorithm()
    assert(app.frame_upscale_active)
    assert(view.material.shader == app.opaque_frame_shader)

    root.content_scale_factor = 1.0
    view.size = Vector2(128, 96)
    assert(app._frame_upscale_target_size() == Vector2i(128, 96))
    root.content_scale_factor = 2.0
    await process_frame
    assert(app._frame_upscale_target_size() == Vector2i(256, 192))
    root.content_scale_factor = 1.0
    await process_frame
    view.size = Vector2(10000, 5000)
    assert(app._frame_upscale_target_size() == Vector2i(4096, 3072))
    view.size = Vector2(120, 80)
    assert(app._frame_upscale_target_size() == Vector2i(107, 80))

    # A larger native output must not change 1:1 layout or input coordinates.
    image.resize(128, 96)
    view.texture = ImageTexture.create_from_image(image)
    app.softpal_aspect_mode = 2
    app._layout_game_viewport(Vector2(1280, 720))
    assert(view.size == Vector2(64, 48))
    assert(app._game_input_content_size() == Vector2(64, 48))
    app.upscale_algorithm = "nearest"
    app._apply_upscale_algorithm()
    assert(player.algorithm.is_empty())
    assert(not app.frame_upscale_active)
    assert(view.texture == source)
    assert(view.material == null)
    assert(view.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST)

    app.viewport = null
    app.player = null
    view.free()
    player.free()
    app.ui_motion.free()
    app.free()
    print("Frame upscale settings test: selection, fallback, pixel scale, aspect ratio, input and switching passed")
    quit(0)
