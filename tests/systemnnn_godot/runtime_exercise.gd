extends SceneTree
var player
var failed = false
func setting(name, fallback):
    var value = OS.get_environment(name)
    return fallback if value.is_empty() else value
func absolute(path):
    return ProjectSettings.globalize_path(path)
var output_path
func check(value, label):
    print("CHECK ",label,"=",value)
    if not value:
        failed = true
        push_error(label)
func state():
    return JSON.parse_string(player.get_plugin_debug_info())
func ticks(count=1):
    for i in range(count):
        check(player.tick(0.02) == 0, "tick")
func check_glyphs(image, label):
    var bright = 0
    for y in range(90,155):
        for x in range(90,470):
            var pixel = image.get_pixel(x,y)
            if pixel.r8 > 180 and pixel.g8 > 180 and pixel.b8 > 180:
                bright += 1
    print("GLYPH_PIXELS ",label,"=",bright)
    check(bright > 100,"visible authored dialogue "+label)
func finish_text():
    for i in range(120):
        var current = state()
        if current.get("wait") != 3 or current.get("text_complete",true):
            return
        check(player.tick(0.02)==0,"reveal tick")
    check(false,"text reveal completes")
func enter():
    finish_text()
    check(player.send_key_event(true, 13, 0, 0) == 0,"enter down")
    ticks()
    check(player.send_key_event(false, 13, 0, 0) == 0,"enter up")
func until_wait(expected):
    for i in range(30):
        if state().get("wait") == expected:
            return
        ticks()
    check(false,"wait="+str(expected)+" "+str(state()))
func _initialize():
    call_deferred("run")
func run():
    var loaded = GDExtensionManager.load_extension(setting("SYSTEMNNN_EXTENSION", "res://production.gdextension"))
    check(loaded == 0,"production extension load")
    check(ClassDB.class_exists("AetherRuntimePlayer"),"production class registered")
    check(DisplayServer.get_name() == "X11","graphical X11")
    if failed:
        quit(1)
        return
    player = ClassDB.instantiate("AetherRuntimePlayer")
    root.add_child(player)
    var game = absolute(setting("SYSTEMNNN_FIXTURE", "res://fixture/日本語 Game"))
    check(player.probe_runtime("systemnnn",game)>0,"registered provider positive")
    check(player.probe_runtime("systemnnn",game.path_join("absent"))==0,"negative probe")
    var writable = absolute(setting("SYSTEMNNN_WRITABLE", "res://writable"))
    output_path = absolute(setting("SYSTEMNNN_OUTPUT", "res://artifacts"))
    check(DirAccess.make_dir_recursive_absolute(output_path) == OK,"create output")
    var cache = writable.path_join("cache")
    DirAccess.make_dir_recursive_absolute(cache)
    check(player.initialize_engine(writable,cache),"initialize engine")
    check(player.set_engine_option("runtime","systemnnn")==0,"select systemnnn")
    var font = OS.get_environment("SYSTEMNNN_FONT")
    if not font.is_empty():
        check(player.set_engine_option("systemnnn.font",absolute(font))==0,"select font")
    check(player.open_game(game,false)==0,"open fixture")
    check(player.get_renderer_info().contains("SystemNNN"),"SystemNNN renderer")
    ticks(3)
    check(state().get("overlay")=="title","title visible")
    var texture = player.update_frame_texture()
    check(texture != null and texture.get_width()>0,"Godot title texture")
    enter()
    until_wait(3)
    finish_text()
    texture = player.update_frame_texture()
    check(texture != null,"Godot story texture")
    if texture != null:
        var image = texture.get_image()
        check(image != null and image.get_pixel(0,0).r8 == 180 and image.get_pixel(0,0).g8 == 30 and image.get_pixel(0,0).b8 == 60,"story RGB texture")
        check_glyphs(image,"story")
        check(image.save_png(output_path.path_join("production-story-finished.png"))==OK,"save story PNG")
    finish_text()
    var first_word = state().get("word")
    check(player.set_engine_option("systemnnn.save_slot","13")==0,"save PC slot")
    check(FileAccess.file_exists(writable.path_join("systemnnn/slot-13.sav")),"slot file exists")
    enter()
    check(state().get("word") != first_word,"dialogue input advances")
    check(player.set_engine_option("systemnnn.load_slot","13")==0,"load PC slot")
    check(state().get("word")==first_word,"load restores continuation")
    for i in range(5):
        if state().get("wait") == 4:
            break
        enter()
    until_wait(4)
    check(player.send_key_event(true,50,0,0)==0,"choice2 key")
    ticks()
    player.send_key_event(false,50,0,0)
    until_wait(3)
    finish_text()
    texture = player.update_frame_texture()
    check(texture != null,"Godot choice texture")
    if texture != null:
        var image = texture.get_image()
        check(image.get_pixel(0,0).r8==10 and image.get_pixel(0,0).g8==80 and image.get_pixel(0,0).b8==220,"choice2 blue RGB texture")
        check_glyphs(image,"choice")
        check(image.save_png(output_path.path_join("production-choice-finished.png"))==OK,"save choice PNG")
    player.destroy_engine()
    player.free()
    print("SYSTEMNNN_GRAPHICAL_PRODUCTION_EXERCISE_", "FAILED" if failed else "OK")
    quit(1 if failed else 0)
