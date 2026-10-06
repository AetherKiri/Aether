class_name AppUpdater
extends RefCounted

## AppUpdater
## Handles version checking and update flows for AetherKiri.
## Supports GitHub Releases and Apple App Store (iOS / macOS).

const GITHUB_RELEASES_URL := "https://api.github.com/repos/AetherKiri/Aether/releases?per_page=10"
const APPLE_APP_ID := "6796580469"
const APPLE_LOOKUP_URL := "https://itunes.apple.com/lookup?id=6796580469"
const APPLE_STORE_URL := "https://apps.apple.com/app/id6796580469"
const APPLE_TESTFLIGHT_URL := "itms-beta://"
const GITHUB_REPO_RELEASES_PAGE := "https://github.com/AetherKiri/Aether/releases"

enum CheckStatus {
    SUCCESS_HAS_UPDATE,
    SUCCESS_NO_UPDATE,
    NETWORK_ERROR,
    PARSE_ERROR,
}

## Compares two version strings (e.g. "1.0.6" vs "1.0.5", "v1.2.0-alpha.1" vs "1.2.0").
## Returns:
##   1 if v1 > v2
##  -1 if v1 < v2
##   0 if v1 == v2
static func compare_versions(v1: String, v2: String) -> int:
    var p1 := _parse_version(v1)
    var p2 := _parse_version(v2)

    var core1: Array = p1.get("core", [])
    var core2: Array = p2.get("core", [])
    var max_len := maxi(core1.size(), core2.size())

    for i in range(max_len):
        var num1: int = core1[i] if i < core1.size() else 0
        var num2: int = core2[i] if i < core2.size() else 0
        if num1 > num2:
            return 1
        elif num1 < num2:
            return -1

    var pre1: String = p1.get("prerelease", "")
    var pre2: String = p2.get("prerelease", "")

    # A version without prerelease has higher precedence than with prerelease
    # (e.g. 1.0.0 > 1.0.0-alpha)
    if pre1.is_empty() and not pre2.is_empty():
        return 1
    elif not pre1.is_empty() and pre2.is_empty():
        return -1
    elif not pre1.is_empty() and not pre2.is_empty():
        return _compare_prereleases(pre1, pre2)

    return 0

static func _compare_prereleases(pre1: String, pre2: String) -> int:
    if pre1 == pre2:
        return 0
    var parts1 := pre1.split(".")
    var parts2 := pre2.split(".")
    var max_len := maxi(parts1.size(), parts2.size())

    for i in range(max_len):
        if i >= parts1.size():
            # Shorter prerelease has lower precedence
            return -1
        if i >= parts2.size():
            return 1

        var p1 := parts1[i]
        var p2 := parts2[i]
        if p1 == p2:
            continue

        var is_p1_num := p1.is_valid_int()
        var is_p2_num := p2.is_valid_int()

        if is_p1_num and is_p2_num:
            var n1 := p1.to_int()
            var n2 := p2.to_int()
            if n1 > n2:
                return 1
            elif n1 < n2:
                return -1
        elif is_p1_num and not is_p2_num:
            # Numeric identifiers have lower precedence than non-numeric
            return -1
        elif not is_p1_num and is_p2_num:
            return 1
        else:
            if p1 > p2:
                return 1
            elif p1 < p2:
                return -1

    return 0

## Returns true if currently running within an Apple Mac App Store build.
## Mac App Store applications have an embedded receipt file at Contents/_MASReceipt/receipt.
static func is_mac_app_store() -> bool:
    if OS.get_environment("AETHERKIRI_SIMULATE_APP_STORE") == "1":
        return true
    if OS.get_name() != "macOS":
        return false
    var exe_path := OS.get_executable_path()
    if exe_path.is_empty():
        return false
    # Executable is typically at <AppBundle>/Contents/MacOS/<Executable>
    var contents_dir := exe_path.get_base_dir().get_base_dir()
    var receipt_path := contents_dir.path_join("_MASReceipt").path_join("receipt")
    return FileAccess.file_exists(receipt_path)

