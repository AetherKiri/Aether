extern "C" {
#include "system4/archive.h"
#include "system4/cg.h"
}
#include <algorithm>
#include <array>
#include <SDL_image.h>
#include <iostream>
#include <stdexcept>
#include <vector>

using Bytes = std::vector<uint8_t>;
static const std::array<std::array<uint8_t, 4>, 4> colors{ { { 255, 0, 0, 255 },
                                                             { 0, 255, 0, 128 },
                                                             { 0, 0, 255, 64 },
                                                             { 255, 255, 255,
                                                               0 } } };

static void Require(bool condition, const char *message) {
    if(!condition)
        throw std::runtime_error(message);
}

static Bytes Fixture(int depth, bool top, bool right, bool rle, bool repeated) {
    Bytes bytes(18);
    bytes[0] = 3; // An optional image ID precedes the pixels.
    bytes[2] = rle ? 10 : 2;
    bytes[12] = bytes[14] = 2;
    bytes[16] = depth;
    bytes[17] = (depth == 32 ? 8 : 0) | (top ? 0x20 : 0) | (right ? 0x10 : 0);
    bytes.insert(bytes.end(), { 'i', 'd', '!' });
    if(rle)
        bytes.push_back(repeated ? 0x83 : 0x03);
    for(int row = 0; row < 2; ++row)
        for(int column = 0; column < 2; ++column) {
            if(repeated && (row || column))
                continue;
            const int x = right ? 1 - column : column;
            const int y = top ? row : 1 - row;
            const auto &color = colors[repeated ? 0 : y * 2 + x];
            bytes.insert(bytes.end(), { color[2], color[1], color[0] });
            if(depth == 32)
                bytes.push_back(color[3]);
        }
    return bytes;
}

static void Check(Bytes bytes, int depth, bool repeated = false) {
    struct archive_data file{};
    file.data = bytes.data();
    file.size = bytes.size();
    struct cg_metrics metrics{};
    Require(cg_get_metrics_data(&file, &metrics), "TGA metrics failed");
    Require(metrics.w == 2 && metrics.h == 2 && metrics.bpp == depth &&
                metrics.has_pixel && metrics.has_alpha == (depth == 32),
            "Incorrect TGA metrics");
    struct cg *image = cg_load_buffer(bytes.data(), bytes.size());
    Require(image && image->pixels,
            (std::string("TGA decode failed: ") + SDL_GetError()).c_str());
    const auto *pixels = static_cast<const uint8_t *>(image->pixels);
    bool valid = true;
    for(int i = 0; i < 4; ++i) {
        const auto &color = colors[repeated ? 0 : i];
        for(int channel = 0; channel < 4; ++channel)
            valid &= pixels[i * 4 + channel] ==
                (channel == 3 && depth == 24 ? 255 : color[channel]);
    }
    cg_free(image);
    Require(valid, "TGA orientation, color channels or alpha changed");
}

int main() {
    try {
        for(int depth : { 24, 32 })
            for(bool top : { false, true })
                for(bool right : { false, true })
                    for(bool rle : { false, true })
                        try {
                            Check(Fixture(depth, top, right, rle, false),
                                  depth);
                        } catch(const std::exception &error) {
                            throw std::runtime_error(
                                std::to_string(depth) +
                                " top=" + std::to_string(top) +
                                " right=" + std::to_string(right) + " rle=" +
                                std::to_string(rle) + ": " + error.what());
                        }
        Check(Fixture(32, true, false, true, true), 32, true);
        for(bool rle : { false, true }) {
            auto bytes = Fixture(32, true, false, rle, false);
            bytes.resize(22);
            struct cg *image = cg_load_buffer(bytes.data(), bytes.size());
            Require(!image, "Truncated TGA was accepted");
            bytes = Fixture(32, true, false, rle, false);
            bytes[12] = 0;
            image = cg_load_buffer(bytes.data(), bytes.size());
            Require(!image, "Zero-width TGA was accepted");
            bytes[12] = bytes[13] = bytes[14] = bytes[15] = 255;
            image = cg_load_buffer(bytes.data(), bytes.size());
            Require(!image, "Oversized TGA was accepted");
        }
        std::cout << "XSYSTEM4_TGA_CONTRACT_OK\n";
        return 0;
    } catch(const std::exception &error) {
        std::cerr << "XSYSTEM4_TGA_CONTRACT_FAILED: " << error.what() << '\n';
        return 1;
    }
}
