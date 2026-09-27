extends RefCounted

# Lumen design language: solid ink-and-paper surfaces separated by hairlines,
# one saturated signal colour per palette and soft layered shadows for
# elevation. Decoration comes from motion and the living dot-field backdrop,
# never from translucent glass or gradients.

const DARK := "dark"
const LIGHT := "classic"
const WARM_DARK := "warm_dark"
const WARM_LIGHT := "warm_light"

const RADIUS_SMALL := 8
const RADIUS_MEDIUM := 12
const RADIUS_CARD := 16
const RADIUS_LARGE := 22
const RADIUS_PILL := 999
const TOPBAR_HEIGHT := 72.0
const COMPACT_HEADER_HEIGHT := 56.0
const DOCK_HEIGHT := 76.0
const CONTENT_MAX_WIDTH := 1240.0
const PAGE_GUTTER := 40.0
const PAGE_GUTTER_COMPACT := 18.0
const CONTROL_HEIGHT := 44.0

var mode := DARK
var background := Color("0c0d10")
var background_raised := Color("121418")
var surface := Color("15171c")
var surface_raised := Color("1b1e24")
var surface_hover := Color("23272f")
var popover := Color("1a1d23")
var text_primary := Color("f3f4f6")
var text_secondary := Color("a0a5b0")
var text_tertiary := Color("666c78")
var text_on_accent := Color("16110f")
var accent := Color("ff6a3d")
var accent_2 := Color("ffb23e")
var accent_3 := Color("ff3d7f")
var accent_fill := Color(1.0, 0.416, 0.239, 0.14)
var accent_text := Color("ff8a66")
var success := Color("3ddc97")
var warning := Color("ffc145")
var danger := Color("ff5c5c")
var separator := Color(1.0, 1.0, 1.0, 0.07)
var outline := Color(1.0, 1.0, 1.0, 0.10)
var outline_strong := Color(1.0, 1.0, 1.0, 0.20)
var shadow := Color(0.0, 0.0, 0.0, 0.50)
var scrim := Color(0.02, 0.02, 0.03, 0.62)
var dot := Color(1.0, 1.0, 1.0, 0.055)

func configure(next_mode: String) -> void:
    mode = next_mode
    match mode:
        WARM_DARK:
            background = Color("110d0a")
            background_raised = Color("17120e")
            surface = Color("1b1510")
            surface_raised = Color("231b15")
            surface_hover = Color("2d231b")
            popover = Color("211a14")
            text_primary = Color("f7efe6")
            text_secondary = Color("b4a595")
            text_tertiary = Color("7a6c60")
            text_on_accent = Color("1a1108")
            accent = Color("e9a23b")
            accent_2 = Color("f26b38")
            accent_3 = Color("c2410c")
            accent_text = Color("f0b862")
            success = Color("6fcf7c")
            warning = Color("f4c04e")
            danger = Color("f06a5a")
            separator = Color(1.0, 0.92, 0.84, 0.07)
            outline = Color(1.0, 0.92, 0.84, 0.10)
            outline_strong = Color(1.0, 0.92, 0.84, 0.20)
            shadow = Color(0.0, 0.0, 0.0, 0.55)
            scrim = Color(0.04, 0.02, 0.01, 0.64)
            dot = Color(1.0, 0.9, 0.78, 0.06)
        WARM_LIGHT:
            background = Color("f8f2e9")
            background_raised = Color("fdf9f3")
            surface = Color("fffcf7")
            surface_raised = Color("ffffff")
            surface_hover = Color("f3ebdf")
            popover = Color("fffdf9")
            text_primary = Color("201812")
            text_secondary = Color("6d5f53")
            text_tertiary = Color("a39485")
            text_on_accent = Color("fffaf4")
            accent = Color("c8553d")
            accent_2 = Color("e9a23b")
            accent_3 = Color("8c5e3c")
            accent_text = Color("b34a33")
            success = Color("2f8f4e")
            warning = Color("c07a12")
            danger = Color("c9352b")
            separator = Color(0.32, 0.20, 0.10, 0.10)
            outline = Color(0.32, 0.20, 0.10, 0.14)
            outline_strong = Color(0.32, 0.20, 0.10, 0.28)
            shadow = Color(0.35, 0.20, 0.08, 0.14)
            scrim = Color(0.20, 0.13, 0.08, 0.40)
            dot = Color(0.32, 0.20, 0.10, 0.10)
        LIGHT:
            background = Color("f4f3ef")
            background_raised = Color("f9f8f5")
            surface = Color("ffffff")
            surface_raised = Color("ffffff")
            surface_hover = Color("efede7")
            popover = Color("ffffff")
            text_primary = Color("16161a")
            text_secondary = Color("5d5d66")
            text_tertiary = Color("9a9aa3")
            text_on_accent = Color("ffffff")
            accent = Color("2f4bff")
            accent_2 = Color("00a6a6")
            accent_3 = Color("ff5a5f")
            accent_text = Color("2640e6")
            success = Color("1f9d55")
            warning = Color("c27c0e")
            danger = Color("e03131")
            separator = Color(0.08, 0.08, 0.12, 0.08)
            outline = Color(0.08, 0.08, 0.12, 0.12)
            outline_strong = Color(0.08, 0.08, 0.12, 0.24)
            shadow = Color(0.10, 0.10, 0.20, 0.12)
            scrim = Color(0.08, 0.08, 0.12, 0.40)
            dot = Color(0.08, 0.08, 0.12, 0.10)
        _:
            mode = DARK
            background = Color("0c0d10")
            background_raised = Color("121418")
            surface = Color("15171c")
            surface_raised = Color("1b1e24")
            surface_hover = Color("23272f")
            popover = Color("1a1d23")
            text_primary = Color("f3f4f6")
            text_secondary = Color("a0a5b0")
            text_tertiary = Color("666c78")
            text_on_accent = Color("16110f")
            accent = Color("ff6a3d")
            accent_2 = Color("ffb23e")
            accent_3 = Color("ff3d7f")
            accent_text = Color("ff8a66")
            success = Color("3ddc97")
            warning = Color("ffc145")
            danger = Color("ff5c5c")
            separator = Color(1.0, 1.0, 1.0, 0.07)
            outline = Color(1.0, 1.0, 1.0, 0.10)
            outline_strong = Color(1.0, 1.0, 1.0, 0.20)
            shadow = Color(0.0, 0.0, 0.0, 0.50)
            scrim = Color(0.02, 0.02, 0.03, 0.62)
            dot = Color(1.0, 1.0, 1.0, 0.055)
    accent_fill = Color(accent.r, accent.g, accent.b, 0.16 if is_dark() else 0.10)

