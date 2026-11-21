extends RefCounted
## Shared by the Astryx editor and the in-game overlay. Positions are centers
## in the safe area. Unmoved Mouse controls retain their responsive edge anchors.

const CATALOG := preload("res://config/virtual_button_catalog.json")
const CONFIG := preload("res://scripts/game_render_config.gd")
const GLOBAL_PATH := "user://virtual_button_layouts.json"
const MOUSE_ICONS := {
    "mouse_left": preload("res://assets/ui/virtual_controls/mouse_left.svg"),
    "mouse_right": preload("res://assets/ui/virtual_controls/mouse_right.svg"),
}
const GAME_FIELD := "virtual_buttons"
const MAX_PROFILES := 32
const MAX_BUTTONS := 64
const MIN_SCALE := 0.65
const MAX_SCALE := 2.4
const SPECIAL := ["mouse_left", "mouse_right", "wheel_up", "wheel_down"]
const GLYPHS := {"wheel_up": "▲", "wheel_down": "▼", "Up": "↑", "Left": "←", "Down": "↓", "Right": "→"}


static func actions() -> Array:
    var values: Array = CATALOG.data.key_codes.keys()
    for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789":
        values.append(c)
    for i in range(1, 13):
        values.append("F%d" % i)
    return values + SPECIAL


static func key_code(action: String) -> int:
    if action.length() == 1:
        return action.unicode_at(0)
    if action.begins_with("F") and action.substr(1).is_valid_int():
        return 0x6F + int(action.substr(1))
    return int(CATALOG.data.key_codes.get(action, 0))


static func key_name(code: int) -> String:
    if code >= 0x70 and code <= 0x7B:
        return "F%d" % (code - 0x6F)
    var named = CATALOG.data.key_codes.find_key(float(code))
    return String(named) if named != null else String.chr(code)


static func mouse() -> Dictionary:
    var buttons := []
    for id in CATALOG.data.mouse_buttons:
        buttons.append({"id": id, "action": id})
    return {"id": "mouse", "name": "Mouse", "pad_mode": "wasd", "buttons": buttons}


static func empty_book(game: bool) -> Dictionary:
    return {"active": "" if game else "mouse", "profiles": []}


static func profile_in(book: Dictionary, id: String) -> Dictionary:
    for profile in book.get("profiles", []):
        if profile.id == id:
            return profile
    return {}


static func effective(book: Dictionary, global_book: Dictionary = {}) -> Dictionary:
    var id: String = book.active
    if id == "mouse":
        return mouse()
    var profile := profile_in(book, id)
    if not profile.is_empty():
        return profile
    if not global_book.is_empty():
        profile = profile_in(global_book, id)
        return profile if not profile.is_empty() else effective(global_book)
    return mouse()


static func new_id(prefix: String) -> String:
    return prefix + Crypto.new().generate_random_bytes(12).hex_encode()


static func copy_profile(book: Dictionary, source: Dictionary, game: bool, name_format: String) -> Dictionary:
    if book.profiles.size() >= MAX_PROFILES:
        return {}
    var copy := source.duplicate(true)
    copy.id = new_id("g-" if game else "p-")
    var names := []
    for profile in book.profiles:
        names.append(profile.name)
    var n: int = names.size() + 1
    while (name_format % n) in names:
        n += 1
    copy.name = name_format % n
    book.profiles.append(copy)
    book.active = copy.id
    return copy


static func _number_between(value, lo: float, hi: float) -> bool:
    return (value is float or value is int) and is_finite(value) and value >= lo and value <= hi


static func valid_book(value, game: bool) -> bool:
    if (
        not value is Dictionary
        or not value.get("active") is String
        or not value.get("profiles") is Array
        or value.profiles.size() > MAX_PROFILES
    ):
        return false
    var allowed := actions()
    var ids := {}
    for p in value.profiles:
        if not p is Dictionary or not p.get("id") is String or not p.id.begins_with("g-" if game else "p-") or ids.has(p.id):
            return false
        if (
            not p.get("name") is String
            or p.name.strip_edges().is_empty()
            or p.name.length() > 48
            or p.get("pad_mode") not in ["wasd", "arrows"]
        ):
            return false
        if p.has("opacity") and not _number_between(p.opacity, 0.2, 1):
            return false
        if not p.get("buttons") is Array or p.buttons.size() > MAX_BUTTONS:
            return false
        ids[p.id] = true
        var caps := {}
        for b in p.buttons:
            if not b is Dictionary or not b.get("id") is String or b.id.is_empty() or caps.has(b.id):
                return false
            if b.id == "pad":
                if b.get("action") != "pad":
                    return false
            elif not b.get("action") in allowed:
                return false
            if (
                b.has("x") != b.has("y")
                or (b.has("x") and (not _number_between(b.x, 0, 1) or not _number_between(b.y, 0, 1)))
            ):
                return false
            if b.has("scale") and not _number_between(b.scale, MIN_SCALE, MAX_SCALE):
                return false
            caps[b.id] = true
        if not caps.has("pad"):
            return false
    return (
        value.active == "mouse" or ids.has(value.active) or (game and (value.active == "" or value.active.begins_with("p-")))
    )


