extends Control

# GPU-drawn rounded surface: two-stop gradient fill, gradient-fading rim,
# outer glow and an animatable sheen band. Place it as a full-rect child with
# show_behind_parent so it renders underneath the parent's own text/icons.
# Every visual parameter is a shader uniform, which lets motion code tween
# `material:shader_parameter/<name>` directly.

const AetherShaders = preload("res://scripts/ui/aether_shaders.gd")

var glow_extent := 0.0
var _material: ShaderMaterial

func _init() -> void:
    mouse_filter = Control.MOUSE_FILTER_IGNORE
    _material = AetherShaders.material(AetherShaders.surface())
    # Seed every tweened uniform so tween_param always has a typed start.
    _material.set_shader_parameter("brightness", 0.0)
    _material.set_shader_parameter("glow_color", Color(0, 0, 0, 0))
    _material.set_shader_parameter("border_color", Color(0, 0, 0, 0))
    _material.set_shader_parameter("sheen", -1.0)
    material = _material
    set_anchors_preset(Control.PRESET_FULL_RECT)
    resized.connect(_sync_size)

func configure(
    color_a: Color,
    color_b: Color = Color(-1, -1, -1, -1),
    radius: float = 14.0,
    angle: float = 0.0
) -> Control:
    set_param("color_a", color_a)
    set_param("color_b", color_a if color_b.a < 0.0 else color_b)
    set_param("radius", radius)
    set_param("angle", angle)
    return self

func rim(color: Color, width: float = 1.0, fade: float = 0.0) -> Control:
    set_param("border_color", color)
    set_param("border_width", width)
    set_param("border_fade", fade)
    return self

func glow(color: Color, extent: float) -> Control:
    glow_extent = maxf(0.0, extent)
    set_param("glow_color", color)
    set_param("glow", glow_extent)
    queue_redraw()
    return self

func set_param(name: StringName, value) -> void:
    _material.set_shader_parameter(name, value)

func get_param(name: StringName):
    var value = _material.get_shader_parameter(name)
    if value == null:
        return _material.shader.get_default_parameter(name) if _material.shader != null else null
    return value

func shader_material() -> ShaderMaterial:
    return _material

# Plays a single light sweep across the surface.
func sweep(duration: float = 0.75, strength: float = 0.26) -> void:
    set_param("sheen_strength", strength)
    var tween := create_tween()
    tween.tween_method(func(value: float): set_param("sheen", value), -0.4, 1.4, duration) \
        .set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
    tween.tween_callback(func(): set_param("sheen", -1.0))

func tween_param(name: StringName, target, duration: float = 0.22) -> Tween:
    var tween := create_tween()
    tween.tween_property(_material, "shader_parameter/%s" % name, target, duration) \
        .set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
    return tween

func _sync_size() -> void:
    set_param("box_size", size)
    queue_redraw()

func _notification(what: int) -> void:
    if what == NOTIFICATION_ENTER_TREE or what == NOTIFICATION_READY:
        _sync_size()

func _draw() -> void:
    var g := glow_extent
    draw_rect(Rect2(Vector2(-g, -g), size + Vector2(g, g) * 2.0), Color.WHITE)
