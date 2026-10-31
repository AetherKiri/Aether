extends Control
## Liquid-glass surface.
##
## Draws a rounded shape that samples the frame behind it, blurs it a little,
## bends it near the rim (lens refraction) and lights the rim from the top.
## Presses show a Material-style ink splash that starts at the touch point.
## All state changes use critically damped easing (no overshoot) so the
## surface never wobbles. It is purely visual and ignores input; call
## bind(button) to drive hover/press from a BaseButton.

const SHADER_CODE := """
shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform vec2 rect_size = vec2(64.0);
uniform float radius = 32.0;
uniform vec4 tint : source_color = vec4(0.10, 0.11, 0.14, 0.38);
uniform vec4 accent : source_color = vec4(1.0, 0.42, 0.24, 1.0);
uniform float accent_mix = 0.0;
uniform float hover = 0.0;
uniform float press = 0.0;
uniform vec2 ink_center = vec2(32.0);
uniform float ink_radius = 0.0;
uniform float ink_alpha = 0.0;
uniform float blur = 2.2;
uniform float refraction = 7.0;

varying vec2 local_pos;
varying vec4 vertex_color;

float sd_box(vec2 p, vec2 b, float r) {
    vec2 q = abs(p) - b + vec2(r);
    return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

void vertex() {
    local_pos = VERTEX;
    vertex_color = COLOR;
}

void fragment() {
    vec2 hb = rect_size * 0.5;
    vec2 p = local_pos - hb;
    float r = min(radius, min(hb.x, hb.y));
    float d = sd_box(p, hb, r);
    float aa = max(fwidth(d), 0.0001);
    float mask = clamp(0.5 - d / aa, 0.0, 1.0);
    if (mask <= 0.0) {
        discard;
    }
    vec2 e = vec2(0.75, 0.0);
    vec2 n = vec2(
        sd_box(p + e.xy, hb, r) - sd_box(p - e.xy, hb, r),
        sd_box(p + e.yx, hb, r) - sd_box(p - e.yx, hb, r)
    );
    n = n / max(length(n), 0.0001);

    float depth = max(min(hb.x, hb.y) * 0.6, 1.0);
    float lens = pow(clamp(1.0 + d / depth, 0.0, 1.0), 3.0);
    vec2 suv = SCREEN_UV - n * lens * refraction * SCREEN_PIXEL_SIZE;
    vec3 col = textureLod(screen_tex, suv, blur).rgb;

    float fill = clamp(tint.a + 0.06 * hover + 0.05 * press, 0.0, 1.0);
    col = mix(col, tint.rgb, fill);
    col = mix(col, accent.rgb, accent_mix);

    float ink_d = distance(local_pos, ink_center);
    float ink = 1.0 - smoothstep(ink_radius - 10.0, ink_radius, ink_d);
    vec3 ink_rgb = mix(vec3(1.0), accent.rgb, 0.25);
    col = mix(col, ink_rgb, ink * ink_alpha * 0.16);
    col += vec3(0.035) * press;

    float sheen = 1.0 - smoothstep(-hb.y, hb.y * 0.35, p.y);
    col += vec3(0.045 + 0.025 * hover) * sheen;

    vec2 light_dir = normalize(vec2(-0.35, -1.0));
    float lit = clamp(dot(n, light_dir), 0.0, 1.0);
    float unlit = clamp(-dot(n, light_dir), 0.0, 1.0);
    float rim = 1.0 - smoothstep(0.0, 1.4, -d);
    float inner = (1.0 - smoothstep(0.0, 5.0, -d)) * lens;
    col += vec3(1.0) * rim * (0.10 + 0.50 * lit + 0.12 * unlit + 0.10 * hover);
    col += vec3(1.0) * inner * 0.05 * lit;

    COLOR = vec4(col, mask) * vertex_color;
}
"""

static var _shader: Shader

var radius := 999.0:
    set(value):
        radius = value
        _push_static()
