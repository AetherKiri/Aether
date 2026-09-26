extends RefCounted

# Aurora design language: layered frosted glass floating over a slowly
# drifting gradient field. Every palette defines a solid base, translucent
# glass tiers, a two-stop accent gradient and three aurora blob colours that
# the ambient backdrop animates.

const DARK := "dark"
const LIGHT := "classic"
const WARM_DARK := "warm_dark"
const WARM_LIGHT := "warm_light"

const RADIUS_SMALL := 10
const RADIUS_MEDIUM := 14
const RADIUS_CARD := 22
const RADIUS_LARGE := 28
const RADIUS_PILL := 999
const SIDEBAR_WIDTH := 244.0
const SIDEBAR_INSET := 14.0
const CONTENT_MAX_WIDTH := 1180.0
const PAGE_GUTTER := 36.0
const PAGE_GUTTER_COMPACT := 20.0
const CONTROL_HEIGHT := 48.0
const TOOLBAR_HEIGHT := 72.0

var mode := DARK
var background := Color("07080e")
var background_raised := Color("0e1018")
var sidebar_material := Color(0.07, 0.08, 0.12, 0.62)
var glass_material := Color(0.11, 0.12, 0.18, 0.58)
var popover := Color(0.09, 0.10, 0.15, 0.97)
var surface := Color(0.10, 0.11, 0.16, 0.72)
var surface_raised := Color(0.14, 0.15, 0.22, 0.78)
var surface_hover := Color(0.19, 0.20, 0.29, 0.85)
var text_primary := Color("f5f6fb")
var text_secondary := Color("a7adc2")
var text_tertiary := Color("6e7590")
var text_on_accent := Color.WHITE
var accent := Color("8b5cf6")
var accent_2 := Color("22d3ee")
var accent_3 := Color("f472b6")
var accent_fill := Color(0.545, 0.361, 0.965, 0.20)
var success := Color("34d399")
var warning := Color("fbbf24")
var danger := Color("f87171")
var separator := Color(1.0, 1.0, 1.0, 0.08)
var rim := Color(1.0, 1.0, 1.0, 0.14)
var shadow := Color(0.0, 0.0, 0.0, 0.45)
var scrim := Color(0.02, 0.02, 0.05, 0.55)
var aurora_a := Color(0.43, 0.16, 0.85, 0.55)
var aurora_b := Color(0.03, 0.57, 0.70, 0.45)
var aurora_c := Color(0.86, 0.15, 0.47, 0.30)

