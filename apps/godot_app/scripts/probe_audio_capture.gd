extends RefCounted

# Optional probe instrumentation. Sample the real mixer, both Master and
# individual YU-RIS channels; a logical playing flag cannot prove audibility.
var captures: Dictionary = {}
var totals: Dictionary = {}

func _attach(bus_name: String) -> void:
    if captures.has(bus_name):
        return
    var bus := AudioServer.get_bus_index(bus_name)
    if bus < 0:
        return
    var capture := AudioEffectCapture.new()
    capture.buffer_length = 1.0
    AudioServer.add_bus_effect(bus, capture)
    captures[bus_name] = capture
    totals[bus_name] = {"frames": 0, "peak": 0.0, "squares": 0.0}

func start() -> void:
    _attach("Master")

func poll(player: Node) -> void:
    for child in player.get_children():
        if child is AudioStreamPlayer and child.has_meta("yuris_channel"):
            _attach(String(child.bus))
    for bus_name in captures:
        var capture: AudioEffectCapture = captures[bus_name]
        var buffer := capture.get_buffer(capture.get_frames_available())
        var total: Dictionary = totals[bus_name]
        for sample in buffer:
            total.peak = maxf(total.peak, maxf(absf(sample.x), absf(sample.y)))
            total.squares += sample.x * sample.x + sample.y * sample.y
        total.frames += buffer.size()

func snapshot(player: Node) -> Dictionary:
    poll(player)
    var result := {"driver": AudioServer.get_driver_name(), "buses": {}, "players": []}
    for bus_name in totals:
        var total: Dictionary = totals[bus_name]
        var index := AudioServer.get_bus_index(bus_name)
        result.buses[bus_name] = {"frames": total.frames, "peak": total.peak,
            "rms": sqrt(total.squares / maxf(1.0, total.frames * 2.0)),
            "muted": AudioServer.is_bus_mute(index) if index >= 0 else false}
        totals[bus_name] = {"frames": 0, "peak": 0.0, "squares": 0.0}
    for child in player.get_children():
        if child is AudioStreamPlayer and child.has_meta("yuris_channel"):
            result.players.append({"channel": child.get_meta("yuris_channel"), "bus": child.bus,
                "playing": child.playing, "paused": child.stream_paused,
                "volume": child.volume_linear, "pitch": child.pitch_scale,
                "position": child.get_playback_position(), "length": child.stream.get_length(),
                "loop": child.stream.loop if child.stream is AudioStreamOggVorbis else false})
    return result

func close() -> void:
    for bus_name in captures:
        var bus := AudioServer.get_bus_index(bus_name)
        if bus < 0:
            continue
        for effect in range(AudioServer.get_bus_effect_count(bus) - 1, -1, -1):
            if AudioServer.get_bus_effect(bus, effect) == captures[bus_name]:
                AudioServer.remove_bus_effect(bus, effect)
    captures.clear()
    totals.clear()
