extends SceneTree

class ImportApp:
    extends "res://scripts/main.gd"

    var allowed := false
    var checked_video_permission := false
    var picker_opened := false

    func _ensure_android_storage_permission_for_import(video_import: bool = false) -> bool:
        checked_video_permission = video_import
        return allowed

    func _show_video_import_picker() -> void:
        picker_opened = true

func _initialize() -> void:
    var app := ImportApp.new()
    # The first-use notice precedes this gate on Android. Both file and folder
    # choices must remain behind it once that notice has been acknowledged.
    app.android_video_import_notice_shown = true
    app._open_video_import_dialog()
    var denied_correctly := app.checked_video_permission and not app.picker_opened
    app.allowed = true
    app._open_video_import_dialog()
    var allowed_correctly := app.picker_opened
    app.ui_motion.free()
    app.free()
    if not denied_correctly or not allowed_correctly:
        push_error("Video file/folder import must require the video storage permission gate")
        quit(1)
        return
    print("VIDEO_IMPORT_PERMISSIONS_OK")
    quit(0)