func is_dark() -> bool:
    return mode == DARK or mode == WARM_DARK

func tint(color: Color, alpha: float) -> Color:
    return Color(color.r, color.g, color.b, alpha)

func panel(fill: Color, radius: int = RADIUS_MEDIUM, border: Color = Color.TRANSPARENT, border_width: int = 0) -> StyleBoxFlat:
    var style := StyleBoxFlat.new()
    style.bg_color = fill
    style.border_color = border
    style.set_border_width_all(border_width)
    style.set_corner_radius_all(radius)
    style.anti_aliasing = true
    style.anti_aliasing_size = 0.8
    style.corner_detail = 12
    return style

# Solid raised surface. `level` 0 is flush with the page, 1 floats (cards,
# bars) and 2 hovers above everything (popovers, dialogs).
func raised(radius: int = RADIUS_CARD, level: int = 1, fill: Color = Color.TRANSPARENT) -> StyleBoxFlat:
    var style := panel(surface if fill.a <= 0.0 else fill, radius, outline, 1)
    return elevate(style, level)

func elevate(style: StyleBoxFlat, level: int) -> StyleBoxFlat:
    if level <= 0:
        style.shadow_size = 0
        return style
    style.shadow_color = tint(shadow, shadow.a * (0.7 if level == 1 else 1.0))
    style.shadow_size = 14 if level == 1 else 30
    style.shadow_offset = Vector2(0, 6 if level == 1 else 16)
    return style

func material_panel(elevated: bool = false) -> StyleBoxFlat:
    var style := panel(surface if not elevated else popover, RADIUS_CARD)
    style.content_margin_left = 18
    style.content_margin_top = 16
    style.content_margin_right = 18
    style.content_margin_bottom = 16
    if elevated:
        elevate(style, 2)
    return style

# Library cards carry no chrome of their own: the poster and its shadow are
# the card. Hover/press read through motion and the title colour.
func card_style(hovered: bool = false, pressed: bool = false) -> StyleBoxFlat:
    var fill := Color.TRANSPARENT
    if pressed:
        fill = tint(text_primary, 0.06)
    elif hovered:
        fill = tint(text_primary, 0.03)
    return panel(fill, RADIUS_CARD)

func detail_outline_style() -> StyleBoxFlat:
    return panel(surface_raised, RADIUS_CARD, separator, 1)

func button_style(fill: Color, border: Color = Color.TRANSPARENT, radius: int = RADIUS_MEDIUM) -> StyleBoxFlat:
    var style := panel(fill, radius, border, 1 if border.a > 0.0 else 0)
    style.content_margin_left = 18
    style.content_margin_top = 10
    style.content_margin_right = 18
    style.content_margin_bottom = 10
    return style

# Keyboard focus is a quiet tinted wash; outlines are reserved for fields.
func focus_style(radius: int = RADIUS_MEDIUM) -> StyleBoxFlat:
    var style := panel(tint(accent, 0.10), radius)
    style.draw_center = true
    return style

func linear_texture(from: Color, to: Color, vertical: bool = false, length: int = 256) -> GradientTexture2D:
    var gradient := Gradient.new()
    gradient.colors = PackedColorArray([from, to])
    var texture := GradientTexture2D.new()
    texture.gradient = gradient
    texture.width = 4 if vertical else length
    texture.height = length if vertical else 4
    texture.fill_from = Vector2(0, 0)
    texture.fill_to = Vector2(0, 1) if vertical else Vector2(1, 0)
    return texture
