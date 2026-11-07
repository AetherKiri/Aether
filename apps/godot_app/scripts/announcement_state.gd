extends RefCounted

var _path: String

func _init(path: String) -> void:
    _path = path

func should_show(notice_id: String, version: int, now: int) -> bool:
    var cfg := ConfigFile.new()
    cfg.load(_path)
    if int(cfg.get_value(notice_id, "dismissed_version", 0)) >= version:
        return false
    # Existing installations only stored a timestamp for the first announcement.
    # Honor that choice for version 1 without suppressing any newer version.
    var snoozed_version := int(cfg.get_value(notice_id, "snoozed_version", 1))
    return snoozed_version != version or now >= int(cfg.get_value(notice_id, "snoozed_until", 0))

func dismiss(notice_id: String, version: int) -> Error:
    var cfg := ConfigFile.new()
    cfg.load(_path)
    cfg.set_value(notice_id, "dismissed_version", maxi(
        version, int(cfg.get_value(notice_id, "dismissed_version", 0))
    ))
    return cfg.save(_path)

func snooze(notice_id: String, version: int, until: int) -> Error:
    var cfg := ConfigFile.new()
    cfg.load(_path)
    cfg.set_value(notice_id, "snoozed_version", version)
    cfg.set_value(notice_id, "snoozed_until", until)
    return cfg.save(_path)
