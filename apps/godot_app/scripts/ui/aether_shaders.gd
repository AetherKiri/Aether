extends RefCounted

# Shared canvas shaders for the Aurora UI. Shaders are compiled once and
# cached; every consumer creates its own ShaderMaterial so uniforms stay
# per-instance. All shaders compute geometry from the local vertex position,
# which keeps rounded masks exact under spring scale and hero morphs.

const SDF_LIB := """
float aether_round_box(vec2 p, vec2 b, float r) {
    vec2 q = abs(p) - b + vec2(r);
    return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - r;
}
"""

const SURFACE_CODE := """
shader_type canvas_item;

uniform vec2 box_size = vec2(64.0);
uniform float glow = 0.0;
uniform float radius = 12.0;
uniform vec4 color_a : source_color = vec4(1.0);
uniform vec4 color_b : source_color = vec4(1.0);
uniform float angle = 0.0;
uniform vec4 border_color : source_color = vec4(0.0);
uniform float border_width = 0.0;
uniform float border_fade = 0.0;
uniform vec4 glow_color : source_color = vec4(0.0);
uniform float sheen = -1.0;
uniform float sheen_strength = 0.28;
uniform float highlight = 0.0;
uniform float brightness = 0.0;

varying vec2 local_pos;

%s

vec4 over(vec4 top, vec4 bottom) {
    float a = top.a + bottom.a * (1.0 - top.a);
    vec3 rgb = (top.rgb * top.a + bottom.rgb * bottom.a * (1.0 - top.a)) / max(a, 0.0001);
    return vec4(rgb, a);
}

void vertex() {
    local_pos = VERTEX;
}

void fragment() {
    vec2 half_box = max(box_size * 0.5, vec2(0.5));
    vec2 p = local_pos - half_box;
    float r = min(radius, min(half_box.x, half_box.y));
    float d = aether_round_box(p, half_box, r);
    float aa = max(fwidth(d), 0.0001);
    float coverage = clamp(0.5 - d / aa, 0.0, 1.0);
    vec2 uv = (p / half_box) * 0.5 + 0.5;

    vec2 dir = vec2(cos(angle), sin(angle));
    float t = clamp(dot(uv - 0.5, dir) + 0.5, 0.0, 1.0);
    vec4 fill = mix(color_a, color_b, t);
    fill.rgb += vec3(brightness);
    fill.rgb += vec3(highlight * smoothstep(0.6, 0.0, uv.y) * 0.22);
    if (sheen > -0.9) {
        float band = (uv.x + uv.y * 0.45) / 1.45 - sheen;
        float s = exp(-band * band * 55.0) * sheen_strength;
        fill.rgb += vec3(s);
    }

    vec4 shape = fill;
    if (border_width > 0.0) {
        float inner = clamp(0.5 - (d + border_width) / aa, 0.0, 1.0);
        float ring = clamp(coverage - inner, 0.0, 1.0);
        vec4 rim = border_color;
        rim.a *= mix(1.0, 1.0 - uv.y * 0.85, border_fade);
        vec4 rim_over = over(rim, fill);
        shape = mix(fill, rim_over, ring / max(coverage, 0.0001));
    }
    shape.a *= coverage;

    if (glow > 0.0 && glow_color.a > 0.0) {
        float g = clamp(1.0 - max(d, 0.0) / glow, 0.0, 1.0);
        vec4 halo = vec4(glow_color.rgb, glow_color.a * g * g * g);
        shape = over(shape, halo);
    }
    COLOR = shape * COLOR;
}
""" % SDF_LIB

