extends SceneTree
## Shape real library titles without relying on fonts installed on the machine.
const DESIGN := preload("res://scripts/ui/astryx/astryx_theme.gd")
const SAMPLES := [
    "游戏库 全部游戏 最近游玩",
    "【双端KR】是谁杀死了知更鸟",
    "【ONS】是谁杀了知更鸟",
    "恋爱少不了撒娇",
    "秽翼的尤斯蒂娅 寄宿少女的誓约与魔法",
    "見上げてごらん、夜空の星を 戦国†恋姫X",
    "Amenity's Life MiniFanDiscレゾナ＆板野奏Ver",
    "（汉化）Nightmare×Maverick ～災厄のレヴェナント～",
    "繁體中文 遊戲庫 스터디 스테디 ♥ ★",
]
var failures := 0

func _expect(value: bool, message: String) -> void:
    if not value:
        failures += 1
        push_error(message)

func _initialize() -> void:
    var server := TextServerManager.get_primary_interface()
    for mode in ["light", "dark"]:
        var design = DESIGN.new(mode)
        for role in ["font", "bold"]:
            var font: Font = design.get(role)
            var bundled := font.get_rids()
            var cjk_face := RID()
            for sample in SAMPLES:
                var line := TextLine.new()
                line.add_string(sample, font, 24)
                for glyph in server.shaped_text_get_glyphs(line.get_rid()):
                    var face: RID = glyph.font_rid
                    var character: String = sample.substr(int(glyph.start), 1)
                    _expect(face.is_valid() and int(glyph.index) != 0,
                        "%s/%s: missing glyph for %s" % [mode, role, character])
                    _expect(bundled.has(face),
                        "%s/%s: %s depends on an unbundled fallback" % [mode, role, character])
                    var code := character.unicode_at(0)
                    if code >= 0x3400 and code <= 0x9fff:
                        if not cjk_face.is_valid():
                            cjk_face = face
                        _expect(face == cjk_face,
                            "%s/%s: %s switches CJK face/weight within a title" % [mode, role, character])
    print("ASTRYX_TYPOGRAPHY_OK" if failures == 0 else "ASTRYX_TYPOGRAPHY_FAILED: %d" % failures)
    quit(0 if failures == 0 else 1)
