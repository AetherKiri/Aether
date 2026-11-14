extends Control
## Lightweight shell decoration, drawn as vectors underneath the page content.
var triangle := PackedVector2Array([Vector2(0, -1), Vector2(0.9, 0.7), Vector2(-0.9, 0.7), Vector2(0, -1)])
var square := PackedVector2Array([Vector2(-0.8, -0.8), Vector2(0.8, -0.8), Vector2(0.8, 0.8), Vector2(-0.8, 0.8), Vector2(-0.8, -0.8)])

class Glyph:
    var kind := 0
    var x := 0.0
    var progress := 0.0
    var radius := 0.0
    var speed := 0.0
    var phase := 0.0
    var drift := 0.0
    var opacity := 0.0
    var outline := PackedVector2Array()

var glyphs: Array[Glyph] = []
var random := RandomNumberGenerator.new()
var tint := Color.BLACK
var suspended := false
var elapsed := 0.0

func _init() -> void:
    mouse_filter = Control.MOUSE_FILTER_IGNORE
    focus_mode = Control.FOCUS_NONE
    size_flags_horizontal = Control.SIZE_EXPAND_FILL
    size_flags_vertical = Control.SIZE_EXPAND_FILL
    clip_contents = true
    random.randomize()
    set_process(false)

func _ready() -> void:
    resized.connect(_resize_field)
    visibility_changed.connect(_sync_processing)
    _resize_field()
    _sync_processing()

func configure(enabled: bool, theme_color: Color, reduced_motion: bool) -> void:
    tint = theme_color
    visible = enabled and not reduced_motion
    _sync_processing()
    queue_redraw()

func _notification(what: int) -> void:
    if what in [NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_APPLICATION_PAUSED]:
        suspended = true
        _sync_processing()
    elif what in [NOTIFICATION_APPLICATION_FOCUS_IN, NOTIFICATION_APPLICATION_RESUMED]:
        suspended = false
        _sync_processing()

func _sync_processing() -> void:
    set_process(is_inside_tree() and is_visible_in_tree() and not suspended)

func _resize_field() -> void:
    if size.x <= 0 or size.y <= 0:
        return
    var count := clampi(int(size.x * size.y / 22000.0), 12, 36)
    while glyphs.size() < count:
        var glyph := Glyph.new()
        _spawn(glyph)
        # Prewarm the field on first display. Subsequent particles enter below
        # the bottom edge and fade away before being recycled at the top.
        glyph.progress = random.randf()
        glyphs.append(glyph)
    while glyphs.size() > count:
        glyphs.pop_back()
    queue_redraw()

func _spawn(glyph: Glyph) -> void:
    glyph.kind = random.randi_range(0, 3)
    glyph.x = random.randf_range(0.03, 0.97)
    glyph.progress = 0.0
    glyph.radius = random.randf_range(7.0, 13.0)
    glyph.speed = random.randf_range(12.0, 24.0)
    glyph.phase = random.randf_range(0.0, TAU)
    glyph.drift = random.randf_range(6.0, 18.0)
    glyph.opacity = random.randf_range(0.12, 0.22)
    glyph.outline = triangle.duplicate() if glyph.kind == 1 else square.duplicate()
    for index in range(glyph.outline.size()):
        glyph.outline[index] *= glyph.radius

func _process(delta: float) -> void:
    var step := minf(delta, 0.05)
    elapsed += step
    for glyph in glyphs:
        glyph.progress += step * glyph.speed / maxf(size.y + 52.0, 1.0)
        if glyph.progress >= 1.0:
            _spawn(glyph)
    queue_redraw()

func _draw() -> void:
    for glyph in glyphs:
        var position := Vector2(glyph.x * size.x + sin(elapsed * 0.35 + glyph.phase) * glyph.drift,
            lerpf(size.y + 26.0, -26.0, glyph.progress))
        var fade := smoothstep(0.0, 0.1, glyph.progress) * (1.0 - smoothstep(0.82, 1.0, glyph.progress))
        var ink := tint
        ink.a *= glyph.opacity * fade
        var angle := sin(elapsed * 0.2 + glyph.phase) * 0.08
        # Scale the geometry rather than the canvas transform: scaling that
        # transform also magnifies the antialias fringe and makes outlines fuzzy.
        draw_set_transform(position, angle)
        # Match the substantial ring / triangle / cross / frame silhouettes.
        # Proportional strokes retain the same weight at every particle size.
        var stroke := glyph.radius * 0.30
        match glyph.kind:
            0: draw_circle(Vector2.ZERO, glyph.radius * 0.85, ink, false, stroke, true)
            1: draw_polyline(glyph.outline, ink, stroke, true)
            2:
                var arm := glyph.radius * 0.78
                # Butt the second diagonal against the first, avoiding a darker
                # double-blended center in the translucent cross.
                var join := stroke / (2.0 * sqrt(2.0))
                draw_line(Vector2(-arm, -arm), Vector2(arm, arm), ink, stroke, true)
                draw_line(Vector2(-arm, arm), Vector2(-join, join), ink, stroke, true)
                draw_line(Vector2(join, -join), Vector2(arm, -arm), ink, stroke, true)
            3: draw_polyline(glyph.outline, ink, stroke, true)
    draw_set_transform(Vector2.ZERO)
