extends SceneTree

const MAIN_SCRIPT := preload("res://scripts/main.gd")

class AndroidApp extends MAIN_SCRIPT:
    var primary_storage_root: String

    func _android_primary_storage_root() -> String:
        return primary_storage_root

func _initialize() -> void:
    var app := AndroidApp.new()
    # The picker IDs must resolve relative to the root provided by Android.
    for root in ["/test/shared-storage", "/test/profile/shared-storage"]:
        app.primary_storage_root = root
        if not _check_picker_paths(app, root):
            app.ui_motion.free()
            app.free()
            quit(1)
            return

    app.ui_motion.free()
    app.free()
    print("ANDROID_TREE_URI_OK")
    quit(0)

func _check_picker_paths(app: AndroidApp, root: String) -> bool:
    var cases := {
        "content://com.android.externalstorage.documents/tree/primary%3AGames":
            root.path_join("Games"),
        "content://com.android.externalstorage.documents/tree/primary%3AGames%2FMyGame":
            root.path_join("Games/MyGame"),
        "content://com.android.externalstorage.documents/tree/primary%3A":
            root,
        "content://com.android.externalstorage.documents/tree/home%3AVNs%2FGame":
            root.path_join("Documents/VNs/Game"),
        "content://com.android.externalstorage.documents/tree/home%3A":
            root.path_join("Documents"),
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
            return false

    # Other document providers do not expose a real filesystem path. Leave
    # their URIs untouched so callers can reject them explicitly.
    var download_id := "raw:" + root.path_join("Download/Game")
    var unsupported := "content://com.android.providers.downloads.documents/tree/" + download_id.uri_encode()
    if app._android_external_storage_path_from_tree_uri(unsupported) != unsupported:
        push_error("Non-ExternalStorageProvider tree URIs must remain untouched")
        return false

    const LaunchEntry := preload("res://scripts/game_launch_entry.gd")
    var root_path := root.path_join("Games/游戏+ A")
    var file_cases := {
        "content://com.android.externalstorage.documents/document/primary%3AGames%2F%E6%B8%B8%E6%88%8F+%20A%2FGame.exe":
            "Game.exe",
        "content://com.android.externalstorage.documents/tree/primary%3AGames/document/primary%3AGames%2F%E6%B8%B8%E6%88%8F%2B%20A%2Fpatch%2Fdata.xp3":
            "patch/data.xp3",
        "content://com.android.providers.downloads.documents/document/" + ("raw:" + root_path.path_join("Game.exe")).uri_encode():
            "Game.exe",
        "file://" + root + "/Games/%E6%B8%B8%E6%88%8F%2B%20A/Game.exe":
            "Game.exe",
        root_path.path_join("Game.exe"): "Game.exe",
        "content://com.android.externalstorage.documents/document/primary%3AGames%2FOther%2FGame.exe":
            "",
        "content://com.android.externalstorage.documents/document/primary%3AGames%2F%E6%B8%B8%E6%88%8F%2B%20A%2F..%2FOther%2FGame.exe":
            "",
        "content://com.example.provider/document/Game.exe": "",
        "content://com.example.fileprovider/root" + root + "/Games/%E6%B8%B8%E6%88%8F%2B%20A/launch.hcb": "",
    }
    for uri in file_cases:
        var selected_path: String = app._android_launch_file_path(uri)
        var entry := LaunchEntry.relative_path_for_selection(root_path, selected_path)
        if entry != file_cases[uri]:
            push_error("Unexpected Android launch entry: %s -> %s (expected %s)" % [uri, entry, file_cases[uri]])
            return false
    return true
