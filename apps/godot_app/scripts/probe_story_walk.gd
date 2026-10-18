extends RefCounted

# Shared by the editor script and the packaged App JSON probe.
func run(tree: SceneTree, player, tick_frame: Callable, click: Callable, capture: Callable, output_dir: String, step: int, label: String, action: Dictionary) -> int:
    var latest := ""
    var age := 0
    var line := -1
    var completed := false
    var failure := ""
    var timings: Array[float] = []
    var lines: Array = []
    var samples: Array = []
    var captures: Array[int] = []
    for value in action.get("capture_ages", [24, 72]):
        captures.append(int(value))
    var capture_frames: Array[int] = []
    for value in action.get("capture_frames", [1, 60, 180, 300]):
        capture_frames.append(int(value))
    var runtime_build := ""
    var max_frames := int(action.get("max_frames", 18000))
    var dwell := int(action.get("dwell_frames", 90))
    var return_count := int(action.get("return_selection_min", 5))
    var return_scene := String(action.get("return_scene", ""))
    var scene_age := 0
    for frame_index in range(max_frames):
        var started := Time.get_ticks_usec()
        var ok: bool = bool(tick_frame.call())
        timings.append(float(Time.get_ticks_usec() - started) / 1000.0)
        if not ok:
            failure = "tick failed: %s" % player.get_last_error()
            break
        var parsed = JSON.parse_string(String(player.get_plugin_debug_info()))
        if not parsed is Dictionary:
            failure = "runtime debug JSON unavailable"
            break
        var state: Dictionary = parsed
        runtime_build = String(state.get("yurisRuntimeBuild", ""))
        if bool(state.get("dialogWaiting", false)) or bool(state.get("ended", false)):
            failure = "unexpected dialog or END"
            await _checkpoint(tree, capture, output_dir, step, "%s-failure" % label, state)
            break
        var text := ""
        for run in state.get("textRuns", []):
            if String(run.get("layer", "")).is_empty():
                var value := String(run.get("text", ""))
                if not value.begins_with("\u0001SEL:") and not value.begins_with("\\x01SEL:"):
                    text += value
        var choices: Array = state.get("selectionLabels", [])
        if not return_scene.is_empty() and line >= 0 and String(state.get("directScene", "")) == return_scene:
            scene_age += 1
            if scene_age >= int(action.get("return_scene_frames", 120)):
                completed = true
                await _checkpoint(tree, capture, output_dir, step, "%s-return" % label, state)
                step += 1
                break
        else:
            scene_age = 0
        if bool(state.get("selectionActive", false)):
            if choices.size() >= return_count and line >= 0:
                completed = true
                await _checkpoint(tree, capture, output_dir, step, "%s-return" % label, state)
                step += 1
                break
            player.send_key_event(true, 49 + int(action.get("branch_choice", 0)), 0, 0)
            player.send_key_event(false, 49 + int(action.get("branch_choice", 0)), 0, 0)
        if not text.is_empty() and text != latest:
            latest = text
            age = 0
            line += 1
            lines.append({"line": line, "frame": frame_index, "text": text})
            print("story_line label=%s line=%d frame=%d text=%s" % [label, line, frame_index, text])
        if capture_frames.has(frame_index):
            await _checkpoint(tree, capture, output_dir, step, "%s-frame%05d" % [label, frame_index], state)
            step += 1
        if not text.is_empty():
            age += 1
            if captures.has(age):
                await _checkpoint(tree, capture, output_dir, step, "%s-line%02d-age%03d" % [label, line, age], state)
                step += 1
        if frame_index % int(action.get("sample_every", 5)) == 0:
            var layers: Array = []
            for layer in state.get("layers", []):
                var id := String(layer.get("id", ""))
                if id.begins_with("SPL") and not id.begins_with("SPLBUF") and (bool(layer.get("hasImage", false)) or bool(layer.get("hasEmote", false))):
                    if float(layer.get("renderAlpha", 0)) > 0 or int(layer.get("color", 0)) & 255:
                        layers.append(layer)
            samples.append({"frame": frame_index, "line": line, "tick_ms": timings.back(), "layers": layers, "emotes": state.get("emotes", []), "media": state.get("media", [])})
        if bool(state.get("textClickWaiting", false)) and not bool(state.get("textRevealActive", false)) and age >= dwell:
            click.call(Vector2(float(action.get("x", 500)), float(action.get("y", 520))))
            age = 0
        await tree.process_frame
    if not completed and failure.is_empty():
        failure = "story did not return to selection before frame limit"
    timings.sort()
    var report := {"completed": completed, "failure": failure, "runtime_build": runtime_build, "lines": lines, "samples": samples,
        "frames": timings.size(), "median_tick_ms": 0.0, "p95_tick_ms": 0.0, "p99_tick_ms": 0.0}
    if not timings.is_empty():
        report["median_tick_ms"] = timings[int(timings.size() / 2)]
        report["p95_tick_ms"] = timings[mini(timings.size() - 1, int(timings.size() * 0.95))]
        report["p99_tick_ms"] = timings[mini(timings.size() - 1, int(timings.size() * 0.99))]
    var file := FileAccess.open(output_dir.path_join(label + "-story.json"), FileAccess.WRITE)
    file.store_string(JSON.stringify(report))
    print("story_walk label=%s completed=%s frames=%d lines=%d median_tick_ms=%.2f p95_tick_ms=%.2f failure=%s" % [
        label, completed, timings.size(), lines.size(), report.median_tick_ms, report.p95_tick_ms, failure])
    if not failure.is_empty():
        printerr(failure)
        return -1
    return step

func _checkpoint(tree: SceneTree, capture: Callable, output_dir: String, step: int, label: String, state: Dictionary) -> void:
    await tree.process_frame
    var stem := output_dir.path_join("aetherkiri-step-%03d-%s" % [step, label])
    var frame_image: Image = capture.call()
    frame_image.save_png(stem + ".png")
    var file := FileAccess.open(stem + ".json", FileAccess.WRITE)
    file.store_string(JSON.stringify(state))
    print("story_checkpoint label=%s screenshot=%s" % [label, stem + ".png"])
