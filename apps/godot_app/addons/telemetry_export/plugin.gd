@tool
extends EditorPlugin

var _export_plugin: EditorExportPlugin


func _enter_tree() -> void:
    _export_plugin = TelemetryExportPlugin.new()
    add_export_plugin(_export_plugin)


func _exit_tree() -> void:
    remove_export_plugin(_export_plugin)
    _export_plugin = null


class TelemetryExportPlugin extends EditorExportPlugin:
    const BUILD := preload("res://telemetry_build.gd")

    func _get_name() -> String:
        return "AetherTelemetryExport"

    func _export_begin(features: PackedStringArray, is_debug: bool, _path: String, _flags: int) -> void:
        var raw_endpoint := OS.get_environment("AETHER_TELEMETRY_ENDPOINT")
        var endpoint := BUILD.normalize_endpoint(raw_endpoint)
        if not raw_endpoint.is_empty() and endpoint.is_empty():
            push_warning("AETHER_TELEMETRY_ENDPOINT is invalid. This export cannot send telemetry.")

        var channel := OS.get_environment("AETHER_TELEMETRY_CHANNEL")
        if not BUILD.is_valid_channel(channel):
            if not channel.is_empty():
                push_warning("AETHER_TELEMETRY_CHANNEL is invalid. Using the default export channel.")
            channel = _default_channel(features, is_debug)

        var data := JSON.stringify({"channel": channel, "endpoint": endpoint})
        add_file(BUILD.CONFIG_PATH, data.to_utf8_buffer(), false)

    func _default_channel(features: PackedStringArray, is_debug: bool) -> String:
        if is_debug:
            return "debug"
        if features.has("web"):
            return "self_hosted"
        if features.has("macos") or features.has("ios"):
            return "apple_release"
        if features.has("windows"):
            return "source"
        return "release"

    func _export_file(path: String, _type: String, _features: PackedStringArray) -> void:
        if path.begins_with("res://addons/telemetry_export/"):
            skip()
