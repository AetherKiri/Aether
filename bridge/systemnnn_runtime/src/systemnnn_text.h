#pragma once

#include <cstdint>
#include <filesystem>
#include <memory>
#include <string>
#include <string_view>

namespace emberfall::render { struct MessagePlane; }

namespace aether::systemnnn {

// Owns FreeType and the selected game codec. Calls on one instance are serialized.
class TextRenderer {
public:
    TextRenderer();
    ~TextRenderer();
    TextRenderer(const TextRenderer&) = delete;
    TextRenderer& operator=(const TextRenderer&) = delete;

    // Uses a memory face so native Unicode filesystem paths work on Windows.
    // A failed load preserves the previous font. No font is selected implicitly.
    bool load_font(std::filesystem::path path);

    // Strict CP932 + canonical58 sjis_ext, or explicit legacy59 configuration.
    // Only a valid UTF-8 BOM selects UTF-8; unmarked UTF-8 is never guessed.
    // Malformed input throws std::runtime_error. UIF applies to either profile.
    std::u32string decode(std::string_view input, bool configuration = false) const;
    // For callers whose format explicitly declares UTF-8; also applies UIF.
    std::u32string decode_utf8(std::string_view input) const;
    // Reversible canonical58 game input, inverse UIF, no ISO controls.
    // Throws on ambiguity, unrepresentable characters or byte limit overflow.
    std::string encode(std::u32string_view input, int max_bytes) const;
    // Optional root-level sjis_ext.bin and uif_config.json, ASCII case insensitive.
    // Missing files reset to plain CP932. Invalid files throw and preserve state.
    void load_game_codec(const std::filesystem::path& root);

    // Keep preceding base text; omit valid PC ruby/emphasis annotations, closing
    // markers, backlog color tags and cat-symbol controls. Unknown markup stays.
    static std::u32string plain_dialogue(std::u32string_view input);

    // (x,y) is the top left of the first font line. Pixel size must be 1..4096.
    // color is straight 0xAARRGGBB; source-over output is premultiplied RGBA8.
    // Wrap at glyph boundaries, handle CR/LF/CRLF and tabs, and clip to the
    // plane and [x,x+max_width). max_width <= 0 uses the remaining plane width.
    // Does not allocate/resize the plane; absent font or invalid plane is a no-op.
    void draw(emberfall::render::MessagePlane& plane, std::u32string_view input,
              int x, int y, int size, int max_width, std::uint32_t color = 0xffffffff) const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace aether::systemnnn
