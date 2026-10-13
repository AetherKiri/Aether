extends SceneTree

const Library := preload("res://scripts/video_library.gd")

var failures := 0
var fixture: DirAccess

func _expect(value: bool, message: String) -> void:
    if not value:
        failures += 1
        push_error(message)

func _write(path: String, content: String = "video fixture") -> void:
    DirAccess.make_dir_recursive_absolute(path.get_base_dir())
    var file := FileAccess.open(path, FileAccess.WRITE)
    _expect(file != null, "Can write fixture: " + path)
    if file != null:
        file.store_string(content)

func _paths(items: Array[Dictionary]) -> Array[String]:
    var result: Array[String] = []
    for item in items:
        result.append(String(item["path"]))
    return result

func _initialize() -> void:
    fixture = DirAccess.create_temp("aether-video-library")
    _expect(fixture != null, "Can create isolated fixture directory")
    if fixture == null:
        quit(1)
        return
    var base := fixture.get_current_dir()
    var root_path := base.path_join("Video")
    var season := root_path.path_join("Season2")
    var nested := season.path_join("Season10")
    var empty := root_path.path_join("Season10")
    var intro := root_path.path_join("intro.MP4")
    var clip := season.path_join("clip2.mkv")
    var deep_clip := nested.path_join("片段10.webm")
    var loose := base.path_join("loose.mov")
    var outside := base.path_join("VideoNeighbor")
    _write(intro)
    _write(clip)
    _write(deep_clip)
    _write(loose)
    _write(outside.path_join("outside.mp4"))
    _write(root_path.path_join("note.txt"))
    _write(root_path.path_join("intro.srt"), "1\n00:00:00,000 --> 00:00:01,000\nSubtitle\n")
    _write(root_path.path_join(".hidden/secret.mp4"))
    DirAccess.make_dir_recursive_absolute(empty)
    if OS.get_name() in ["macOS", "Linux"]:
        _expect(fixture.create_link(root_path, root_path.path_join("cycle")) == OK, "Can create directory symlink fixture")

    var list_path := base.path_join("library.json")
    var hidden_path := base.path_join("hidden.json")
    # The previous app stored a flat array. Invalid and duplicate entries must
    # not prevent existing single-file imports from loading after an upgrade.
    _write(list_path, JSON.stringify([
        {"path": loose, "name": "old name"}, {"path": loose},
        {"path": ""}, {"path": 17}, {"path": base.path_join("missing.mp4")}, null,
    ]))
    var library := Library.new(list_path, hidden_path)
    library.refresh()
    _expect(_paths(library.videos) == [loose], "Legacy single-file imports still load and deduplicate")
    _expect(library.add_source(root_path + "/"), "Can import a folder")
    library.refresh()
    _expect(library.sources.size() == 2, "Folder is persisted as one source")
    _expect(_paths(library.entries) == [root_path, loose], "Library root shows the folder before individual videos")
    _expect(library.videos.size() == 4, "Nested videos join one catalog; hidden files, subtitles and directory links are skipped")
    _expect(_paths(library.search_entries()).has(deep_clip), "Recursive search can still reach videos inside imported folders")
    _expect(library.add_source(root_path), "Reimporting the same folder succeeds")
    _expect(library.add_source(season), "Can also import an overlapping folder")
    library.refresh()
    _expect(library.sources.size() == 3 and library.videos.size() == 4, "Overlapping folder imports do not duplicate playable videos")
    library.remove_entry(season)
    library.refresh()
    _expect(library.sources.size() == 2 and library.videos.size() == 4, "Removing one overlapping source preserves videos in the other")
    _expect(not library.enter_directory(outside), "Unimported folders cannot be opened from the library root")
    _expect(library.enter_directory(root_path), "Can open imported folder")
    _expect(_paths(library.entries) == [season, empty, intro], "Each level lists its own folders first in natural order")
    _expect(library.enter_directory(season) and library.enter_directory(nested), "Can enter multiple nested levels")
    _expect(_paths(library.entries) == [deep_clip], "Nested file retains its original path for playback, subtitles and progress")
    _expect(_paths(library.search_entries()) == [deep_clip], "Search is scoped to the current folder subtree")
    _expect(library.location_label() == "Video/Season2/Season10", "Navigation label includes each level")
    _expect(not library.enter_directory(outside), "Navigation cannot escape through a common path prefix")
    _expect(library.go_up() and library.current_directory == season, "Back moves one level")
    _expect(library.go_up() and library.current_directory == root_path, "Back reaches the imported root")
    _expect(library.enter_directory(empty) and library.entries.is_empty(), "Empty folders can be browsed")
    _expect(library.can_go_up(), "Empty folder still has a working back action")
    library.go_to_library()
    _expect(library.current_directory.is_empty() and not library.go_up(), "Library root is the desktop navigation boundary")

    library = Library.new(list_path, hidden_path)
    library.refresh()
    _expect(_paths(library.entries) == [root_path, loose], "Imported folders survive a new library instance")
    var added := season.path_join("new.mp4")
    _write(added)
    library.refresh()
    _expect(library.videos.size() == 5 and _paths(library.videos).has(added), "Refreshing detects videos added to imported folders")
    library.remove_entry(clip)
    library.refresh()
    _expect(not _paths(library.videos).has(clip) and FileAccess.file_exists(clip), "Removing a scanned video hides it without deleting it")
    library.enter_directory(root_path)
    library.enter_directory(empty)
    library.refresh()
    library.go_up()
    library.enter_directory(season)
    _expect(not _paths(library.entries).has(clip), "Browsing another folder does not forget hidden videos")
    _write(hidden_path, JSON.stringify({clip: int(FileAccess.get_modified_time(clip)) - 1}))
    library.refresh()
    _expect(_paths(library.videos).has(clip), "A video with a new modification time becomes visible again")
    library.remove_entry(clip)
    library.refresh()
    _expect(library.add_source(clip), "Explicit file import can restore a hidden video")
    library.refresh()
    _expect(_paths(library.videos).has(clip) and library.videos.size() == 5, "Restored video still appears once in the catalog")
    library.remove_entry(clip)
    library.refresh()

    # iOS derives its root from Video/, ignoring desktop-style import records.
    var ios := Library.new(list_path, base.path_join("ios-hidden.json"))
    ios.refresh(root_path)
    _expect(ios.current_directory == root_path and not ios.can_go_up(), "iOS starts at Video and cannot leave its root")
    _expect(_paths(ios.entries) == [season, empty, intro] and ios.videos.size() == 4, "iOS displays folders and root videos without flattening")
    _expect(ios.enter_directory(season) and ios.enter_directory(nested), "iOS can open nested folders")
    _expect(not ios.enter_directory(outside), "iOS browser stays inside Video")
    ios.refresh(root_path)
    _expect(ios.current_directory == nested, "Refresh preserves the folder used when returning from playback")
    _expect(not ios.can_remove(Library.entry_info(nested)), "Browsing does not expose removal of physical folders")
    ios.go_up()
    ios.remove_entry(clip)
    ios.refresh(root_path)
    ios.go_to_library()
    ios.enter_directory(empty)
    ios.refresh(root_path)
    ios.go_up()
    ios.enter_directory(season)
    _expect(not _paths(ios.entries).has(clip), "iOS hidden videos persist across folder navigation")
    ios.enter_directory(nested)
    DirAccess.remove_absolute(deep_clip)
    DirAccess.remove_absolute(nested)
    ios.refresh(root_path)
    _expect(ios.current_directory == season, "A removed current folder falls back to its existing parent")
    ios.go_to_library()
    _expect(ios.current_directory == root_path, "iOS root action returns to Video")

    library.go_to_library()
    library.enter_directory(root_path)
    library.remove_entry(root_path)
    library.refresh()
    _expect(library.current_directory.is_empty(), "Unimporting the current root returns to the library")
    _expect(_paths(library.entries) == [loose], "Unimporting a folder removes only that source")
    _expect(FileAccess.file_exists(intro) and FileAccess.file_exists(added), "Folder removal leaves videos on disk")

    print("VIDEO_LIBRARY_FOLDERS_OK" if failures == 0 else "VIDEO_LIBRARY_FOLDERS_FAILED: %d" % failures)
    quit(0 if failures == 0 else 1)
