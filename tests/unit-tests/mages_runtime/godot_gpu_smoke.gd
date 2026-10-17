extends SceneTree

# Run in a project that loads aether_kiri.gdextension using a RenderingDevice:
# godot --path <project> --rendering-method mobile --script <this-file> -- <game-root> [frames] [output-dir] [sessions]
# A real resource directory is required; no game data is included in the test.
func _initialize() -> void:
	call_deferred("run")

func fail(message: String) -> void:
	push_error(message)
	quit(1)

func run() -> void:
	var args := OS.get_cmdline_user_args()
	var sessions := 1
	if args.size() > 3:
		sessions = maxi(1, int(args[3]))
	for session in sessions:
		if not await run_session(args, session):
			quit(1)
			return
	quit(0)

func run_session(args: PackedStringArray, session: int) -> bool:
	if args.is_empty() or not ClassDB.class_exists("AetherRuntimePlayer"):
		fail("MAGES smoke requires a game root and the Aether extension")
		return false
	var player = ClassDB.instantiate("AetherRuntimePlayer")
	var writable := OS.get_cache_dir().path_join("aether-mages-gpu-smoke")
	if args.size() > 2:
		writable = args[2]
	DirAccess.make_dir_recursive_absolute(writable)
	if not player.initialize_engine(writable, writable):
		fail(player.get_last_error())
		return false
	player.set_frame_enhancement_enabled(false)
	player.set_frame_native_output_enabled(true)
	player.set_render_backend("godot")
	player.set_engine_option("runtime", "mages")
	if player.open_game(args[0], false) != 0:
		fail("open: " + player.get_last_error())
		player.destroy_engine()
		return false
	var display := TextureRect.new()
	display.size = Vector2(960,540)
	root.add_child(display)
	var count := 360
	if args.size() > 1:
		count = int(args[1])
	var has_content := false
	for frame in count:
		if player.tick(1.0 / 60.0) != 0:
			fail("tick: " + player.get_last_error())
			player.destroy_engine()
			return false
		display.texture = player.update_frame_texture()
		if frame >= 180 and frame % 180 == 0:
			player.send_key_event(true, 13, 0, 0)
		if frame >= 181 and frame % 180 == 1:
			player.send_key_event(false, 13, 0, 0)
		await process_frame
		if frame % 120 == 119:
			await RenderingServer.frame_post_draw
			if display.texture == null:
				fail("no native frame texture")
				player.destroy_engine()
				return false
			var image: Image = display.texture.get_image()
			if image == null or image.is_empty():
				fail("native texture readback is empty")
				player.destroy_engine()
				return false
			var reference := image.get_pixel(0, 0)
			for y in range(0, image.get_height(), 16):
				for x in range(0, image.get_width(), 16):
					var sample := image.get_pixel(x, y)
					if absf(sample.r - reference.r) + absf(sample.g - reference.g) + absf(sample.b - reference.b) > 0.05:
						has_content = true
			image.save_png(writable + "/session_%d_frame_%04d.png" % [session, frame])
	var renderer: String = player.get_renderer_info()
	print("MAGES_SMOKE session=", session, " backend=", player.get_frame_texture_backend(), " renderer=", renderer)
	print("MAGES_SMOKE debug=", player.get_plugin_debug_info())
	var passed: bool = player.get_frame_texture_backend().begins_with("godot_native_gpu")
	passed = passed and renderer.contains("bridge_failed=0 ")
	passed = passed and has_content
	display.texture = null
	player.destroy_engine()
	player.free()
	display.queue_free()
	await process_frame
	return passed