func configure(next_mode: String) -> void:
    mode = next_mode
    if mode == WARM_DARK:
        background = Color("0d0a09")
        background_raised = Color("17120f")
        sidebar_material = Color(0.10, 0.08, 0.07, 0.64)
        glass_material = Color(0.15, 0.12, 0.10, 0.60)
        popover = Color(0.12, 0.10, 0.08, 0.97)
        surface = Color(0.14, 0.11, 0.09, 0.72)
        surface_raised = Color(0.19, 0.15, 0.12, 0.80)
        surface_hover = Color(0.25, 0.20, 0.16, 0.88)
        text_primary = Color("fbf7f2")
        text_secondary = Color("b8ab9f")
        text_tertiary = Color("7c7169")
        accent = Color("fb7c4b")
        accent_2 = Color("fbbf24")
        accent_3 = Color("f43f5e")
        success = Color("4ade80")
        warning = Color("fbbf24")
        danger = Color("f87171")
        separator = Color(1.0, 0.95, 0.9, 0.08)
        rim = Color(1.0, 0.92, 0.85, 0.14)
        shadow = Color(0.0, 0.0, 0.0, 0.50)
        scrim = Color(0.04, 0.02, 0.01, 0.56)
        aurora_a = Color(0.76, 0.25, 0.05, 0.45)
        aurora_b = Color(0.71, 0.33, 0.04, 0.34)
        aurora_c = Color(0.62, 0.07, 0.22, 0.30)
    elif mode == WARM_LIGHT:
        background = Color("f6f1ea")
        background_raised = Color("fffdf9")
        sidebar_material = Color(1.0, 0.99, 0.97, 0.64)
        glass_material = Color(1.0, 0.99, 0.97, 0.62)
        popover = Color(1.0, 0.99, 0.97, 0.98)
        surface = Color(1.0, 0.99, 0.97, 0.70)
        surface_raised = Color(1.0, 0.99, 0.97, 0.88)
        surface_hover = Color(0.99, 0.95, 0.90, 0.96)
        text_primary = Color("1c1612")
        text_secondary = Color("6f6258")
        text_tertiary = Color("a2958a")
        accent = Color("e4683a")
        accent_2 = Color("f59e0b")
        accent_3 = Color("db2777")
        success = Color("16a34a")
        warning = Color("d97706")
        danger = Color("dc2626")
        separator = Color(0.35, 0.22, 0.12, 0.10)
        rim = Color(1.0, 1.0, 1.0, 0.85)
        shadow = Color(0.45, 0.25, 0.10, 0.16)
        scrim = Color(0.24, 0.16, 0.10, 0.26)
        aurora_a = Color(0.99, 0.73, 0.45, 0.55)
        aurora_b = Color(0.99, 0.83, 0.30, 0.40)
        aurora_c = Color(0.98, 0.66, 0.83, 0.35)
    elif mode == LIGHT:
        background = Color("eef0f7")
        background_raised = Color("ffffff")
        sidebar_material = Color(1.0, 1.0, 1.0, 0.62)
        glass_material = Color(1.0, 1.0, 1.0, 0.60)
        popover = Color(1.0, 1.0, 1.0, 0.98)
        surface = Color(1.0, 1.0, 1.0, 0.70)
        surface_raised = Color(1.0, 1.0, 1.0, 0.86)
        surface_hover = Color(0.93, 0.94, 0.99, 0.95)
        text_primary = Color("0f1222")
        text_secondary = Color("5a607a")
        text_tertiary = Color("8d93ab")
        accent = Color("6366f1")
        accent_2 = Color("06b6d4")
        accent_3 = Color("ec4899")
        success = Color("16a34a")
        warning = Color("d97706")
        danger = Color("e11d48")
        separator = Color(0.06, 0.08, 0.20, 0.08)
        rim = Color(1.0, 1.0, 1.0, 0.85)
        shadow = Color(0.16, 0.18, 0.38, 0.14)
        scrim = Color(0.10, 0.12, 0.25, 0.22)
        aurora_a = Color(0.65, 0.71, 0.99, 0.60)
        aurora_b = Color(0.40, 0.91, 0.98, 0.45)
        aurora_c = Color(0.98, 0.66, 0.83, 0.40)
    else:
        mode = DARK
        background = Color("07080e")
        background_raised = Color("0e1018")
        sidebar_material = Color(0.07, 0.08, 0.12, 0.62)
        glass_material = Color(0.11, 0.12, 0.18, 0.58)
        popover = Color(0.09, 0.10, 0.15, 0.97)
        surface = Color(0.10, 0.11, 0.16, 0.72)
        surface_raised = Color(0.14, 0.15, 0.22, 0.78)
        surface_hover = Color(0.19, 0.20, 0.29, 0.85)
        text_primary = Color("f5f6fb")
        text_secondary = Color("a7adc2")
        text_tertiary = Color("6e7590")
        accent = Color("8b5cf6")
        accent_2 = Color("22d3ee")
        accent_3 = Color("f472b6")
        success = Color("34d399")
        warning = Color("fbbf24")
        danger = Color("f87171")
        separator = Color(1.0, 1.0, 1.0, 0.08)
        rim = Color(1.0, 1.0, 1.0, 0.14)
        shadow = Color(0.0, 0.0, 0.0, 0.45)
        scrim = Color(0.02, 0.02, 0.05, 0.55)
        aurora_a = Color(0.43, 0.16, 0.85, 0.55)
        aurora_b = Color(0.03, 0.57, 0.70, 0.45)
        aurora_c = Color(0.86, 0.15, 0.47, 0.30)
    accent_fill = Color(accent.r, accent.g, accent.b, 0.20 if is_dark() else 0.13)

func is_dark() -> bool:
    return mode == DARK or mode == WARM_DARK

func accent_mix(weight: float) -> Color:
    return accent.lerp(accent_2, clampf(weight, 0.0, 1.0))

func tint(color: Color, alpha: float) -> Color:
    return Color(color.r, color.g, color.b, alpha)

