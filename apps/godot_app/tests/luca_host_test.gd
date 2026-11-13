extends SceneTree

const Main = preload("res://scripts/main.gd")
const Metadata = preload("res://scripts/game_metadata.gd")
const Launch = preload("res://scripts/game_launch_entry.gd")
const Mapping = preload("res://scripts/game_input_mapping.gd")

class MoviePlayer:
    extends RefCounted
    var info := ""
    var path := ""
    var opens := 0
    var closes := 0
    var status := 1
    var volume := 0.0
    var open_ok := true
    var finishes: Array = []

    func get_renderer_info() -> String:
        return info
    func media_open(value: String) -> bool:
        path = value
        opens += 1
        return open_ok
    func media_close() -> void:
        closes += 1
    func media_set_volume(value: float) -> int:
        volume = value
        return 0
    func media_play() -> int:
        return 0
    func media_update_texture() -> Texture2D:
        return null
    func media_get_state() -> Dictionary:
        return {"status": status}
    func set_engine_option(key: String, value: String) -> int:
        finishes.append([key, value])
        info = "runtime=luca movie_state=idle"
        return 0

var failures := 0

func expect(value: bool, message: String) -> void:
    if not value:
        failures += 1
        push_error(message)

func _initialize() -> void:
    var fixture := ProjectSettings.globalize_path("user://luca_host_%d" % Time.get_ticks_usec())
    DirAccess.make_dir_recursive_absolute(fixture.path_join("files/image"))
    for name in ["Game.exe", "files/SCRIPT.PAK"]:
        FileAccess.open(fixture.path_join(name), FileAccess.WRITE).close()
    expect(Metadata.inspect(fixture).engine == "kirikiri", "A script marker alone is ambiguous")
    FileAccess.open(fixture.path_join("files/image/SYSCG.PAK"), FileAccess.WRITE).close()
    expect(Metadata.inspect(fixture).engine == "luca", "PAK game root must be identified as Luca")
    expect(Metadata.inspect(fixture.path_join("Game.exe")).engine == "luca", "EXE import must inspect its game root")
    expect(Launch.resolve_for_runtime({"path": fixture, "launchFile": "Game.exe"}, "luca") == fixture, "Luca must receive a directory")
    expect(Mapping.input_surface_size("luca", Vector2(1920, 1080), Vector2(1280, 720)) == Vector2(1920, 1080), "Pointer input must use the native frame")
    DirAccess.rename_absolute(fixture.path_join("files/SCRIPT.PAK"), fixture.path_join("files/SCRIPT2.PAK"))
    expect(Metadata.inspect(fixture).engine == "luca", "Replacement script archive must be sufficient")
    for name in ["Game.exe", "files/SCRIPT2.PAK", "files/image/SYSCG.PAK"]:
        DirAccess.remove_absolute(fixture.path_join(name))
    for name in ["files/image", "files", ""]:
        DirAccess.remove_absolute(fixture.path_join(name))

    var app = Main.new()
    var movie := MoviePlayer.new()
    app.player = movie
    app.engine_movie_rect = TextureRect.new()
    app.add_child(app.engine_movie_rect)
    var original_path := "/game/电影 OP.webm"
    movie.info = "runtime=luca movie_state=pending movie_path=%s movie_volume=0.4" % original_path.uri_encode()
    app._poll_engine_movie()
    expect(movie.path == original_path and is_equal_approx(movie.volume, 0.4), "Movie path and volume must survive the renderer channel")
    app._poll_engine_movie()
    expect(movie.opens == 1, "A pending movie must open only once")
    movie.status = 3
    app._poll_engine_movie()
    expect(movie.finishes == [["luca.movie.finish", "seen"]], "EOF must release the runtime latch as seen")
    expect(movie.closes == 1 and not app.engine_movie_playing, "EOF must close the decoder")

    movie.status = 1
    movie.info = "runtime=luca movie_state=pending movie_path=%s" % original_path.uri_encode()
    app._poll_engine_movie()
    expect(movie.opens == 2, "The same movie may be played again")
    movie.info = "runtime=luca movie_state=idle"
    app._poll_engine_movie()
    expect(movie.closes == 2 and movie.finishes.size() == 1, "Runtime skip must close playback without a second finish")

    movie.info = "runtime=another movie_state=pending movie_path=other.webm"
    app._poll_engine_movie()
    app._finish_engine_movie()
    expect(movie.finishes.back() == ["another.movie.finish", ""], "Finish must target the current runtime")
    app._close_engine_movie()
    expect(movie.closes == 3, "Inactive cleanup must not close unrelated media")

    movie.open_ok = false
    movie.info = "runtime=luca movie_state=pending movie_path=missing.webm"
    app._poll_engine_movie()
    expect(movie.finishes.back() == ["luca.movie.finish", ""] and not app.engine_movie_playing, "A failed decoder open must release the latch")
    app.player = null
    app.ui_motion.free()
    app.free()
    print("LUCA_HOST_OK" if failures == 0 else "LUCA_HOST_FAILED")
    quit(0 if failures == 0 else 1)
