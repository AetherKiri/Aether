extends SceneTree

const Host = preload("res://scripts/wa2_audio_host.gd")

class Runtime:
    extends Node
    var events: Array = []
    var acks: Array[int] = []
    var drop_next_ack := false
    var announced := false

    func get_plugin_debug_info() -> String:
        return JSON.stringify({"runtime": JSON.stringify({"pendingAudio": events})})

    func set_engine_option(key: String, value: String) -> int:
        if key == "wa2.audio.host":
            announced = true
        elif key == "wa2.audio.finished":
            var seq := int(value)
            acks.append(seq)
            if drop_next_ack:
                drop_next_ack = false
            else:
                events = events.filter(func(event: Dictionary): return int(event["id"]) != seq)
        return 0

var failures := 0
var host: Node
var runtime: Runtime
var clip := ""

func _initialize() -> void:
    _run.call_deferred()

func _expect(value: bool, message: String) -> void:
    if not value:
        failures += 1
        push_error(message)

func _event(seq: int, action: String, channel: String, looped: int = 0, fade: int = 0, volume: int = 256) -> Dictionary:
    return {"id": seq, "action": action, "channel": channel,
        "path": clip, "loop": looped, "fade": fade, "volume": volume}

func _run() -> void:
    var fixture := DirAccess.create_temp("wa2-audio-host")
    clip = fixture.get_current_dir().path_join("voice.wav")
    var wav := AudioStreamWAV.new()
    wav.format = AudioStreamWAV.FORMAT_16_BITS
    wav.mix_rate = 24000
    var pcm := PackedByteArray()
    pcm.resize(12000) # 0.25 seconds of real decoded PCM.
    for index in range(6000):
        pcm.encode_s16(index * 2, int(sin(float(index) * 0.12) * 12000.0))
    wav.data = pcm
    _expect(wav.save_to_wav(clip) == OK, "Create finite audio fixture")
    runtime = Runtime.new()
    root.add_child(runtime)
    host = Host.new()
    root.add_child(host)
    host.start_session(runtime)

    runtime.events = [_event(1, "play", "voice0")]
    host.poll(0.01)
    _expect(runtime.announced, "Announce real host before voice waits")
    _expect(host.players["voice0"].playing, "Start finite voice")
    for _index in range(20):
        host.poll(0.001)
    _expect(host.play_count == 1 and not runtime.acks.has(1), "Repeated polling neither restarts nor acknowledges an unfinished voice")
    var deadline := Time.get_ticks_msec() + 2000
    while Time.get_ticks_msec() < deadline and not runtime.acks.has(1):
        host.poll(0.01)
        await process_frame
    host.poll(0.01)
    _expect(runtime.acks.has(1) and host.completion_count == 1, "Natural finished signal acknowledges the finite voice")
    _expect(runtime.events.is_empty() and host.handled.is_empty(), "Completion drains the native queue and handling guards")

    runtime.drop_next_ack = true
    runtime.events = [_event(2, "play", "bgm0", 1)]
    host.poll(0.01)
    _expect(runtime.acks.has(2) and runtime.events.size() == 1, "Loop play acknowledges on consumption, with simulated lost ACK")
    for _index in range(8):
        host.poll(0.1)
    _expect(host.play_count == 2 and runtime.events.is_empty(), "Lost ACK retries without restarting the BGM")
    var bgm: AudioStreamPlayer = host.players["bgm0"]
    var until := Time.get_ticks_msec() + 400
    while Time.get_ticks_msec() < until:
        await process_frame
    _expect(bgm.playing and bgm.stream.loop_mode == AudioStreamWAV.LOOP_FORWARD, "BGM loops beyond the fixture duration")

    runtime.events = [_event(3, "volume", "bgm", 0, 60, 128)]
    host.poll(0.5)
    _expect(absf(bgm.volume_linear - 0.75) < 0.02 and runtime.acks.has(3), "Volume ramp uses elapsed seconds and acknowledges on consumption")
    host.poll(0.5)
    _expect(absf(bgm.volume_linear - 0.5) < 0.02, "Volume ramp reaches its target")
    runtime.events = [_event(4, "stop", "bgm", 0, 30)]
    host.poll(0.25)
    _expect(bgm.playing and absf(bgm.volume_linear - 0.25) < 0.02 and runtime.acks.has(4), "Fade-stop acknowledges the command while playback fades")
    host.poll(0.25)
    _expect(not bgm.playing and bgm.stream == null, "Fade-stop releases the player after the ramp")

    runtime.events = [_event(5, "play", "se0")]
    host.poll(0.01)
    host.set_paused(true)
    _expect(host.players["se0"].stream_paused, "Pause host audio with the application")
    host.set_paused(false)
    runtime.events.append(_event(6, "stop", "se0"))
    host.poll(0.01)
    _expect(runtime.acks.has(5) and runtime.acks.has(6) and not host.players["se0"].playing, "Immediate stop retires finite playback and consumes both events")

    runtime.events = [_event(7, "play", "voice0")]
    host.poll(0.01)
    runtime.events = [_event(8, "play", "voice0")]
    host.poll(0.01)
    _expect(runtime.acks.has(7) and not runtime.acks.has(8), "Replacement retires only the superseded voice")
    host.stop_session()
    _expect(host.states.is_empty() and host.stream_cache.is_empty() and host.runtime == null, "Session teardown clears playback, cache and ACK state")
    host.start_session(runtime, false)
    _expect(not host.host_announced, "Silent session does not announce a live output path")
    host.stop_session()
    host.free()
    runtime.free()
    DirAccess.remove_absolute(clip)
    fixture = null
    await create_timer(0.15).timeout
    if failures == 0:
        print("WA2_AUDIO_HOST_OK")
    quit(1 if failures else 0)