func panel(fill: Color, radius: int = RADIUS_MEDIUM, border: Color = Color.TRANSPARENT, border_width: int = 0) -> StyleBoxFlat:
    var style := StyleBoxFlat.new()
    style.bg_color = fill
    style.border_color = border
    style.border_width_left = border_width
    style.border_width_top = border_width
    style.border_width_right = border_width
    style.border_width_bottom = border_width
    style.corner_radius_top_left = radius
    style.corner_radius_top_right = radius
    style.corner_radius_bottom_left = radius
    style.corner_radius_bottom_right = radius
    style.anti_aliasing = true
    style.anti_aliasing_size = 0.8
    style.corner_detail = 12
    return style

# Frosted glass: translucent fill, a light rim that catches the aurora and a
# soft drop shadow when the surface floats above the page.
func glass_panel(radius: int = RADIUS_CARD, elevated: bool = false, fill: Color = Color.TRANSPARENT) -> StyleBoxFlat:
    var style := panel(glass_material if fill.a <= 0.0 else fill, radius, rim, 1)
    if elevated:
        style.shadow_color = shadow
        style.shadow_size = 26 if is_dark() else 22
        style.shadow_offset = Vector2(0, 12)
    return style

func material_panel(elevated: bool = false) -> StyleBoxFlat:
    var style := panel(glass_material if not elevated else popover, RADIUS_CARD)
    style.content_margin_left = 18
    style.content_margin_top = 16
    style.content_margin_right = 18
    style.content_margin_bottom = 16
    if elevated:
        style.shadow_color = shadow
        style.shadow_size = 28
        style.shadow_offset = Vector2(0, 14)
    return style

# Library card base. The glass rim, cover-colour bleed and glow are drawn by
# dedicated layers inside the card, so the stylebox stays a clean fill.
func card_style(hovered: bool = false, pressed: bool = false) -> StyleBoxFlat:
    var fill := Color.TRANSPARENT
    if pressed:
        fill = tint(accent, 0.10)
    elif hovered:
        fill = tint(text_primary, 0.025)
    return panel(fill, RADIUS_CARD)

func detail_outline_style() -> StyleBoxFlat:
    return panel(surface_raised, RADIUS_CARD, separator, 1)

func sidebar_panel() -> StyleBoxFlat:
    var style := panel(Color.TRANSPARENT, 0)
    style.content_margin_left = 16
    style.content_margin_top = 18
    style.content_margin_right = 16
    style.content_margin_bottom = 18
    return style

func button_style(fill: Color, border: Color = Color.TRANSPARENT, radius: int = RADIUS_MEDIUM) -> StyleBoxFlat:
    var style := panel(fill, radius, border, 1 if border.a > 0.0 else 0)
    style.content_margin_left = 16
    style.content_margin_top = 10
    style.content_margin_right = 16
    style.content_margin_bottom = 10
    return style

func focus_style(radius: int = RADIUS_MEDIUM) -> StyleBoxFlat:
    return panel(tint(accent, 0.10), radius)

# Two-stop gradient used by glows, rules and progress fills.
func gradient_texture(from: Color, to: Color, vertical: bool = false, length: int = 256) -> GradientTexture2D:
    var gradient := Gradient.new()
    gradient.colors = PackedColorArray([from, to])
    var texture := GradientTexture2D.new()
    texture.gradient = gradient
    texture.width = length if not vertical else 4
    texture.height = 4 if not vertical else length
    texture.fill_from = Vector2(0, 0)
    texture.fill_to = Vector2(0, 1) if vertical else Vector2(1, 0)
    return texture

func radial_glow_texture(color: Color, size: int = 128) -> GradientTexture2D:
    var gradient := Gradient.new()
    gradient.offsets = PackedFloat32Array([0.0, 0.45, 1.0])
    gradient.colors = PackedColorArray([
        color,
        Color(color.r, color.g, color.b, color.a * 0.35),
        Color(color.r, color.g, color.b, 0.0),
    ])
    var texture := GradientTexture2D.new()
    texture.gradient = gradient
    texture.width = size
    texture.height = size
    texture.fill = GradientTexture2D.FILL_RADIAL
    texture.fill_from = Vector2(0.5, 0.5)
    texture.fill_to = Vector2(1.0, 0.5)
    return texture
