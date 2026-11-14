extends SceneTree

const MAIN_SCRIPT := preload("res://scripts/main.gd")

func _initialize() -> void:
    var app = MAIN_SCRIPT.new()
    var cases := {
        "content://com.android.externalstorage.documents/tree/primary%3AGames%2FMyGame":
            "/storage/emulated/0/Games/MyGame",
        "content://com.android.externalstorage.documents/tree/primary%3A":
            "/storage/emulated/0",
        "content://com.android.externalstorage.documents/tree/home%3AVNs%2FGame":
            "/storage/emulated/0/Documents/VNs/Game",
        "content://com.android.externalstorage.documents/tree/home%3A":
            "/storage/emulated/0/Documents",
        "content://com.android.externalstorage.documents/tree/1234-ABCD%3AGames%2FMyGame":
            "/storage/1234-ABCD/Games/MyGame",
        "content://com.android.externalstorage.documents/tree/1234-ABCD%3A":
            "/storage/1234-ABCD",
        "content://com.android.externalstorage.documents/tree/1234-ABCD%3A%E6%B8%B8%E6%88%8F%20Folder":
            "/storage/1234-ABCD/游戏 Folder",
    }
    for uri in cases:
        var actual: String = app._android_external_storage_path_from_tree_uri(uri)
        if actual != cases[uri]:
            push_error(
                "Unexpected Android tree path: %s -> %s (expected %s)" % [
                    uri, actual, cases[uri]
                ]
            )
            app.ui_motion.free()
            app.free()
            quit(1)
            return

    # Other document providers do not expose a real filesystem path. Leave
    # their URIs untouched so callers can reject them explicitly.
    var unsupported := "content://com.android.providers.downloads.documents/tree/raw%3A%2Fstorage%2Femulated%2F0%2FDownload%2FGame"
    if app._android_external_storage_path_from_tree_uri(unsupported) != unsupported:
        push_error("Non-ExternalStorageProvider tree URIs must remain untouched")
        app.ui_motion.free()
        app.free()
        quit(1)
        return

    app.ui_motion.free()
    app.free()
    print("ANDROID_TREE_URI_OK")
    quit(0)