## Returns true if the given version string has a pre-release identifier (e.g. "1.0.7-alpha.1").
static func is_prerelease(v: String) -> bool:
    var parsed := _parse_version(v)
    return not str(parsed.get("prerelease", "")).is_empty()

## Returns true if running an Apple TestFlight (iOS or macOS TestFlight) build.
static func is_apple_testflight(current_version: String) -> bool:
    if OS.get_environment("AETHERKIRI_SIMULATE_TESTFLIGHT") == "1":
        return true
    if not is_prerelease(current_version):
        return false
    if OS.get_name() == "iOS":
        return true
    if OS.get_name() == "macOS" and is_mac_app_store():
        return true
    return false

static func is_ios_testflight(current_version: String) -> bool:
    return is_apple_testflight(current_version)

static func _parse_version(v: String) -> Dictionary:
    var clean := v.strip_edges().trim_prefix("v").trim_prefix("V")
    var prerelease := ""
    var dash_idx := clean.find("-")
    if dash_idx != -1:
        prerelease = clean.substr(dash_idx + 1)
        clean = clean.substr(0, dash_idx)

    var parts := clean.split(".")
    var core: Array[int] = []
    for part in parts:
        core.append(part.to_int())

    return {
        "core": core,
        "prerelease": prerelease,
    }

## Converts common Markdown release notes syntax to Godot BBCode.
static func markdown_to_bbcode(md: String) -> String:
    if md.is_empty():
        return ""

    var lines := md.split("\n")
    var out_lines: PackedStringArray = []
    var in_code_block := false

    for line in lines:
        var raw_line := line.strip_edges(false, true) # strip right trailing spaces

        # Strip HTML comments like <!-- ... -->
        var comment_start := raw_line.find("<!--")
        var comment_end := raw_line.find("-->")
        if comment_start != -1 and comment_end != -1 and comment_end > comment_start:
            raw_line = raw_line.substr(0, comment_start) + raw_line.substr(comment_end + 3)
            raw_line = raw_line.strip_edges()
            if raw_line.is_empty():
                continue

        # Code block fence
        if raw_line.begins_with("```"):
            if in_code_block:
                out_lines.append("[/code]")
                in_code_block = false
            else:
                out_lines.append("[code]")
                in_code_block = true
            continue

        if in_code_block:
            out_lines.append(raw_line)
            continue

        var trimmed := raw_line.strip_edges()

        # Headings: ### Header -> [b]Header[/b]
        if trimmed.begins_with("### "):
            var h := _format_inline_markdown(trimmed.substr(4).strip_edges())
            out_lines.append("[font_size=13][b]%s[/b][/font_size]" % h)
            continue
        elif trimmed.begins_with("## "):
            var h := _format_inline_markdown(trimmed.substr(3).strip_edges())
            out_lines.append("[font_size=14][b]%s[/b][/font_size]" % h)
            continue
        elif trimmed.begins_with("# "):
            var h := _format_inline_markdown(trimmed.substr(2).strip_edges())
            out_lines.append("[font_size=15][b]%s[/b][/font_size]" % h)
            continue

        # List items: * item or - item
        if trimmed.begins_with("* ") or trimmed.begins_with("- "):
            var item_text := _format_inline_markdown(trimmed.substr(2).strip_edges())
            out_lines.append("  • %s" % item_text)
            continue

        # Regular paragraph line
        out_lines.append(_format_inline_markdown(raw_line))

    return "\n".join(out_lines)

static func _format_inline_markdown(text: String) -> String:
    var res := text

    # Regex for links: [text](url) -> [url=url]text[/url]
    var link_regex := RegEx.new()
    link_regex.compile("\\[([^\\]]+)\\]\\(([^\\)]+)\\)")
    res = link_regex.sub(res, "[url=$2]$1[/url]", true)

    # Bold: **text** -> [b]text[/b]
    var bold_regex := RegEx.new()
    bold_regex.compile("\\*\\*([^*]+)\\*\\*")
    res = bold_regex.sub(res, "[b]$1[/b]", true)

    # Inline code: `text` -> [code]$1[/code]
    var code_regex := RegEx.new()
    code_regex.compile("`([^`]+)`")
    res = code_regex.sub(res, "[code]$1[/code]", true)

    # Mentions: @username -> [b]@username[/b]
    var user_regex := RegEx.new()
    user_regex.compile("(^|\\s)@([a-zA-Z0-9_-]+)")
    res = user_regex.sub(res, "$1[b]@$2[/b]", true)

    return res