static func _loaded(value, game: bool, error: Error = OK) -> Dictionary:
    # Early editor previews stored the direction-mode handle as a gameplay key.
    if value is Dictionary and value.get("profiles") is Array:
        for p in value.profiles:
            if p is Dictionary and p.get("buttons") is Array:
                p.buttons = p.buttons.filter(func(b): return not (b is Dictionary and b.get("action") == "direction_mode"))
    if error == OK and not valid_book(value, game):
        error = ERR_INVALID_DATA
    return {"book": value if error == OK else empty_book(game), "error": error}


static func load_global(path: String = GLOBAL_PATH) -> Dictionary:
    var blank := empty_book(false)
    if not FileAccess.file_exists(path):
        return _loaded(blank, false)
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null:
        return _loaded(blank, false, FileAccess.get_open_error())
    if file.get_length() > 1024 * 1024:
        return _loaded(blank, false, ERR_INVALID_DATA)
    return _loaded(JSON.parse_string(file.get_as_text()), false)


static func save_global(book: Dictionary, path: String = GLOBAL_PATH) -> Error:
    if not valid_book(book, false):
        return ERR_INVALID_DATA
    return CONFIG.write_document(path, book)


static func load_game(root: String) -> Dictionary:
    var loaded := CONFIG.read(root)
    return _loaded(loaded.document.get(GAME_FIELD, empty_book(true)), true, loaded.error)


static func save_game(root: String, book: Dictionary) -> Error:
    if root.is_empty() or not DirAccess.dir_exists_absolute(root):
        return ERR_FILE_BAD_PATH
    if not valid_book(book, true):
        return ERR_INVALID_DATA
    var loaded := CONFIG.read(root)
    if loaded.error != OK:
        return loaded.error
    if book.active.is_empty() and book.profiles.is_empty():
        if not loaded.document.erase(GAME_FIELD):
            return OK
    else:
        loaded.document[GAME_FIELD] = book
    return CONFIG.write_document(loaded.path, loaded.document)


static func mouse_geometry(area: Vector2) -> Dictionary:
    var edge := minf(area.x, area.y)
    var d := clampf(edge * 0.13, 44, 68)
    var gap := clampf(d * 0.13, 6, 9)
    var m := clampf(d * 0.2, 9, 14)
    var pad := clampf(edge * 0.36, 118, 210)
    var a := d * 1.12
    var bottom := area.y - m - d
    var digit_x := area.x - 44 - d - gap
    var left := digit_x - 2 * (a + gap)
    var scroll := clampf((area.y - 2 * d - gap) * 0.46, m + d + gap, maxf(m + d + gap, area.y - m - pad - 2 * (d + gap)))
    var compact := area.x < 1.25 * area.y
    var right := area.x - m - a if compact else left + a + gap
    var near := right - a - gap
    var ctrl_x := m + pad + gap
    var key := Vector2.ONE * d
    var action := Vector2.ONE * a
    var result := {
        "pad": Rect2(Vector2(m, area.y - m - pad), Vector2.ONE * pad),
        "Esc": Rect2(Vector2(m, m), key),
        "wheel_up": Rect2(Vector2(m, scroll), key),
        "wheel_down": Rect2(Vector2(m, scroll + d + gap), key),
        "Ctrl": Rect2(Vector2(m if compact else ctrl_x, area.y - m - pad - gap - d if compact else bottom), key),
        "mouse_left": Rect2(Vector2(near, bottom - a - gap), action),
        "mouse_right": Rect2(Vector2(right, bottom - a - gap), action),
        "Space": Rect2(Vector2(near, bottom), action),
        "Enter": Rect2(Vector2(right, bottom), action),
    }
    for i in 4:
        result[str(i + 1)] = Rect2(Vector2(digit_x, m + d * 0.24 + i * (d + gap)), key)
    return result


static func button_rect(cap: Dictionary, area: Vector2, homes: Dictionary) -> Rect2:
    var home: Rect2 = homes.get(cap.id, Rect2())
    var center := home.get_center() if home.has_area() else area * 0.5
    var diameter := home.size.x if home.has_area() else clampf(minf(area.x, area.y) * 0.13, 44, 68)
    if cap.has("x"):
        center = Vector2(cap.x, cap.y) * area
    diameter = minf(minf(area.x, area.y), diameter * float(cap.get("scale", 1.0)))
    var half := Vector2.ONE * diameter * 0.5
    return Rect2(center.clamp(half, area - half) - half, 2 * half)
