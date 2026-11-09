extends Node

# WA2 publishes extracted OGG/WAV files; the application owns their playback.
# Keep finite plays pending until finished, and consume loop/stop/volume events
# once. Re-polling a pending voice must never restart it at sample zero.
const CACHE_LIMIT := 16
const ONESHOT_COUNT := 8
const ACK_RETRY_SECONDS := 0.5
const ACK_RETRY_LIMIT := 5

var runtime: Node
var players: Dictionary = {}
var oneshots: Array[AudioStreamPlayer] = []
var oneshot_cursor := 0
var states: Dictionary = {}
var handled: Dictionary = {}
var acknowledgements: Dictionary = {}
var stream_cache: Dictionary = {}
var elapsed := 0.0
var host_announced := false
var output_enabled := true
var paused := false
var play_count := 0
var completion_count := 0
var ack_count := 0
var load_failures := 0
var max_pending := 0

func start_session(player: Node, enable_output: bool = true) -> void:
    stop_session()
    runtime = player
    output_enabled = enable_output
    for channel in ["bgm0", "bgm1", "se0", "se1", "se2", "se3", "voice0"]:
        players[channel] = _new_player(channel)
    for index in range(ONESHOT_COUNT):
        oneshots.append(_new_player("se_oneshot_%d" % index))

func stop_session() -> void:
    runtime = null
    for child in get_children():
        if child is AudioStreamPlayer:
            child.stop()
            child.stream = null
            child.queue_free()
    players.clear()
    oneshots.clear()
    states.clear()
    handled.clear()
    acknowledgements.clear()
    stream_cache.clear()
    oneshot_cursor = 0
    elapsed = 0.0
    host_announced = false
    paused = false
    play_count = 0
    completion_count = 0
    ack_count = 0
    load_failures = 0
    max_pending = 0

func _new_player(channel: String) -> AudioStreamPlayer:
    var output := AudioStreamPlayer.new()
    output.name = channel
    output.bus = &"Master"
    add_child(output)
    output.finished.connect(_on_finished.bind(output))
    return output

func set_paused(value: bool) -> void:
    paused = value
    for output in _all_players():
        output.stream_paused = value

func _all_players() -> Array:
    return players.values() + oneshots

func _targets(channel: String) -> Array:
    if channel == "bgm":
        return [players["bgm0"], players["bgm1"]]
    if channel == "se_oneshot":
        return oneshots
    if players.has(channel):
        return [players[channel]]
    return []

static func runtime_state(value: Variant, depth: int = 0) -> Dictionary:
    # The bridge may wrap the provider's debug JSON inside another dictionary.
    if depth > 8:
        return {}
    if value is String:
        var text := String(value).strip_edges()
        if not text.begins_with("{"):
            return {}
        var json := JSON.new()
        if json.parse(text) != OK:
            return {}
        return runtime_state(json.data, depth + 1)
    if value is Dictionary:
        if value.has("pendingAudio"):
            return value
        for child in value.values():
            if child is Dictionary or child is String:
                var found := runtime_state(child, depth + 1)
                if not found.is_empty():
                    return found
    return {}

func poll(delta: float) -> void:
    if not is_instance_valid(runtime) or paused:
        return
    elapsed += delta
    if output_enabled and not host_announced:
        # Silent probes deliberately have no live output path or voice hold.
        runtime.set_engine_option("wa2.audio.host", "1")
        host_announced = true
    var snapshot := runtime_state(runtime.get_plugin_debug_info())
    var events: Array = snapshot.get("pendingAudio", [])
    max_pending = maxi(max_pending, events.size())
    var pending := {}
    for event in events:
        if not event is Dictionary:
            continue
        var seq := int(event.get("id", 0))
        pending[seq] = true
        if not handled.has(seq):
            handled[seq] = true
            _handle(event)
    # Retain guards only while an event is pending. This bounds long sessions
    # without clearing the guard for a voice that is still playing.
    for seq in handled.keys():
        if not pending.has(seq):
            handled.erase(seq)
    for seq in acknowledgements.keys():
        if not pending.has(seq):
            acknowledgements.erase(seq)
            continue
        var retry: Dictionary = acknowledgements[seq]
        if elapsed >= float(retry["due"]) and int(retry["tries"]) < ACK_RETRY_LIMIT:
            runtime.set_engine_option("wa2.audio.finished", str(seq))
            ack_count += 1
            retry["tries"] = int(retry["tries"]) + 1
            retry["due"] = elapsed + ACK_RETRY_SECONDS
    _update_fades(delta)

func _load_stream(path: String, looped: bool) -> AudioStream:
    path = path.replace(String.chr(92), "/")
    if OS.get_name() == "Windows" and path.begins_with("/") and not path.begins_with("//"):
        # std::filesystem emits drive-rooted /tmp paths on Windows. Godot
        # requires the explicit current drive for these native cache files.
        var current := DirAccess.open(".").get_current_dir()
        path = current.substr(0, 2) + path
    # Loop flags live on the resource: cache each loop mode separately so a
    # finite use of a clip cannot accidentally inherit a looped SE's flags.
    var key := path + ("|loop" if looped else "|once")
    if stream_cache.has(key):
        var cached: AudioStream = stream_cache[key]
        stream_cache.erase(key)
        stream_cache[key] = cached
        return cached
    var bytes := FileAccess.get_file_as_bytes(path)
    var stream: AudioStream
    if not bytes.is_empty():
        # Archive entries can retain .wav names even when their payload is OGG.
        if bytes.size() >= 4 and bytes.slice(0, 4).get_string_from_ascii() == "OggS":
            var ogg := AudioStreamOggVorbis.load_from_buffer(bytes)
            if ogg != null:
                ogg.loop = looped
                stream = ogg
        else:
            var wav := AudioStreamWAV.load_from_buffer(bytes)
            if wav != null:
                wav.loop_mode = AudioStreamWAV.LOOP_FORWARD if looped else AudioStreamWAV.LOOP_DISABLED
                if looped and wav.loop_end <= wav.loop_begin:
                    wav.loop_begin = 0
                    wav.loop_end = int(wav.get_length() * wav.mix_rate)
                stream = wav
    if stream == null:
        load_failures += 1
        push_warning("[wa2-audio] Cannot decode %s" % path)
        return null
    stream_cache[key] = stream
    while stream_cache.size() > CACHE_LIMIT:
        stream_cache.erase(stream_cache.keys()[0])
    return stream