## Checks for update asynchronously using an HTTPRequest node added to caller's tree.
## callback signature: func(status: int, info: Dictionary)
## info contains:
##   "current_version": String
##   "latest_version": String
##   "tag_name": String
##   "github_url": String
##   "github_apk_url": String
##   "github_macos_url": String
##   "app_store_url": String
##   "is_app_store": bool
##   "is_prerelease": bool
##   "source": String
static func check_for_updates(
    node: Node,
    current_version: String,
    is_app_store: bool,
    include_prerelease: bool,
    callback: Callable
) -> void:
    if not is_instance_valid(node):
        callback.call(CheckStatus.NETWORK_ERROR, {})
        return

    # On Apple platforms, TestFlight / alpha builds do not check App Store because TestFlight manages updates natively
    if is_apple_testflight(current_version):
        callback.call(CheckStatus.SUCCESS_NO_UPDATE, {
            "current_version": current_version,
            "is_testflight": true,
            "is_app_store": true,
            "is_prerelease": true,
            "source": "testflight",
        })
        return

    var req := HTTPRequest.new()
    req.timeout = 10.0
    node.add_child(req)

    if is_app_store:
        _check_app_store(req, current_version, callback)
    else:
        _check_github(req, current_version, include_prerelease, callback)

static func _check_app_store(req: HTTPRequest, current_version: String, callback: Callable) -> void:
    req.request_completed.connect(func(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray):
        req.queue_free()
        if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
            callback.call(CheckStatus.NETWORK_ERROR, {"error_code": response_code})
            return

        var json = JSON.new()
        if json.parse(body.get_string_from_utf8()) != OK:
            callback.call(CheckStatus.PARSE_ERROR, {})
            return

        var data = json.get_data()
        if not (data is Dictionary) or not data.has("results") or not (data["results"] is Array):
            callback.call(CheckStatus.PARSE_ERROR, {})
            return
        if data["results"].is_empty():
            callback.call(CheckStatus.SUCCESS_NO_UPDATE, {})
            return
        if not (data["results"][0] is Dictionary):
            callback.call(CheckStatus.PARSE_ERROR, {})
            return

        var app_info: Dictionary = data["results"][0]
        var store_version: String = str(app_info.get("version", ""))
        var release_notes: String = str(app_info.get("releaseNotes", ""))
        var track_view_url: String = str(app_info.get("trackViewUrl", APPLE_STORE_URL))

        var info := {
            "current_version": current_version,
            "latest_version": store_version,
            "release_notes": release_notes,
            "app_store_url": track_view_url,
            "is_app_store": true,
            "is_prerelease": false,
            "source": "app_store",
        }

        if compare_versions(store_version, current_version) > 0:
            callback.call(CheckStatus.SUCCESS_HAS_UPDATE, info)
        else:
            callback.call(CheckStatus.SUCCESS_NO_UPDATE, info)
    )

    var headers := PackedStringArray(["User-Agent: AetherKiri-Updater"])
    var err := req.request(APPLE_LOOKUP_URL, headers)
    if err != OK:
        req.queue_free()
        callback.call(CheckStatus.NETWORK_ERROR, {"error": err})

