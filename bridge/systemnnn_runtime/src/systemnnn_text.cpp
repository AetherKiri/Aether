#include "systemnnn_text.h"

#include <emberfall/layers.hpp>
#include <ft2build.h>
#include FT_FREETYPE_H
#include <iconv.h>
#include <nlohmann/json.hpp>

#include <algorithm>
#include <array>
#include <fstream>
#include <limits>
#include <mutex>
#include <stdexcept>
#include <type_traits>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace aether::systemnnn {
namespace {
constexpr std::size_t max_input = 4 * 1024 * 1024;
constexpr std::size_t max_mappings = 0x3b * 0x3a;
constexpr std::size_t max_config = 1024 * 1024;
constexpr char32_t ambiguous = 0xffffffff;
constexpr std::array<unsigned, 5> canonical_avoid{9, 10, 13, 32, 44};

[[noreturn]] void fail(const char* message) { throw std::runtime_error(message); }
bool scalar(char32_t point) { return point <= 0x10ffff && !(point >= 0xd800 && point <= 0xdfff); }
bool control(char32_t point) { return point < 0x20 || (point >= 0x7f && point <= 0x9f); }

std::u32string utf8(std::string_view input) {
    if (input.size() > max_input) fail("Text input exceeds 4 MiB limit");
    std::u32string output;
    output.reserve(input.size());
    for (std::size_t at = 0; at < input.size();) {
        unsigned first = static_cast<unsigned char>(input[at++]);
        char32_t point = first;
        unsigned extra = 0;
        char32_t minimum = 0;
        if (first >= 0xc2 && first <= 0xdf) { extra = 1; point &= 0x1f; minimum = 0x80; }
        else if (first >= 0xe0 && first <= 0xef) { extra = 2; point &= 0x0f; minimum = 0x800; }
        else if (first >= 0xf0 && first <= 0xf4) { extra = 3; point &= 7; minimum = 0x10000; }
        else if (first >= 0x80) fail("Malformed UTF-8 text");
        if (extra > input.size() - at) fail("Truncated UTF-8 text");
        for (unsigned i = 0; i < extra; ++i) {
            unsigned byte = static_cast<unsigned char>(input[at++]);
            if ((byte & 0xc0) != 0x80) fail("Malformed UTF-8 continuation");
            point = (point << 6) | (byte & 0x3f);
        }
        if (point < minimum || !scalar(point)) fail("Invalid UTF-8 scalar");
        output.push_back(point);
    }
    return output;
}

// GNU iconv accepts char**, while some libiconv builds declare const char**.
template<class Function>
std::size_t convert(Function function, iconv_t descriptor, char*& input, std::size_t& remaining,
                    char*& output, std::size_t& available) {
    if constexpr (std::is_invocable_v<Function, iconv_t, char**, std::size_t*, char**, std::size_t*>)
        return function(descriptor, &input, &remaining, &output, &available);
    else {
        const char* constant = input;
        const auto result = function(descriptor, &constant, &remaining, &output, &available);
        input = const_cast<char*>(constant);
        return result;
    }
}

class Converter {
public:
    Converter(const char* to, const char* from) : value_(iconv_open(to, from)) {
        if (value_ == reinterpret_cast<iconv_t>(-1)) fail("iconv CP932/UTF-32LE codec is unavailable");
    }
    ~Converter() { iconv_close(value_); }
    Converter(const Converter&) = delete;
    Converter& operator=(const Converter&) = delete;
    std::string run(std::string_view bytes) {
        iconv(value_, nullptr, nullptr, nullptr, nullptr);
        std::array<char, 32> buffer{};
        char* input = const_cast<char*>(bytes.data());
        std::size_t remaining = bytes.size(), available = buffer.size();
        char* output = buffer.data();
        const auto result = convert(&iconv, value_, input, remaining, output, available);
        if (result == static_cast<std::size_t>(-1) || result != 0 || remaining != 0)
            fail("Invalid or unrepresentable CP932 character");
        return std::string(buffer.data(), static_cast<std::size_t>(output - buffer.data()));
    }
private:
    iconv_t value_;
};

struct Codec {
    std::u32string mapping;
    std::unordered_map<char32_t, char32_t> substitutions, inverse;