func _ack(seq: int) -> void:
    if acknowledgements.has(seq) or not is_instance_valid(runtime):
        return
    runtime.set_engine_option("wa2.audio.finished", str(seq))
    ack_count += 1
    acknowledgements[seq] = {"tries": 0, "due": elapsed + ACK_RETRY_SECONDS}

func _handle(event: Dictionary) -> void:
    var seq := int(event.get("id", 0))
    var channel := String(event.get("channel", ""))
    var action := String(event.get("action", ""))
    var duration := maxf(0.0, float(event.get("fade", 0)) / 60.0)
    var volume := clampf(float(event.get("volume", 255)) / 256.0, 0.0, 1.0)
    match action:
        "play":
            var output: AudioStreamPlayer = players.get(channel)
            if channel == "se_oneshot":
                output = oneshots[oneshot_cursor]
                oneshot_cursor = (oneshot_cursor + 1) % oneshots.size()
            if output == null:
                push_warning("[wa2-audio] Unsupported channel %s" % channel)
                _ack(seq)
                return
            var looped := int(event.get("loop", 0)) != 0
            var stream := _load_stream(String(event.get("path", "")), looped)
            # Replacing a voice/SE cancels the old finite playback; Godot's
            # stop() emits no finished signal, so retire that event explicitly.
            _retire(output)
            if stream == null:
                _ack(seq) # Missing files must not leave VW/SEW blocked forever.
                return
            output.stream = stream
            output.volume_linear = 0.0 if duration > 0.0 else volume
            output.stream_paused = paused
            states[output.get_instance_id()] = {
                "seq": seq, "channel": channel, "loop": looped,
                "from": output.volume_linear, "to": volume,
                "time": 0.0, "duration": duration, "stopping": false,
            }
            output.play()
            play_count += 1
            print("[wa2-audio] play seq=%d channel=%s loop=%s length=%.3f" % [seq, channel, looped, stream.get_length()])
            if looped:
                _ack(seq)
        "stop", "volume":
            for output: AudioStreamPlayer in _targets(channel):
                var id := output.get_instance_id()
                if not states.has(id):
                    continue
                if action == "stop" and duration <= 0.0:
                    _retire(output)
                    continue
                var state: Dictionary = states[id]
                state["from"] = output.volume_linear
                state["to"] = 0.0 if action == "stop" else volume
                state["time"] = 0.0
                state["duration"] = duration
                state["stopping"] = action == "stop"
                if duration <= 0.0:
                    output.volume_linear = volume
            _ack(seq)
        _:
            # Leave unsupported commands visible for diagnosis.
            push_warning("[wa2-audio] Unsupported action %s" % action)

func _retire(output: AudioStreamPlayer) -> void:
    var id := output.get_instance_id()
    if states.has(id):
        var state: Dictionary = states[id]
        if not bool(state["loop"]):
            _ack(int(state["seq"]))
        states.erase(id)
    output.stop()
    output.stream = null

func _on_finished(output: AudioStreamPlayer) -> void:
    var id := output.get_instance_id()
    if not states.has(id):
        return
    var state: Dictionary = states[id]
    completion_count += 1
    _ack(int(state["seq"]))
    states.erase(id)
    output.stream = null

func _update_fades(delta: float) -> void:
    for output: AudioStreamPlayer in _all_players():
        var id := output.get_instance_id()
        if not states.has(id):
            continue
        var state: Dictionary = states[id]
        var duration := float(state["duration"])
        state["time"] = float(state["time"]) + delta
        var weight := minf(float(state["time"]) / duration, 1.0) if duration > 0.0 else 1.0
        output.volume_linear = lerpf(float(state["from"]), float(state["to"]), weight)
        if bool(state["stopping"]) and weight >= 1.0:
            _retire(output)

func debug_snapshot() -> Dictionary:
    var active: Array = []
    for output: AudioStreamPlayer in _all_players():
        if output.stream != null:
            var state: Dictionary = states.get(output.get_instance_id(), {})
            active.append({"channel": state.get("channel", output.name),
                "seq": state.get("seq", 0), "playing": output.playing,
                "position": output.get_playback_position(), "length": output.stream.get_length(),
                "volume": output.volume_linear, "loop": state.get("loop", false)})
    return {"hostAnnounced": host_announced, "playCount": play_count,
        "completionCount": completion_count, "ackCount": ack_count,
        "loadFailures": load_failures, "pendingGuards": handled.size(),
        "pendingAcks": acknowledgements.size(), "maxPending": max_pending,
        "cacheSize": stream_cache.size(), "active": active}
