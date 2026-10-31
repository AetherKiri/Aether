#ifndef AETHER_GB18030_H
#define AETHER_GB18030_H

#include <cstdint>
#include <string>
#include <string_view>

namespace aether::text {

// Apple's system iconv rejects the supplementary range of GB18030. Handle
// its algorithmic U+10000..U+10FFFF mapping before calling the native codec
// for BMP runs; the caller retains its existing invalid-input policy.
// https://encoding.spec.whatwg.org/#index-gb18030-ranges-code-point
// AetherSoftPal vendors this header for independent runtime builds.
template<class Convert>
std::string Gb18030ToUtf8(std::string_view input, Convert convert) {
    std::string result;
    result.reserve(input.size());
    size_t run = 0;
    for(size_t at = 0; at < input.size();) {
        const auto a = uint8_t(input[at]);
        if(a >= 0x81 && a <= 0xfe && at + 1 < input.size()) {
            const auto b = uint8_t(input[at + 1]);
            if(b >= 0x30 && b <= 0x39 && at + 3 < input.size()) {
                const auto c = uint8_t(input[at + 2]), d = uint8_t(input[at + 3]);
                if(c >= 0x81 && c <= 0xfe && d >= 0x30 && d <= 0x39) {
                    const uint32_t pointer = ((uint32_t(a - 0x81) * 10 + b - 0x30) * 126 + c - 0x81) * 10 + d - 0x30;
                    if(pointer >= 189000 && pointer <= 1237575) {
                        if(at > run) result += convert(input.substr(run, at - run));
                        const auto cp = pointer - 189000 + 0x10000;
                        result += char(0xf0 | (cp >> 18));
                        result += char(0x80 | ((cp >> 12) & 0x3f));
                        result += char(0x80 | ((cp >> 6) & 0x3f));
                        result += char(0x80 | (cp & 0x3f));
                        run = at + 4;
                    }
                    at += 4;
                    continue;
                }
            }
            at += 2;
        } else ++at;
    }
    if(run < input.size()) result += convert(input.substr(run));
    return result;
}

template<class Convert>
std::string Utf8ToGb18030(std::string_view input, Convert convert) {
    std::string result;
    result.reserve(input.size());
    size_t run = 0;
    for(size_t at = 0; at < input.size(); ++at) {
        const auto a = uint8_t(input[at]);
        if(a < 0xf0 || a > 0xf4 || at + 3 >= input.size()) continue;
        const auto b = uint8_t(input[at + 1]), c = uint8_t(input[at + 2]), d = uint8_t(input[at + 3]);
        if((b & 0xc0) != 0x80 || (c & 0xc0) != 0x80 || (d & 0xc0) != 0x80) continue;
        const uint32_t cp = (uint32_t(a & 7) << 18) | (uint32_t(b & 0x3f) << 12) |
                            (uint32_t(c & 0x3f) << 6) | (d & 0x3f);
        if(cp < 0x10000 || cp > 0x10ffff) continue;
        if(at > run) result += convert(input.substr(run, at - run));
        const auto pointer = cp - 0x10000 + 189000;
        result += char(0x81 + pointer / 12600);
        result += char(0x30 + (pointer / 1260) % 10);
        result += char(0x81 + (pointer / 10) % 126);
        result += char(0x30 + pointer % 10);
        at += 3;
        run = at + 1;
    }
    if(run < input.size()) result += convert(input.substr(run));
    return result;
}

} // namespace aether::text
#endif