    std::u32string raw_decode(std::string_view input, bool configuration) const {
        if (input.size() > max_input) fail("Text input exceeds 4 MiB limit");
        std::u32string result;
        result.reserve(input.size());
        Converter decoder("UTF-32LE", "CP932");
        for (std::size_t at = 0; at < input.size();) {
            unsigned high = static_cast<unsigned char>(input[at++]);
            if (high < 0x80) { result.push_back(high); continue; }
            if (high >= 0xa1 && high <= 0xdf) { result.push_back(0xff61 + high - 0xa1); continue; }
            if (high == 0x80 || high == 0xa0 || high >= 0xfd) {
                result.push_back(high == 0x80 ? 0x80 : high == 0xa0 ? 0xf8f0 : 0xf8f1 + high - 0xfd);
                continue;
            }
            if (at == input.size()) fail("Truncated CP932 character");
            unsigned low = static_cast<unsigned char>(input[at++]);
            if (low < 0x40) {
                if (low == 0) fail("NUL inside tunnel pair");
                unsigned low_index = low;
                const std::size_t avoid_count = configuration ? 4 : 5;
                for (std::size_t i = avoid_count; i-- > 0;) {
                    if (low == canonical_avoid[i]) fail("Reserved low byte in tunnel pair");
                    if (low_index > canonical_avoid[i]) --low_index;
                }
                const unsigned row = high < 0xa0 ? high - 0x81 : 0x1f + high - 0xe0;
                const std::size_t index = row * (configuration ? 59 : 58) + low_index - 1;
                if (index >= mapping.size()) fail("Tunnel pair has no sjis_ext mapping");
                result.push_back(mapping[index]);
            } else {
                const auto converted = decoder.run(input.substr(at - 2, 2));
                if (converted.size() != 4) fail("CP932 pair did not produce one Unicode scalar");
                char32_t point = 0;
                for (unsigned i = 0; i < 4; ++i)
                    point |= static_cast<char32_t>(static_cast<unsigned char>(converted[i])) << (i * 8);
                if (!scalar(point)) fail("CP932 produced invalid Unicode scalar");
                result.push_back(point);
            }
        }
        return result;
    }

    std::u32string substitute(std::u32string text) const {
        for (auto& point : text) {
            const auto found = substitutions.find(point);
            if (found != substitutions.end()) point = found->second;
        }
        return text;
    }

