extends SceneTree
#
# ExHIBIT manual play window.
#
# Boots the exhibit runtime provider against the title and presents its frames
# on a full-window TextureRect, forwarding the REAL mouse and keyboard straight
# into the provider's input entry points (the same path the acceptance harness
# synthesizes events through). No auto-clicks, no milestone heuristics: the
# window stays open and a human plays. Esc closes it.
#
# Run windowed (headless Godot cannot render):
#   Godot_v4.7.2-stable_win64_console.exe --path apps/godot_app ^
#       -s res://scripts/exhibit_manual_play.gd
#
# The game root comes from the probe config or AETHERKIRI_EXHIBIT_GAME, falling
# back to D:/imopara1/imopara3.

const ProbeConfig = preload("res://scripts/probe_config.gd")

const DEFAULT_GAME := "D:/imopara1/imopara3"
const STARTUP_SUCCEEDED := 2
const STARTUP_FAILED := 3
# engine_api.h engine_input_event_type_t
const POINTER_DOWN := 1
const POINTER_UP := 3

var player: Node
var rect: TextureRect
var glue: Node


# Window pixels in, frame pixels out, straight into the player's real input
# entry points. Attached as a Node so genuine user events reach _input through
# the viewport like any other event.
class ExhibitInputGlue extends Node:
	var player: Node
	var frame_size := Vector2i(1280, 720)

	func _input(event: InputEvent) -> void:
		if event is InputEventKey and (event as InputEventKey).pressed:
			if (event as InputEventKey).keycode == KEY_ESCAPE:
				get_tree().quit(0)
				return
		if player == null:
			return
		var vp := get_viewport().get_visible_rect().size
		if vp.x <= 0.0 or vp.y <= 0.0:
			return
		var sx := float(frame_size.x) / vp.x
		var sy := float(frame_size.y) / vp.y
		if event is InputEventMouseButton:
			var mb := event as InputEventMouseButton
			var fx := mb.position.x * sx
			var fy := mb.position.y * sy
			if mb.pressed:
				player.send_pointer_event(POINTER_DOWN, 0, fx, fy, 0.0, 0.0, int(mb.button_index))
			else:
				player.send_pointer_event(POINTER_UP, 0, fx, fy, 0.0, 0.0, int(mb.button_index))
		elif event is InputEventKey:
			var ke := event as InputEventKey
			if ke.pressed and not ke.echo:
				player.send_key_event(true, int(ke.keycode), 0, 0)
				player.send_key_event(false, int(ke.keycode), 0, 0)


func drain_engine_logs() -> void:
	var chunk: String = player.drain_startup_logs()
	if chunk.is_empty():
		return
	for line in chunk.split("\n"):
		if not line.strip_edges().is_empty():
			print("[engine] " + line)


func current_serial() -> int:
	var frame: Dictionary = player.read_frame_rgba()
	return int(frame.get("frame_serial", 0))


func _initialize() -> void:
	var config := ProbeConfig.load()
	var game_path := ProbeConfig.game_path(config, DEFAULT_GAME)
	root.size = ProbeConfig.window_size(config, Vector2i(1280, 720))

	rect = TextureRect.new()
	rect.name = "ManualTexture"
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	root.add_child(rect)

	glue = ExhibitInputGlue.new()
	glue.name = "ExhibitInputGlue"
	root.add_child(glue)

	player = ClassDB.instantiate("AetherRuntimePlayer")
	root.add_child(player as Node)
	glue.player = player

	var user_dir := OS.get_user_data_dir()
	var cache_dir := user_dir.path_join("cache")
	DirAccess.make_dir_recursive_absolute(cache_dir)
	if not player.initialize_engine(user_dir, cache_dir):
		printerr("[manual] BOOT FAILED initialize_engine: ", player.get_last_error())
		quit(1)
		return
	player.set_render_backend(ProbeConfig.backend(config))
	var surface_size: Vector2i = ProbeConfig.surface_size(config)
	player.set_surface_size(surface_size.x, surface_size.y)
	glue.frame_size = surface_size

	print("[manual] RUN game=%s backend=%s -- click to advance, Esc to quit" % [game_path, ProbeConfig.backend(config)])
	var result: int = player.open_game(game_path, true)
	if result != 0:
		printerr("[manual] BOOT FAILED open_game result=%d: %s" % [result, player.get_last_error()])
		player.destroy_engine()
		quit(1)
		return

	var started := false
	for i in range(ProbeConfig.int_value(config, "startup_timeout_frames", 1800)):
		var state: int = player.get_startup_state()
		if state == STARTUP_SUCCEEDED:
			started = true
			break
		if state == STARTUP_FAILED:
			drain_engine_logs()
			printerr("[manual] BOOT FAILED startup: ", player.get_last_error())
			player.destroy_engine()
			quit(1)
			return
		drain_engine_logs()
		await process_frame
	if not started:
		printerr("[manual] BOOT FAILED startup timed out")
		player.destroy_engine()
		quit(1)
		return

	var frames := 0
	while true:
		var tick_result := int(player.tick(1.0 / 60.0))
		if tick_result != 0:
			print("[manual] tick failed: ", player.get_last_error())
			break
		if player.frame_rendered_this_tick():
			var texture: Texture2D = player.update_frame_texture()
			if texture != null:
				rect.texture = texture
		drain_engine_logs()
		frames += 1
		if frames % 600 == 0:
			print("[manual] frames=%d serial=%d" % [frames, current_serial()])
		await process_frame

	rect.texture = null
	player.destroy_engine()
	quit(0)
