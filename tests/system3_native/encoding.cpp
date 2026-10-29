#include "embedded_symbols.h"
#include "encoding.h"
#include <iostream>
#include <stdexcept>

static void Require(bool value) {
    if(!value)
        throw std::runtime_error("encoding contract failed");
}
int main() {
    auto unicode = Encoding::create("utf-8");
    std::string chinese = "中文优先，支持日本語。";
    Require(unicode->fromUtf8(chinese) == chinese &&
            unicode->toUtf8(chinese) == chinese);
    std::string_view characters(chinese);
    Require(unicode->next_codepoint(characters) == U'中');
    Require(unicode->mbslen(chinese) == 11);
    std::string_view short_utf8("\xe4\xb8", 2);
    Require(unicode->next_codepoint(short_utf8) == 0xfffd);
    for(const std::string invalid :
        { std::string("\xc0\x80", 2), std::string("\xed\xa0\x80", 3),
          std::string("\xf4\x90\x80\x80", 4) }) {
        std::string_view bad(invalid);
        Require(unicode->next_codepoint(bad) == 0xfffd);
    }
    auto japanese = Encoding::create("CP932");
    const std::string text = "日本語、ランスとシィル。";
    const auto sjis = japanese->fromUtf8(text);
    Require(japanese->toUtf8(sjis) == text);
    std::string_view view(sjis);
    Require(japanese->next_codepoint(view) == U'日');
    Require(japanese->mblen(0xb1) == 1 && japanese->mblen(0x93) == 2);
    std::string_view truncated("\x93", 1);
    Require(japanese->next_codepoint(truncated) == 0xfffd && truncated.empty());
    std::string_view invalid_sjis("\x80", 1);
    Require(japanese->next_codepoint(invalid_sjis) == 0xfffd);
    Require(japanese->mbslen(std::string("\x93", 1)) == 1);
    std::cout << "SYSTEM3_ENCODING_OK\n";
}