var tint := Color(0.10, 0.11, 0.14, 0.38):
    set(value):
        tint = value
        _push_static()
var accent := Color("ff6a3d"):
    set(value):
        accent = value
        _push_static()
var hovered := false
var pressed := false
var selected := false
var selected_amount := 0.32

var _mat: ShaderMaterial
var _hover := 0.0
var _press := 0.0
var _accent := 0.0
var _ink_center := Vector2.ZERO
var _ink_t := 1.0
var _ink_alpha := 0.0
var _animating := true

func _init() -> void:
    name = "Glass"
    mouse_filter = Control.MOUSE_FILTER_IGNORE
    show_behind_parent = true
    if _shader == null:
        _shader = Shader.new()
        _shader.code = SHADER_CODE
    _mat = ShaderMaterial.new()
    _mat.shader = _shader
    material = _mat
    set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    _push_static()

func bind(button: BaseButton) -> void:
    button.mouse_entered.connect(func(): hovered = true; _wake())
    button.mouse_exited.connect(func(): hovered = false; _wake())
    button.button_down.connect(_on_down.bind(button))
    button.button_up.connect(func(): pressed = false; _wake())

func press_at(local_position: Vector2) -> void:
    pressed = true
    _ink_center = local_position
    _ink_t = 0.0
    _ink_alpha = 1.0
    _wake()

func _on_down(button: BaseButton) -> void:
    var local := button.get_local_mouse_position()
    if not Rect2(Vector2.ZERO, size).has_point(local):
        local = size * 0.5
    press_at(local)

func _wake() -> void:
    _animating = true
    set_process(true)

func _notification(what: int) -> void:
    if what == NOTIFICATION_RESIZED:
        _push_static()
        queue_redraw()

func _push_static() -> void:
    if _mat == null:
        return
    _mat.set_shader_parameter("rect_size", size)
    _mat.set_shader_parameter("radius", radius)
    _mat.set_shader_parameter("tint", tint)
    _mat.set_shader_parameter("accent", accent)

func _draw() -> void:
    draw_rect(Rect2(Vector2.ZERO, size), Color.WHITE)

static func approach(current: float, target: float, rate: float, delta: float) -> float:
    var next := lerpf(current, target, 1.0 - exp(-rate * delta))
    return target if absf(next - target) < 0.001 else next

func _process(delta: float) -> void:
    if not _animating:
        set_process(false)
        return
    _hover = approach(_hover, 1.0 if hovered else 0.0, 14.0, delta)
    _press = approach(_press, 1.0 if pressed else 0.0, 26.0 if pressed else 10.0, delta)
    _accent = approach(_accent, selected_amount if selected else 0.0, 12.0, delta)
    if _ink_t < 1.0:
        _ink_t = minf(1.0, _ink_t + delta / 0.5)
    if not pressed:
        _ink_alpha = approach(_ink_alpha, 0.0, 7.0, delta)
    var eased := 1.0 - pow(1.0 - _ink_t, 3.0)
    var far := 0.0
    for corner in [Vector2.ZERO, Vector2(size.x, 0), Vector2(0, size.y), size]:
        far = maxf(far, _ink_center.distance_to(corner))
    _mat.set_shader_parameter("hover", _hover)
    _mat.set_shader_parameter("press", _press)
    _mat.set_shader_parameter("accent_mix", _accent)
    _mat.set_shader_parameter("ink_center", _ink_center)
    _mat.set_shader_parameter("ink_radius", eased * (far + 10.0))
    _mat.set_shader_parameter("ink_alpha", _ink_alpha)
    var settled := (
        _hover == (1.0 if hovered else 0.0)
        and _press == (1.0 if pressed else 0.0)
        and _accent == (selected_amount if selected else 0.0)
        and _ink_t >= 1.0
        and (pressed or _ink_alpha == 0.0)
    )
    _animating = not settled

func set_selected(value: bool) -> void:
    selected = value
    _wake()