    std::string character(char32_t point, Converter& encoder) const {
        if (!point || !scalar(point)) return {};
        if (point <= 0x80) return std::string(1, static_cast<char>(point));
        if (point >= 0xff61 && point <= 0xff9f) return std::string(1, static_cast<char>(0xa1 + point - 0xff61));
        if (point == 0xf8f0) return std::string(1, static_cast<char>(0xa0));
        if (point >= 0xf8f1 && point <= 0xf8f3) return std::string(1, static_cast<char>(0xfd + point - 0xf8f1));
        std::array<char, 4> wide{};
        for (unsigned i = 0; i < 4; ++i) wide[i] = static_cast<char>((point >> (i * 8)) & 255);
        try {
            auto bytes = encoder.run(std::string_view(wide.data(), wide.size()));
            if (raw_decode(bytes, false) == std::u32string(1, point)) return bytes;
        } catch (const std::runtime_error&) { /* A tunnel mapping may still be reversible. */ }
        for (std::size_t index = 0; index < mapping.size(); ++index) {
            if (mapping[index] != point) continue;
            unsigned row = static_cast<unsigned>(index / 58), low = static_cast<unsigned>(index % 58 + 1);
            for (auto excluded : canonical_avoid) if (low >= excluded) ++low;
            return {static_cast<char>(row < 0x1f ? 0x81 + row : 0xe0 + row - 0x1f), static_cast<char>(low)};
        }
        return {};
    }
};

std::string read_bounded(const std::filesystem::path& path, std::size_t limit) {
    std::ifstream stream(path, std::ios::binary);
    if (!stream) fail("Cannot open text resource or font");
    std::string output;
    std::array<char, 4096> block{};
    while (stream) {
        stream.read(block.data(), block.size());
        const auto count = static_cast<std::size_t>(stream.gcount());
        if (count > limit - output.size()) fail("Text resource or font exceeds size limit");
        output.append(block.data(), count);
    }
    if (!stream.eof()) fail("Cannot read text resource or font");
    return output;
}

std::filesystem::path resource(const std::filesystem::path& root, std::string_view name) {
    const auto direct = root / name;
    if (std::filesystem::is_regular_file(direct)) return direct;
    std::filesystem::path found;
    for (const auto& entry : std::filesystem::directory_iterator(root)) {
        const auto filename = entry.path().filename().u8string();
        if (filename.size() != name.size() || !entry.is_regular_file()) continue;
        bool equal = true;
        for (std::size_t i = 0; i < name.size(); ++i) {
            const unsigned byte = static_cast<unsigned char>(filename[i]);
            if ((byte >= 'A' && byte <= 'Z' ? byte + 'a' - 'A' : byte) != static_cast<unsigned char>(name[i])) {
                equal = false; break;
            }
        }
        if (equal && (found.empty() || entry.path() < found)) found = entry.path();
    }
    return found;
}

void load_uif(Codec& codec, std::string_view bytes) {
    // Match Android limits and reject duplicate keys rather than silently taking
    // the last substitution object. Other injector features are ignored.
    std::vector<std::unordered_set<std::string>> keys;
    std::size_t values = 0;
    const auto parsed = nlohmann::json::parse(bytes.begin(), bytes.end(),
        [&](int depth, nlohmann::json::parse_event_t event, nlohmann::json& value) {
            if (event == nlohmann::json::parse_event_t::object_start ||
                event == nlohmann::json::parse_event_t::array_start || event == nlohmann::json::parse_event_t::value) ++values;
            if (depth > 32 || values > 16384) fail("UIF JSON exceeds complexity limit");
            if (event == nlohmann::json::parse_event_t::object_start) keys.emplace_back();
            if (event == nlohmann::json::parse_event_t::key && !keys.back().insert(value.get<std::string>()).second)
                fail("Duplicate UIF JSON key");
            if (event == nlohmann::json::parse_event_t::object_end) keys.pop_back();
            return true;
        });
    if (!parsed.is_object()) fail("UIF configuration must be an object");
    const auto section = parsed.find("character_substitution");
    if (section == parsed.end() || section->is_null()) return;
    if (!section->is_object()) fail("Invalid UIF character_substitution object");
    const auto enabled = section->find("enable");
    if (enabled == section->end() || enabled->is_null()) return;
    if (!enabled->is_boolean()) fail("Invalid UIF substitution enable flag");
    if (!enabled->get<bool>()) return;
    const auto source = section->find("source_characters"), target = section->find("target_characters");
    if (source == section->end() || target == section->end() || !source->is_string() || !target->is_string())
        fail("Missing UIF character substitution strings");
    const auto from = utf8(source->get<std::string>()), to = utf8(target->get<std::string>());
    if (from.size() != to.size()) fail("UIF character substitution lengths differ");
    for (std::size_t i = 0; i < from.size(); ++i) {
        if (!from[i] || !to[i]) fail("NUL UIF substitution character");
        if (!codec.substitutions.emplace(from[i], to[i]).second) fail("Duplicate UIF source character");
        const auto previous = codec.inverse.emplace(to[i], from[i]);
        if (!previous.second) previous.first->second = ambiguous;
    }
}

bool color_tag(char32_t point) {
    return std::u32string_view(U"BURPGCYWO\u9ed2\u9752\u8d64\u7d2b\u7dd1\u6c34\u9ec4\u767d\u6a59").find(point) != std::u32string_view::npos;
}
unsigned mul255(unsigned a, unsigned b) { return (a * b + 127) / 255; }
} // namespace

struct TextRenderer::Impl {
    mutable std::mutex mutex;
    FT_Library library = nullptr;
    FT_Face face = nullptr;
    std::string font_bytes;
    Codec codec;
    Impl() { if (FT_Init_FreeType(&library)) fail("Cannot initialize FreeType"); }
    ~Impl() { if (face) FT_Done_Face(face); if (library) FT_Done_FreeType(library); }
};

TextRenderer::TextRenderer() : impl_(std::make_unique<Impl>()) {}
TextRenderer::~TextRenderer() = default;

bool TextRenderer::load_font(std::filesystem::path path) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    try {
        auto bytes = read_bounded(path, 128 * 1024 * 1024);
        if (bytes.empty() || bytes.size() > static_cast<std::size_t>(std::numeric_limits<FT_Long>::max())) return false;
        FT_Face face = nullptr;
        if (FT_New_Memory_Face(impl_->library, reinterpret_cast<const FT_Byte*>(bytes.data()),
                               static_cast<FT_Long>(bytes.size()), 0, &face)) return false;
        if (FT_Select_Charmap(face, FT_ENCODING_UNICODE)) { FT_Done_Face(face); return false; }
        if (impl_->face) FT_Done_Face(impl_->face);
        // swap preserves the allocation backing the newly constructed memory face.
        impl_->font_bytes.swap(bytes);
        impl_->face = face;
        return true;
    } catch (const std::exception&) { return false; }
}