const IMAGE_CODE := """
shader_type canvas_item;

uniform vec2 rect_size = vec2(64.0);
uniform float radius = 12.0;
uniform float zoom = 1.0;
uniform vec2 pan = vec2(0.0);
uniform float saturation = 1.0;
uniform float brightness = 0.0;
uniform float fade_bottom = 0.0;

varying vec2 local_pos;

%s

void vertex() {
    local_pos = VERTEX;
}

void fragment() {
    vec2 uv = (UV - vec2(0.5)) / max(zoom, 0.01) + vec2(0.5) + pan;
    vec4 c = texture(TEXTURE, clamp(uv, vec2(0.001), vec2(0.999)));
    float luma = dot(c.rgb, vec3(0.299, 0.587, 0.114));
    c.rgb = mix(vec3(luma), c.rgb, saturation) + vec3(brightness);
    vec2 half_box = rect_size * 0.5;
    vec2 p = local_pos - half_box;
    float d = aether_round_box(p, half_box, min(radius, min(half_box.x, half_box.y)));
    float aa = max(fwidth(d), 0.0001);
    c.a *= clamp(0.5 - d / aa, 0.0, 1.0);
    if (fade_bottom > 0.0) {
        float v = local_pos.y / max(rect_size.y, 1.0);
        c.a *= 1.0 - smoothstep(1.0 - fade_bottom, 1.0, v);
    }
    COLOR = c * COLOR;
}
""" % SDF_LIB

const BACKDROP_CODE := """
shader_type canvas_item;

uniform vec4 base : source_color = vec4(0.03, 0.03, 0.06, 1.0);
uniform vec4 blob_a : source_color = vec4(0.4, 0.2, 0.9, 0.5);
uniform vec4 blob_b : source_color = vec4(0.0, 0.6, 0.7, 0.4);
uniform vec4 blob_c : source_color = vec4(0.9, 0.2, 0.5, 0.3);
uniform vec4 focus_tint : source_color = vec4(0.0);
uniform vec2 pointer = vec2(0.5);
uniform float pointer_strength = 0.0;
uniform vec4 pointer_color : source_color = vec4(1.0);
uniform float aspect = 1.7778;
uniform float speed = 1.0;
uniform float grain = 0.018;
uniform float vignette = 0.28;
uniform float time_offset = 0.0;

float blob(vec2 uv, vec2 c, float r) {
    vec2 d = uv - c;
    d.x *= aspect;
    return exp(-dot(d, d) / (r * r));
}

void fragment() {
    float t = (TIME + time_offset) * 0.045 * speed;
    vec2 uv = UV;
    vec2 ca = vec2(0.18 + 0.12 * sin(t * 1.3), 0.22 + 0.14 * cos(t * 1.1));
    vec2 cb = vec2(0.84 + 0.10 * cos(t * 0.9), 0.30 + 0.16 * sin(t * 1.4 + 1.0));
    vec2 cc = vec2(0.52 + 0.22 * sin(t * 0.7 + 2.0), 0.92 + 0.08 * cos(t * 1.2));
    vec3 col = base.rgb;
    col = mix(col, blob_a.rgb, blob(uv, ca, 0.46) * blob_a.a);
    col = mix(col, blob_b.rgb, blob(uv, cb, 0.40) * blob_b.a);
    col = mix(col, blob_c.rgb, blob(uv, cc, 0.40) * blob_c.a);
    vec2 fc = vec2(0.62 + 0.05 * sin(t * 2.0), 0.46 + 0.05 * cos(t * 1.7));
    col = mix(col, focus_tint.rgb, blob(uv, fc, 0.55) * focus_tint.a);
    col = mix(col, pointer_color.rgb, blob(uv, pointer, 0.20) * pointer_strength);
    vec2 v = uv - 0.5;
    col *= 1.0 - dot(v, v) * vignette;
    float n = fract(sin(dot(floor(FRAGCOORD.xy), vec2(12.9898, 78.233))) * 43758.5453);
    col += (n - 0.5) * grain;
    COLOR = vec4(col, 1.0);
}
"""

