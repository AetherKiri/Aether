extends RefCounted
## Build metadata shared by the application and the Godot export plugin.

const CONFIG_PATH := "res://config/telemetry_export.json"
const CHANNEL_PATTERN := "\\A[a-z0-9][a-z0-9_-]{0,39}\\z"
const DNS_LABEL := "[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
const ENDPOINT_PATTERN := "\\Ahttps://(" + DNS_LABEL + "(?:\\." + DNS_LABEL + ")*)(?::([0-9]{1,5}))?(?:/v1/events|/)?\\z"


static func get_endpoint() -> String:
    var endpoint: Variant = _get_export_config().get("endpoint", "")
    return normalize_endpoint(endpoint) if endpoint is String else ""


static func get_metadata() -> Dictionary:
    var channel: Variant = _get_export_config().get("channel", "")
    if not channel is String or not is_valid_channel(channel):
        channel = "source"
        if OS.has_feature("template"):
            channel = "debug" if OS.has_feature("debug") else "release"
    return {
        "app_version": str(ProjectSettings.get_setting("application/config/version", "development")),
        "app_build": str(ProjectSettings.get_setting("application/config/build_number", "development")),
        "channel": channel,
    }


static func is_valid_channel(channel: String) -> bool:
    return channel.length() <= 40 and RegEx.create_from_string(CHANNEL_PATTERN).search(channel) != null


static func normalize_endpoint(endpoint: String) -> String:
    # Accept an HTTPS origin or the exact ingestion path. The syntax excludes
    # credentials, queries, fragments, percent escapes and all whitespace.
    if endpoint.length() > 512:
        return ""
    var parsed := RegEx.create_from_string(ENDPOINT_PATTERN).search(endpoint)
    if parsed == null:
        return ""
    var host := parsed.get_string(1).to_lower()
    if host.length() > 253:
        return ""
    var port := parsed.get_string(2)
    if not port.is_empty():
        var port_number := port.to_int()
        if port_number < 1 or port_number > 65535:
            return ""
        if port_number != 443:
            host += ":%d" % port_number
    return "https://%s/v1/events" % host


static func _get_export_config() -> Dictionary:
    # Apple recovery exports briefly stage this file in the checkout. A
    # simultaneous source launch must never use that export's configuration.
    if not OS.has_feature("template") and not FileAccess.file_exists("res://project.binary"):
        return {}
    if not FileAccess.file_exists(CONFIG_PATH):
        return {}
    var config := FileAccess.open(CONFIG_PATH, FileAccess.READ)
    if config == null or config.get_length() > 1024:
        return {}
    var data: Variant = JSON.parse_string(config.get_as_text())
    return data if data is Dictionary else {}