void TextRenderer::load_game_codec(const std::filesystem::path& root) {
    Codec codec;
    const auto tunnel = resource(root, "sjis_ext.bin"), uif = resource(root, "uif_config.json");
    if (!tunnel.empty()) {
        const auto bytes = read_bounded(tunnel, max_mappings * 2);
        if (bytes.size() % 2) fail("Invalid sjis_ext.bin byte length");
        for (std::size_t i = 0; i < bytes.size(); i += 2) {
            const char32_t point = static_cast<unsigned char>(bytes[i]) |
                (static_cast<char32_t>(static_cast<unsigned char>(bytes[i + 1])) << 8);
            if (!point || !scalar(point)) fail("NUL/surrogate sjis_ext mapping is unsupported");
            codec.mapping.push_back(point);
        }
    }
    if (!uif.empty()) load_uif(codec, read_bounded(uif, max_config));
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->codec = std::move(codec);
}

std::u32string TextRenderer::decode(std::string_view input, bool configuration) const {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (input.size() > max_input) fail("Text input exceeds 4 MiB limit");
    if (input.substr(0, 3) == std::string_view("\xef\xbb\xbf", 3))
        return impl_->codec.substitute(utf8(input.substr(3)));
    return impl_->codec.substitute(impl_->codec.raw_decode(input, configuration));
}

std::u32string TextRenderer::decode_utf8(std::string_view input) const {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (input.size() > max_input) fail("Text input exceeds 4 MiB limit");
    if (input.substr(0, 3) == std::string_view("\xef\xbb\xbf", 3)) input.remove_prefix(3);
    return impl_->codec.substitute(utf8(input));
}

std::string TextRenderer::encode(std::u32string_view input, int max_bytes) const {
    if (max_bytes < 0 || static_cast<std::size_t>(max_bytes) > max_input || input.size() > max_input)
        fail("Invalid game input byte limit");
    std::lock_guard<std::mutex> lock(impl_->mutex);
    Converter encoder("CP932", "UTF-32LE");
    std::string result;
    result.reserve(std::min(input.size(), static_cast<std::size_t>(max_bytes)));
    for (auto point : input) {
        if (!scalar(point) || control(point)) fail("Game input contains invalid or control character");
        std::string bytes;
        const auto inverse = impl_->codec.inverse.find(point);
        if (inverse != impl_->codec.inverse.end()) {
            if (inverse->second == ambiguous) fail("Ambiguous inverse UIF substitution");
            if (!control(inverse->second)) bytes = impl_->codec.character(inverse->second, encoder);
        }
        const auto direct = impl_->codec.substitutions.find(point);
        if (bytes.empty() && (direct == impl_->codec.substitutions.end() || direct->second == point))
            bytes = impl_->codec.character(point, encoder);
        if (bytes.empty()) fail("Character is not reversibly representable in game encoding");
        if (bytes.size() > static_cast<std::size_t>(max_bytes) - result.size()) fail("Game input exceeds byte limit");
        result += bytes;
    }
    return result;
}

std::u32string TextRenderer::plain_dialogue(std::u32string_view input) {
    std::u32string output;
    output.reserve(input.size());
    for (std::size_t at = 0; at < input.size();) {
        if (input[at] == U'#' && at + 1 < input.size()) {
            const auto command = input[at + 1];
            if (command == U']' || command == U'\uff3d' || color_tag(command) || command == U'c' || command == U'\u732b') {
                at += 2; continue;
            }
            const bool ruby = command == U'[' || command == U'\uff3b';
            const bool emphasis = command == U'.' || command == U'\u5f37';
            if (ruby || emphasis) {
                const auto close = command == U'[' || command == U'.' ? U']' : U'\uff3d';
                std::size_t start = at + 2;
                bool valid = emphasis;
                if (ruby && start < input.size()) {
                    const auto digit = input[start++];
                    valid = (digit >= U'1' && digit <= U'9') || (digit >= U'\uff11' && digit <= U'\uff19');
                }
                std::size_t end = start;
                while (end < input.size() && end - start < 100 && input[end] != close &&
                       input[end] != U'\n' && input[end] != U'\r') ++end;
                if (valid && end > start && end - start < 100 && end < input.size() && input[end] == close) {
                    at = end + 1; continue;
                }
            }
        }
        output.push_back(input[at++]);
    }
    return output;
}