const FROST_CODE := """
shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float blur = 3.0;
uniform vec4 tint : source_color = vec4(0.0, 0.0, 0.0, 0.4);
uniform float saturation = 1.2;
uniform vec2 rect_size = vec2(0.0);
uniform float radius = 0.0;

varying vec2 local_pos;

%s

void vertex() {
    local_pos = VERTEX;
}

void fragment() {
    vec2 px = SCREEN_PIXEL_SIZE * pow(2.0, blur);
    vec3 c = textureLod(screen_tex, SCREEN_UV, blur).rgb * 0.36;
    c += textureLod(screen_tex, SCREEN_UV + vec2(px.x, 0.0), blur).rgb * 0.16;
    c += textureLod(screen_tex, SCREEN_UV - vec2(px.x, 0.0), blur).rgb * 0.16;
    c += textureLod(screen_tex, SCREEN_UV + vec2(0.0, px.y), blur).rgb * 0.16;
    c += textureLod(screen_tex, SCREEN_UV - vec2(0.0, px.y), blur).rgb * 0.16;
    float luma = dot(c, vec3(0.299, 0.587, 0.114));
    c = mix(vec3(luma), c, saturation);
    c = mix(c, tint.rgb, tint.a);
    float alpha = COLOR.a;
    if (rect_size.x > 0.0) {
        vec2 half_box = rect_size * 0.5;
        float d = aether_round_box(local_pos - half_box, half_box, min(radius, min(half_box.x, half_box.y)));
        float aa = max(fwidth(d), 0.0001);
        alpha *= clamp(0.5 - d / aa, 0.0, 1.0);
    }
    COLOR = vec4(c, alpha);
}
""" % SDF_LIB

const RIPPLE_CODE := """
shader_type canvas_item;

uniform vec2 rect_size = vec2(64.0);
uniform float radius = 12.0;
uniform vec2 center = vec2(32.0);
uniform float progress = 0.0;
uniform float reach = 120.0;
uniform vec4 tint : source_color = vec4(1.0, 1.0, 1.0, 0.22);

varying vec2 local_pos;

%s

void vertex() {
    local_pos = VERTEX;
}

void fragment() {
    vec2 half_box = rect_size * 0.5;
    float d = aether_round_box(local_pos - half_box, half_box, min(radius, min(half_box.x, half_box.y)));
    float aa = max(fwidth(d), 0.0001);
    float mask = clamp(0.5 - d / aa, 0.0, 1.0);
    float eased = 1.0 - pow(1.0 - progress, 3.0);
    float rr = reach * eased;
    float dist = length(local_pos - center);
    float disc = clamp(rr - dist, 0.0, 1.0);
    float edge = smoothstep(rr - 18.0, rr, dist) * 0.6 + 0.4;
    float fade = 1.0 - smoothstep(0.55, 1.0, progress);
    COLOR = vec4(tint.rgb, tint.a * disc * mask * fade * edge) * COLOR;
}
""" % SDF_LIB

static var _cache := {}

static func _shader(key: String, code: String) -> Shader:
    if not _cache.has(key):
        var shader := Shader.new()
        shader.code = code
        _cache[key] = shader
    return _cache[key]

static func surface() -> Shader:
    return _shader("surface", SURFACE_CODE)

static func image() -> Shader:
    return _shader("image", IMAGE_CODE)

static func backdrop() -> Shader:
    return _shader("backdrop", BACKDROP_CODE)

static func frost() -> Shader:
    return _shader("frost", FROST_CODE)

static func ripple() -> Shader:
    return _shader("ripple", RIPPLE_CODE)

static func material(shader: Shader) -> ShaderMaterial:
    var result := ShaderMaterial.new()
    result.shader = shader
    return result

# Frosted scrim for modals and the loading sheet: blurs whatever is behind it
# and washes it with the palette tint.
static func frost_material(tint_color: Color, blur_level: float = 3.0) -> ShaderMaterial:
    var result := material(frost())
    result.set_shader_parameter("tint", tint_color)
    result.set_shader_parameter("blur", blur_level)
    return result
