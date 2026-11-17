#include "systemnnn_text.h"
#include <emberfall/layers.hpp>

#include <algorithm>
#include <array>
#include <cassert>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <type_traits>

using aether::systemnnn::TextRenderer;
namespace {
template<class F> void rejects(F operation) {
    bool threw = false;
    try { operation(); } catch (const std::exception&) { threw = true; }
    assert(threw);
}
void put(const std::filesystem::path& path, const std::string& bytes) {
    std::ofstream file(path, std::ios::binary);
    file.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
    assert(file.good());
}
std::string pair(unsigned high, unsigned low) { return {static_cast<char>(high), static_cast<char>(low)}; }
emberfall::render::MessagePlane plane() {
    emberfall::render::MessagePlane p;
    p.width = 100; p.height = 100; p.stride = p.width * 4 + 12;
    p.rgba.resize(p.stride * p.height, 0);
    for (unsigned y = 0; y < p.height; ++y)
        std::fill(p.rgba.begin() + y * p.stride + p.width * 4, p.rgba.begin() + (y + 1) * p.stride, 0x5a);
    return p;
}
}

int main(int argc, char** argv) {
    assert(argc == 2);
    static_assert(!std::is_copy_constructible_v<TextRenderer>);
    TextRenderer text;
    assert(text.decode("ABC\t\r\n") == U"ABC\t\r\n");
    assert(text.decode(std::string("\x1a\x1c\x7f\x80\xa0\xfd\xfe\xff", 8)) ==
           std::u32string({0x1a, 0x1c, 0x7f, 0x80, 0xf8f0, 0xf8f1, 0xf8f2, 0xf8f3}));
    assert(text.decode(pair(0x82, 0xa0)) == U"\u3042");
    assert(text.decode(std::string("\xa1\xdf", 2)) == U"\uff61\uff9f");
    assert(text.encode(U"\u3042", 2) == pair(0x82, 0xa0));
    assert(text.encode(U"\uff61\uf8f0\uf8f3", 3) == std::string("\xa1\xa0\xff", 3));
    assert(text.decode_utf8("\xe3\x81\x82") == U"\u3042");
    assert(text.decode("\xef\xbb\xbf\xe3\x81\x82") == U"\u3042");
    rejects([&] { text.decode("\xe3\x81\x82"); }); // Unmarked UTF-8 is not guessed.
    rejects([&] { text.decode("\xef\xbb\xbf\xc0\xaf"); });
    rejects([&] { text.decode_utf8("\xed\xa0\x80"); });
    rejects([&] { text.decode_utf8("\xf4\x90\x80\x80"); });
    rejects([&] { text.decode("\x82"); });
    rejects([&] { text.decode(pair(0x81, 0x7f)); });
    rejects([&] { text.decode(pair(0x81, 0x01)); });
    rejects([&] { text.encode(U"\n", 10); });
    rejects([&] { text.encode(U"\U0001f600", 10); });
    rejects([&] { text.encode(U"\u00a5", 10); }); // Lossy CP932 alias to backslash.
    rejects([&] { text.encode(U"\u3042", 1); });
    rejects([&] { text.encode(U"x", -1); });
    rejects([&] { text.encode(std::u32string(1, 0xd800), 10); });
    rejects([&] { text.decode(std::string(4 * 1024 * 1024 + 1, 'a')); });

    const auto root = std::filesystem::temp_directory_path() /
        ("systemnnn-text-test-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    assert(std::filesystem::create_directory(root));
    std::string mappings;
    for (unsigned i = 0; i < 59 * 58; ++i) {
        const unsigned point = 0x100 + i;
        mappings += static_cast<char>(point & 255); mappings += static_cast<char>(point >> 8);
    }
    put(root / "SJIS_EXT.BIN", mappings);
    text.load_game_codec(root);
    std::array<unsigned, 5> avoid{9, 10, 13, 32, 44};
    for (unsigned index = 0; index < 59 * 58; ++index) {
        const auto high_for = [](unsigned row) { return row < 0x1f ? 0x81 + row : 0xe0 + row - 0x1f; };
        unsigned low = index % 58 + 1;
        for (auto skipped : avoid) if (low >= skipped) ++low;
        const auto input = pair(high_for(index / 58), low);
        const auto expected = std::u32string(1, 0x100 + index);
        assert(text.decode(input) == expected);
        assert(text.decode(text.encode(expected, 2)) == expected);
        unsigned legacy_low = index % 59 + 1;
        for (unsigned j = 0; j < 4; ++j) if (legacy_low >= avoid[j]) ++legacy_low;
        assert(text.decode(pair(high_for(index / 59), legacy_low), true) == expected);
    }
    for (unsigned low : {0u, 9u, 10u, 13u, 32u, 44u})
        rejects([&] { text.decode(pair(0x81, low)); });
    assert(text.decode(pair(0x81, 44), true).size() == 1);
    assert(text.decode(pair(0x82, 1)) != text.decode(pair(0x82, 1), true));

    put(root / "uif_config.json", R"({"character_substitution":{"enable":true,"source_characters":"A\u0100","target_characters":"\ud83d\ude00\u754c"}})");
    text.load_game_codec(root);
    assert(text.decode("A") == U"\U0001f600");
    assert(text.decode(pair(0x81, 1)) == U"\u754c");
    assert(text.decode_utf8("A") == U"\U0001f600");
    assert(text.encode(U"\U0001f600", 1) == "A");
    assert(text.encode(U"\u754c", 2) == pair(0x81, 1));
    rejects([&] { text.encode(U"A", 1); });
    put(root / "uif_config.json", R"({"character_substitution":{"enable":true,"source_characters":"AB","target_characters":"xx"}})");
    text.load_game_codec(root);
    rejects([&] { text.encode(U"x", 1); });
    put(root / "uif_config.json", R"({"character_substitution":{"enable":true,"enable":false}})");
    rejects([&] { text.load_game_codec(root); });
    assert(text.decode("AB") == U"xx"); // Failed reload preserves state.
    put(root / "uif_config.json", R"({"character_substitution":{"enable":true,"source_characters":"AA","target_characters":"xy"}})");
    rejects([&] { text.load_game_codec(root); });
    put(root / "uif_config.json", R"({"character_substitution":{"enable":"yes"}})");
    rejects([&] { text.load_game_codec(root); });
    put(root / "uif_config.json", "{}");
    put(root / "SJIS_EXT.BIN", std::string(1, 'x'));
    rejects([&] { text.load_game_codec(root); });
    put(root / "SJIS_EXT.BIN", std::string("\x00\xd8", 2));
    rejects([&] { text.load_game_codec(root); });

    assert(TextRenderer::plain_dialogue(U"\u6f22\u5b57#\uff3b\uff12\u304b\u3093\u3058\uff3d!#\uff3d") == U"\u6f22\u5b57!");
    assert(TextRenderer::plain_dialogue(U"ab#[2ruby]cd#.xx]#]#Rred#W#c") == U"abcdred");
    assert(TextRenderer::plain_dialogue(U"a#[0bad]#?x") == U"a#[0bad]#?x");

    auto absent = plane();
    text.draw(absent, U"A", 0, 0, 20, 100);
    assert(absent.rgba == plane().rgba);
    const auto unicode_font = root / std::filesystem::path(u8"\u5b57-font.ttf");
    assert(std::filesystem::copy_file(std::filesystem::path(argv[1]), unicode_font));
    assert(text.load_font(unicode_font));
    assert(std::filesystem::remove(unicode_font)); // Face retains bytes, not a file mapping.
    assert(!text.load_font(root / "missing-font.ttf"));
    auto plain = plane(), markup = plane();
    text.draw(plain, U"ab", 0, 0, 20, 100);
    text.draw(markup, U"ab#[2ruby]", 0, 0, 20, 100);
    assert(plain.rgba == markup.rgba);
    auto lf = plane(), crlf = plane(), wrapped = plane();
    text.draw(lf, U"W\nW", 0, 0, 20, 15);
    text.draw(crlf, U"W\r\nW", 0, 0, 20, 15);
    text.draw(wrapped, U"WW", 0, 0, 20, 15);
    assert(lf.rgba == crlf.rgba && lf.rgba == wrapped.rgba);
    auto source = plane(), composited = plane();
    for (unsigned y = 0; y < composited.height; ++y)
        for (unsigned x = 0; x < composited.width; ++x) {
            auto* pixel = composited.rgba.data() + y * composited.stride + x * 4;
            pixel[0] = 20; pixel[1] = 30; pixel[2] = 40; pixel[3] = 80;
        }
    text.draw(source, U"A", 0, 0, 20, 100, 0x80402010);
    text.draw(composited, U"A", 0, 0, 20, 100, 0x80402010);
    for (unsigned y = 0; y < source.height; ++y)
        for (unsigned x = 0; x < source.width; ++x) {
            auto at = y * source.stride + x * 4;
            const unsigned inverse = 255 - source.rgba[at + 3];
            for (unsigned channel = 0; channel < 4; ++channel) {
                const unsigned background[] = {20, 30, 40, 80};
                assert(composited.rgba[at + channel] == source.rgba[at + channel] +
                       (background[channel] * inverse + 127) / 255);
            }
        }
    auto drawn = plane();
    text.draw(drawn, U"W\r\nW\nWWWWWWWWWWWW", -2, -1, 20, 14, 0x80402010);
    bool ink = false, lower = false;
    for (unsigned y = 0; y < drawn.height; ++y) {
        for (unsigned x = 0; x < drawn.width; ++x) {
            auto at = y * drawn.stride + x * 4;
            if (drawn.rgba[at + 3]) {
                ink = true; lower |= y > 25;
                assert(x < 12);
                assert(drawn.rgba[at] <= drawn.rgba[at + 3]);
                assert(drawn.rgba[at + 1] <= drawn.rgba[at + 3]);
                assert(drawn.rgba[at + 2] <= drawn.rgba[at + 3]);
                assert(drawn.rgba[at + 3] <= 128);
            }
        }
        for (unsigned x = drawn.width * 4; x < drawn.stride; ++x) assert(drawn.rgba[y * drawn.stride + x] == 0x5a);
    }
    assert(ink && lower);
    auto before = drawn.rgba;
    text.draw(drawn, U"A", std::numeric_limits<int>::max(), std::numeric_limits<int>::min(), 4096, 10);
    text.draw(drawn, U"A", 0, 0, 4097, 10);
    assert(drawn.rgba == before);
    auto malformed = drawn; malformed.stride = 1;
    text.draw(malformed, U"A", 0, 0, 20, 100);
    assert(malformed.rgba == before);

    // The test owns this unique temporary directory and only its fixture files.
    assert(root.parent_path() == std::filesystem::temp_directory_path());
    std::filesystem::remove_all(root);
    std::cout << "systemnnn text: CP932, 3422 canonical + legacy tunnel entries, UIF, markup and rendering passed\n";
}