void TextRenderer::draw(emberfall::render::MessagePlane& plane, std::u32string_view input,
                        int x, int y, int size, int max_width, std::uint32_t color) const {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (!impl_->face || size <= 0 || size > 4096 || !plane.width || !plane.height || !(color >> 24)) return;
    if (plane.stride / 4 < plane.width ||
        plane.height > std::numeric_limits<std::size_t>::max() / plane.stride ||
        plane.rgba.size() < plane.stride * plane.height) return;
    FT_Face face = impl_->face;
    if (FT_Set_Pixel_Sizes(face, 0, static_cast<FT_UInt>(size))) return;
    const std::int64_t left = x, right = max_width > 0 ? std::min<std::int64_t>(plane.width, left + max_width) : plane.width;
    if (right <= std::max<std::int64_t>(left, 0)) return;
    const auto text = plain_dialogue(input);
    const std::int64_t ascent = (face->size->metrics.ascender + 63) / 64;
    const std::int64_t line_height = std::max<std::int64_t>(size, (face->size->metrics.height + 63) / 64);
    std::int64_t pen = left, top = y;
    FT_UInt previous = 0;
    const unsigned alpha = color >> 24, red = (color >> 16) & 255, green = (color >> 8) & 255, blue = color & 255;
    for (std::size_t at = 0; at < text.size(); ++at) {
        const char32_t point = text[at];
        if (point == U'\r' || point == U'\n') {
            if (point == U'\r' && at + 1 < text.size() && text[at + 1] == U'\n') ++at;
            pen = left; top += line_height; previous = 0;
            if (top >= plane.height) break;
            continue;
        }
        if (point == U'\t') {
            const auto tab = std::max(1, size * 2);
            pen = left + ((pen - left) / tab + 1) * tab;
            if (pen >= right) { pen = left; top += line_height; }
            previous = 0; continue;
        }
        if (control(point) || !scalar(point)) continue;
        const auto glyph = FT_Get_Char_Index(face, static_cast<FT_ULong>(point));
        if (FT_Load_Glyph(face, glyph, FT_LOAD_DEFAULT)) { previous = 0; continue; }
        FT_Vector kerning{};
        if (previous && glyph && FT_HAS_KERNING(face)) FT_Get_Kerning(face, previous, glyph, FT_KERNING_DEFAULT, &kerning);
        std::int64_t shift = kerning.x / 64;
        const std::int64_t advance = std::max<std::int64_t>(0, (face->glyph->advance.x + 32) / 64);
        if (pen > left && pen + shift + advance > right) { pen = left; top += line_height; shift = 0; }
        if (top >= plane.height) break;
        pen += shift;
        if (FT_Render_Glyph(face->glyph, FT_RENDER_MODE_NORMAL) == 0) {
            const auto& bitmap = face->glyph->bitmap;
            const std::int64_t gx = pen + face->glyph->bitmap_left, gy = top + ascent - face->glyph->bitmap_top;
            const auto first_x = std::max<std::int64_t>({gx, left, 0}), last_x = std::min<std::int64_t>(gx + bitmap.width, right);
            const auto first_y = std::max<std::int64_t>(gy, 0), last_y = std::min<std::int64_t>(gy + bitmap.rows, plane.height);
            for (auto py = first_y; py < last_y; ++py) {
                // FreeType defines pitch as the signed offset down one row.
                const auto row_offset = static_cast<std::ptrdiff_t>(py - gy) * bitmap.pitch;
                const auto* source = bitmap.buffer + row_offset;
                for (auto px = first_x; px < last_x; ++px) {
                    const auto column = static_cast<std::size_t>(px - gx);
                    unsigned coverage = 0;
                    if (bitmap.pixel_mode == FT_PIXEL_MODE_GRAY && bitmap.num_grays > 1)
                        coverage = static_cast<unsigned>(source[column]) * 255 / (bitmap.num_grays - 1);
                    else if (bitmap.pixel_mode == FT_PIXEL_MODE_MONO)
                        coverage = (source[column / 8] & (0x80 >> (column % 8))) ? 255 : 0;
                    if (!coverage) continue;
                    const unsigned a = mul255(alpha, coverage), inverse = 255 - a;
                    auto* pixel = plane.rgba.data() + static_cast<std::size_t>(py) * plane.stride + static_cast<std::size_t>(px) * 4;
                    pixel[0] = static_cast<unsigned char>(std::min(255u, mul255(red, a) + mul255(pixel[0], inverse)));
                    pixel[1] = static_cast<unsigned char>(std::min(255u, mul255(green, a) + mul255(pixel[1], inverse)));
                    pixel[2] = static_cast<unsigned char>(std::min(255u, mul255(blue, a) + mul255(pixel[2], inverse)));
                    pixel[3] = static_cast<unsigned char>(std::min(255u, a + mul255(pixel[3], inverse)));
                }
            }
        }
        pen += advance; previous = glyph;
    }
}

} // namespace aether::systemnnn
