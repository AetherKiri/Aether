extends RefCounted

# Lumen canvas shaders. Compiled once and cached; each consumer gets its own
# ShaderMaterial so uniforms stay per-instance.

# Living dot field behind the shell: a regular grid of dots that breathes in
# a slow diagonal wave, brightens around the pointer and picks up a soft
# colour wash for the focused title.
const BACKDROP_CODE := """
shader_type canvas_item;

uniform vec4 base : source_color = vec4(0.05, 0.05, 0.06, 1.0);
uniform vec4 dot_color : source_color = vec4(1.0, 1.0, 1.0, 0.06);
uniform vec4 glow_color : source_color = vec4(1.0, 0.4, 0.2, 0.10);
uniform vec4 focus_tint : source_color = vec4(0.0);
uniform vec2 pointer = vec2(0.5);
uniform float pointer_strength = 0.0;
uniform vec2 view_size = vec2(1280.0, 720.0);
uniform float spacing = 28.0;
uniform float speed = 1.0;

void fragment() {
    vec2 px = UV * view_size;
    float t = TIME * speed;
    vec3 col = base.rgb;

    float top = exp(-pow(UV.y * 2.4, 2.0)) * (0.85 + 0.15 * sin(t * 0.35));
    col = mix(col, glow_color.rgb, top * glow_color.a);

    vec2 fd = UV - vec2(0.78, 0.18);
    fd.x *= view_size.x / max(view_size.y, 1.0);
    col = mix(col, focus_tint.rgb, exp(-dot(fd, fd) * 2.6) * focus_tint.a);

    vec2 id = floor(px / spacing);
    vec2 cell = px - (id + 0.5) * spacing;
    float wave = 0.5 + 0.5 * sin(id.x * 0.33 + id.y * 0.21 - t * 0.9);
    vec2 pd = px - pointer * view_size;
    float near = exp(-dot(pd, pd) / (170.0 * 170.0)) * pointer_strength;
    float radius = 0.9 + wave * 0.45 + near * 1.8;
    float mask = clamp(radius - length(cell) + 0.5, 0.0, 1.0);
    float alpha = dot_color.a * (0.45 + 0.55 * wave) + near * 0.45;
    vec3 dot_rgb = mix(dot_color.rgb, glow_color.rgb, clamp(near * 1.4, 0.0, 1.0));
    col = mix(col, dot_rgb, mask * clamp(alpha, 0.0, 1.0));
    COLOR = vec4(col, 1.0);
}
"""

# Artwork: exact rounded-corner mask computed from the local vertex position
# (stays crisp under scale), hover zoom, optional mip blur, dimming and a
# bottom fade used by the detail backdrop.
const IMAGE_CODE := """
shader_type canvas_item;

uniform vec2 rect_size = vec2(64.0);
uniform float radius = 12.0;
uniform float zoom = 1.0;
uniform float blur = 0.0;
uniform float dim = 0.0;
uniform float fade_bottom = 0.0;
uniform float feather = 0.0;
uniform vec4 fade_color : source_color = vec4(0.0);

varying vec2 local_pos;

float round_box(vec2 p, vec2 b, float r) {
    vec2 q = abs(p) - b + vec2(r);
    return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

void vertex() {
    local_pos = VERTEX;
}

void fragment() {
    vec2 uv = (UV - vec2(0.5)) / max(zoom, 0.01) + vec2(0.5);
    uv = clamp(uv, vec2(0.001), vec2(0.999));
    vec4 c = blur > 0.0 ? textureLod(TEXTURE, uv, blur) : texture(TEXTURE, uv);
    c.rgb *= 1.0 - dim;
    if (fade_bottom > 0.0) {
        float v = local_pos.y / max(rect_size.y, 1.0);
        float f = smoothstep(1.0 - fade_bottom, 1.0, v);
        c.rgb = mix(c.rgb, fade_color.rgb, f * fade_color.a);
    }
    vec2 half_box = rect_size * 0.5;
    float d = round_box(local_pos - half_box, half_box, min(radius, min(half_box.x, half_box.y)));
    float aa = max(fwidth(d), 0.0001);
    c.a *= feather > 0.0 ? 1.0 - smoothstep(-feather, feather * 0.25, d) : clamp(0.5 - d / aa, 0.0, 1.0);
    COLOR = c * COLOR;
}
"""

static var _cache := {}

static func _shader(key: String, code: String) -> Shader:
    if not _cache.has(key):
        var shader := Shader.new()
        shader.code = code
        _cache[key] = shader
    return _cache[key]

static func backdrop() -> Shader:
    return _shader("backdrop", BACKDROP_CODE)

static func image() -> Shader:
    return _shader("image", IMAGE_CODE)

static func material(shader: Shader) -> ShaderMaterial:
    var result := ShaderMaterial.new()
    result.shader = shader
    return result