static func _check_github(
    req: HTTPRequest,
    current_version: String,
    include_prerelease: bool,
    callback: Callable
) -> void:
    req.request_completed.connect(func(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray):
        req.queue_free()
        if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
            callback.call(CheckStatus.NETWORK_ERROR, {"error_code": response_code})
            return

        var json = JSON.new()
        if json.parse(body.get_string_from_utf8()) != OK:
            callback.call(CheckStatus.PARSE_ERROR, {})
            return

        var data = json.get_data()
        var target_release: Dictionary = {}
        if data is Array and not data.is_empty():
            target_release = _pick_release(data, include_prerelease)
        elif data is Dictionary and data.has("tag_name"):
            var is_pre := bool(data.get("prerelease", false))
            if include_prerelease or not is_pre:
                target_release = data

        if target_release.is_empty():
            callback.call(CheckStatus.SUCCESS_NO_UPDATE, {})
            return

        _finish_with_release_data(target_release, current_version, "github", callback)
    )

    var headers := PackedStringArray(["User-Agent: AetherKiri-Updater"])
    var err := req.request(GITHUB_RELEASES_URL, headers)
    if err != OK:
        req.queue_free()
        callback.call(CheckStatus.NETWORK_ERROR, {"error": err})

static func _pick_release(releases: Array, include_prerelease: bool) -> Dictionary:
    for item in releases:
        if not (item is Dictionary):
            continue
        var is_pre: bool = bool(item.get("prerelease", false))
        if not include_prerelease and is_pre:
            continue
        return item
    return {}

static func _finish_with_release_data(
    release_data: Dictionary,
    current_version: String,
    source: String,
    callback: Callable
) -> void:
    var tag_name: String = str(release_data.get("tag_name", "")).strip_edges()
    var latest_ver := tag_name.trim_prefix("v").trim_prefix("V")
    var body_notes: String = str(release_data.get("body", ""))
    var is_pre := bool(release_data.get("prerelease", false))

    var github_url := ""
    var github_apk_url := ""
    var github_macos_url := ""

    var expected_apk_name_1 := "Aether-%s-android.apk" % latest_ver
    var expected_apk_name_2 := "AetherKiri-%s-android.apk" % latest_ver
    var expected_macos_name_1 := "Aether-%s-macos.zip" % latest_ver
    var expected_macos_name_2 := "AetherKiri-%s-macos.zip" % latest_ver

    # Parse assets to find direct APK and macOS zip links if available
    var assets: Array = release_data.get("assets", []) if (release_data.get("assets") is Array) else []
    for asset in assets:
        if asset is Dictionary:
            var aname: String = str(asset.get("name", ""))
            var dl_url: String = str(asset.get("browser_download_url", ""))
            if aname == expected_apk_name_1 or aname == expected_apk_name_2 or aname.ends_with("-android.apk") or aname.ends_with(".apk"):
                github_apk_url = dl_url
            elif aname == expected_macos_name_1 or aname == expected_macos_name_2 or ((aname.ends_with("-macos.zip") or aname.ends_with(".dmg")) and not aname.contains("app-store")):
                github_macos_url = dl_url

    # Construct direct download URLs if not explicitly found in assets list
    if github_apk_url.is_empty():
        github_apk_url = "%s/download/%s/%s" % [GITHUB_REPO_RELEASES_PAGE, tag_name, expected_apk_name_1]

    if github_macos_url.is_empty():
        github_macos_url = "%s/download/%s/%s" % [GITHUB_REPO_RELEASES_PAGE, tag_name, expected_macos_name_1]

    var html_url: String = str(release_data.get("html_url", ""))
    github_url = html_url if not html_url.is_empty() else (GITHUB_REPO_RELEASES_PAGE + "/tag/" + tag_name)

    var info := {
        "current_version": current_version,
        "latest_version": latest_ver,
        "tag_name": tag_name,
        "release_notes": body_notes,
        "github_url": github_url,
        "github_apk_url": github_apk_url,
        "github_macos_url": github_macos_url,
        "is_app_store": false,
        "is_prerelease": is_pre,
        "source": source,
    }

    if compare_versions(latest_ver, current_version) > 0:
        callback.call(CheckStatus.SUCCESS_HAS_UPDATE, info)
    else:
        callback.call(CheckStatus.SUCCESS_NO_UPDATE, info)
