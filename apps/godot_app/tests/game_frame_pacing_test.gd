extends SceneTree

const Pacing = preload("res://scripts/game_frame_pacing.gd")

func _init() -> void:
    var policy := Pacing.new()
    for context in [["kirikiri", "macOS", "metal"], ["yuris", "Windows", "vulkan"],
            ["yuris", "macOS", "opengl3"], ["yuris", "iOS", "metal"],
            ["bgi", "Windows", "vulkan"], ["bgi", "macOS", "opengl3"],
            ["bgi", "iOS", "metal"]]:
        assert(policy.enter(context[0], context[1], context[2], 1, 0, 60.0).is_empty())
        assert(policy.leave().is_empty())
    assert(policy.enter("yuris", "macOS", "metal", 1, 0, 120.0) == {"vsync": 0, "max_fps": 60})
    # A repeated launch callback must not overwrite the saved shell state.
    assert(policy.enter("yuris", "macOS", "metal", 0, 60, 60.0).is_empty())
    assert(policy.leave() == {"vsync": 1, "max_fps": 0})
    assert(policy.leave().is_empty())
    assert(policy.enter("yuris", "macOS", "metal", 2, 30, 60.0) == {"vsync": 0, "max_fps": 30})
    assert(policy.leave() == {"vsync": 2, "max_fps": 30})
    assert(policy.enter("yuris", "macOS", "metal", 1, 0, -1.0).max_fps == 60)
    policy.leave()
    assert(policy.enter("yuris", "macOS", "metal", 1, 0, 50.0).max_fps == 50)
    policy.leave()
    assert(policy.enter("yuris", "macOS", "metal", 0, 0, 60.0).is_empty())
    # BGI's software compositor does not need to run at ProMotion's 120 Hz.
    assert(policy.enter("bgi", "macOS", "metal", 1, 0, 120.0) == {"vsync": 0, "max_fps": 60})
    assert(policy.enter("bgi", "macOS", "metal", 0, 60, 120.0).is_empty())
    assert(policy.leave() == {"vsync": 1, "max_fps": 0})
    assert(policy.enter("bgi", "macOS", "metal", 2, 45, 120.0) == {"vsync": 0, "max_fps": 45})
    assert(policy.leave() == {"vsync": 2, "max_fps": 45})
    assert(policy.enter("exhibit", "macOS", "metal", 1, 0, 120.0) == {"vsync": 0, "max_fps": 60})
    assert(policy.leave() == {"vsync": 1, "max_fps": 0})
    assert(policy.enter("systemc", "macOS", "metal", 1, 0, 120.0) == {"vsync": 0, "max_fps": 60})
    assert(policy.leave() == {"vsync": 1, "max_fps": 0})
    assert(policy.enter("systemc", "iOS", "metal", 1, 0, 120.0).is_empty())
    assert(policy.enter("advhd", "macOS", "metal", 1, 0, 120.0) == {"vsync": 0, "max_fps": 60})
    assert(policy.frame_limit("advhd", 120.0, 90) == 90)
    assert(policy.frame_limit("advhd", 120.0, 144) == 120)
    assert(policy.leave() == {"vsync": 1, "max_fps": 0})
    assert(policy.enter("advhd", "macOS", "metal", 1, 75, 120.0, 90).max_fps == 75)
    assert(policy.leave() == {"vsync": 1, "max_fps": 75})
    assert(policy.enter("advhd", "iOS", "metal", 1, 0, 120.0).is_empty())
    var active_usec := 6900
    for frame in [20, 21, 22, 22]:
        assert(policy.polling_delay_usec(frame, active_usec) == active_usec)
    for frame in [22, 22, 23, 23, 24]:
        assert(policy.polling_delay_usec(frame, active_usec) == 16667)
    assert(policy.polling_delay_usec(25, active_usec) == active_usec)
    assert(policy.polling_delay_usec(25, 20000) == 20000)
    assert(policy.polling_delay_usec(25, 20000) == 20000)
    print("Game frame pacing lifecycle regression passed")
    quit(0)
