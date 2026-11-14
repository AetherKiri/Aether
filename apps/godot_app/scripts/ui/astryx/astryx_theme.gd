extends RefCounted
## Native Godot counterpart of the Astryx Neutral tokens used by the web preview.

const TOKENS := preload("res://assets/ui/astryx/tokens.gd")
const REGULAR := preload("res://assets/fonts/Figtree-Regular.ttf")
const SEMIBOLD := preload("res://assets/fonts/Figtree-Semibold.ttf")
const CJK := preload("res://assets/fonts/aetherkiri-runtime-cjk.otf")
const SYMBOLS := preload("res://assets/fonts/aetherkiri-runtime-symbols.ttf")
var tokens: Dictionary
var colors: Dictionary
var mode: String
var font: Font
var bold: Font
var native: Theme

func _init(value: String = "light") -> void:
    tokens = TOKENS.VALUES
    mode = value if value in ["light", "dark"] else "light"
    colors = tokens[mode]
    # Library titles are arbitrary text; the small UI subset cannot cover them.
    # Keep our fallback resources separate from the classic shell's font setup.
    var cjk := CJK.duplicate()
    cjk.fallbacks = []
    # Explicit sampling keeps 14 pt CJK strokes intact after a locale rebuild.
    cjk.oversampling = 2.0
    var symbols := SYMBOLS.duplicate()
    symbols.fallbacks = []
    font = REGULAR.duplicate()
    font.fallbacks = [cjk, symbols]
    bold = SEMIBOLD.duplicate()
    var cjk_bold := FontVariation.new()
    cjk_bold.base_font = cjk
    cjk_bold.variation_embolden = 0.5
    var symbols_bold := FontVariation.new()
    symbols_bold.base_font = symbols
    symbols_bold.variation_embolden = 0.5
    bold.fallbacks = [cjk_bold, symbols_bold]
    native = Theme.new()
    native.default_font = font
    native.default_font_size = 14
    native.set_color("font_color", "Label", color("text"))
    for kind in ["Button", "OptionButton"]:
        native.set_stylebox("normal", kind, box("subtle", 10, "", 0, Vector2(12, 6)))
        native.set_stylebox("hover", kind, box("selected", 10, "border", 1, Vector2(12, 6)))
        native.set_stylebox("pressed", kind, box("selected", 10, "input_border", 1, Vector2(12, 6)))
        native.set_stylebox("disabled", kind, box("subtle", 10, "border", 1, Vector2(12, 6)))
        native.set_stylebox("focus", kind, focus_box(10))
        for state in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
            native.set_color(state, kind, color("text"))
        native.set_color("font_disabled_color", kind, color("secondary", 0.5))
        native.set_color("icon_normal_color", kind, color("text"))
        native.set_color("icon_hover_color", kind, color("text"))
        native.set_color("icon_pressed_color", kind, color("text"))
        native.set_constant("h_separation", kind, 8)
        native.set_constant("outline_size", kind, 0)
    native.set_stylebox("normal", "LineEdit", box("surface", 10, "input_border", 1, Vector2(12, 10)))
    native.set_stylebox("focus", "LineEdit", focus_box(10))
    native.set_color("font_color", "LineEdit", color("text"))
    native.set_color("font_placeholder_color", "LineEdit", color("secondary"))
    native.set_color("caret_color", "LineEdit", color("text"))
    native.set_color("selection_color", "LineEdit", color("focus", 0.25))
    native.set_stylebox("panel", "PopupMenu", box("surface", 12, "border", 1, Vector2(8, 8)))
    native.set_stylebox("hover", "PopupMenu", box("selected", 6))
    native.set_color("font_color", "PopupMenu", color("text"))
    native.set_color("font_hover_color", "PopupMenu", color("text"))
    native.set_constant("v_separation", "PopupMenu", 16)
    # The track, not just the thumb, defines the ScrollBar's minimum width.
    native.set_stylebox("scroll", "VScrollBar", box("subtle", 5, "", 0, Vector2(5, 0)))
    for key in ["grabber", "grabber_highlight", "grabber_pressed"]:
        var grabber := box("secondary", 4, "", 0, Vector2(5, 16))
        grabber.bg_color = color("secondary", 0.55 if key == "grabber" else 0.9)
        grabber.expand_margin_left = -2
        grabber.expand_margin_right = -2
        native.set_stylebox(key, "VScrollBar", grabber)
    for key in ["increment", "decrement", "increment_highlight", "decrement_highlight", "increment_pressed", "decrement_pressed"]:
        native.set_icon(key, "VScrollBar", ImageTexture.new())
    var knob := Image.new()
    knob.load_svg_from_string('<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24"><circle cx="12" cy="12" r="10" fill="#%s"/></svg>' % color("accent").to_html(false))
    var knob_texture := ImageTexture.create_from_image(knob)
    for key in ["grabber", "grabber_highlight", "grabber_disabled"]:
        native.set_icon(key, "HSlider", knob_texture)
    native.set_stylebox("focus", "HSlider", focus_box(10))
    native.set_stylebox("panel", "TooltipPanel", box("accent", 8, "", 0, Vector2(10, 6)))
    native.set_color("font_color", "TooltipLabel", color("on_accent"))

func color(key: String, alpha: float = 1.0) -> Color:
    var result := Color(String(colors[key]))
    result.a *= alpha
    return result

func metric(key: String) -> float:
    return float(tokens.layout[key])

func box(fill: String, radius: int, border: String = "", width: int = 0, padding: Vector2 = Vector2.ZERO) -> StyleBoxFlat:
    var result := StyleBoxFlat.new()
    result.bg_color = color(fill) if not fill.is_empty() else Color.TRANSPARENT
    result.set_corner_radius_all(radius)
    result.set_border_width_all(width)
    if not border.is_empty():
        result.border_color = color(border)
    result.content_margin_left = padding.x
    result.content_margin_right = padding.x
    result.content_margin_top = padding.y
    result.content_margin_bottom = padding.y
    return result

func focus_box(radius: int) -> StyleBoxFlat:
    var result := box("", radius, "focus", 2)
    result.expand_margin_left = 2
    result.expand_margin_right = 2
    result.expand_margin_top = 2
    result.expand_margin_bottom = 2
    return result

func style_button(button: Button, variant: String = "secondary", radius: int = 10) -> void:
    var destructive := variant == "destructive"
    var filled := variant == "primary" or destructive
    var fill := "danger_muted" if destructive else ("accent" if variant == "primary" else ("" if variant == "quiet" else "subtle"))
    var edge := ""
    button.add_theme_stylebox_override("normal", box(fill, radius, edge, 1 if not edge.is_empty() else 0, Vector2(12, 6)))
    button.add_theme_stylebox_override("hover", box(fill if filled else "selected", radius, edge, 1 if not edge.is_empty() else 0, Vector2(12, 6)))
    button.add_theme_stylebox_override("pressed", box(fill if filled else "selected", radius, "danger" if destructive else "input_border", 1, Vector2(12, 6)))
    var focus := focus_box(radius)
    if destructive:
        focus.border_color = color("danger")
    button.add_theme_stylebox_override("focus", focus)
    var ink := "on_danger_muted" if destructive else ("on_accent" if variant == "primary" else "text")
    for key in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "icon_normal_color", "icon_hover_color", "icon_pressed_color"]:
        button.add_theme_color_override(key, color(ink))
    button.add_theme_font_override("font", bold)
