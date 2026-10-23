extends SceneTree

const LiveActions = preload("res://scripts/probe_live_actions.gd")

func _initialize() -> void:
    assert(LiveActions.idle_timeout_msec({}) == 600000)
    assert(LiveActions.idle_timeout_msec({"live_actions_timeout_frames": 60000}) == 1000000)
    assert(LiveActions.idle_timeout_msec({"live_actions_timeout_seconds": 7200}) == 7200000)
    assert(LiveActions.idle_timeout_msec({"live_actions_timeout_seconds": -1}) == 1000)
    assert(LiveActions.idle_timeout_msec({"live_actions_timeout_seconds": INF}) == 600000)
    assert(LiveActions.idle_timeout_msec({"live_actions_timeout_seconds": 1e9}) == 14400000)
    var folder := OS.get_user_data_dir().path_join("probe-live-test-%d" % Time.get_ticks_usec())
    assert(DirAccess.make_dir_recursive_absolute(folder) == OK)
    var path := folder.path_join(LiveActions.REQUEST_FILE)
    var live = LiveActions.new()
    assert(live.poll(folder).is_empty())
    _write(path, '{"sequence":1,"actions":[')
    assert(live.poll(folder).is_empty()) # A writer may not have finished yet.
    _write(path, JSON.stringify({"sequence": 1, "actions": [{"type":"capture","label":"same-process"}]}))
    var request: Dictionary = live.poll(folder)
    assert(request.sequence == 1 and request.actions[0].label == "same-process")
    assert(live.poll(folder).is_empty()) # Never click twice for one request.
    for invalid in [{"sequence":2,"actions":"code"}, {"sequence":2.5},
            {"sequence":"2"}, {"sequence":2,"actions":["code"]}]:
        _write(path, JSON.stringify(invalid))
        assert(live.poll(folder).is_empty())
    _write(path, JSON.stringify({"sequence":2,"stop":true}))
    request = live.poll(folder)
    assert(request.sequence == 2 and request.stop and request.actions.is_empty())
    live.acknowledge(folder, 2, 5)
    var result = JSON.parse_string(FileAccess.get_file_as_string(folder.path_join(LiveActions.RESULT_FILE)))
    assert(result.sequence == 2 and result.step == 5 and result.ok)
    DirAccess.remove_absolute(path)
    DirAccess.remove_absolute(folder.path_join(LiveActions.RESULT_FILE))
    DirAccess.remove_absolute(folder)
    print("Live JSON probe request validation and deduplication passed")
    quit(0)

func _write(path: String, value: String) -> void:
    var file := FileAccess.open(path, FileAccess.WRITE)
    assert(file != null)
    file.store_string(value)
