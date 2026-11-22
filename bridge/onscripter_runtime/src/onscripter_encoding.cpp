#include "onscripter_encoding.h"
#include "gbk2utf16.h"
#include "sjis2utf16.h"
#include <iconv.h>
#include <cstring>
#include <mutex>
#include <stdexcept>

namespace {
// ONS keeps its default menu text and full-width punctuation in shared writable
// buffers. Snapshot the original UTF-8 before the first session's init() call.
struct DefaultText {
    char *buffer;
    size_t capacity;
    std::string original;

    template <size_t N>
    DefaultText(char (&text)[N]) : buffer(text), capacity(N), original(text) {}
};

const auto &Defaults() {
    using O = Coding2UTF16;
    static const DefaultText fields[] = {
        O::space, O::minus, O::bracket, O::num_str, O::DEFAULT_START_KINSOKU,
        O::DEFAULT_END_KINSOKU, O::DEFAULT_SAVE_MENU_NAME, O::DEFAULT_LOAD_MENU_NAME,
        O::DEFAULT_SAVE_ITEM_NAME, O::MESSAGE_SAVE_EXIST, O::MESSAGE_SAVE_EMPTY,
        O::MESSAGE_SAVE_CONFIRM, O::MESSAGE_LOAD_CONFIRM, O::MESSAGE_RESET_CONFIRM,
        O::MESSAGE_END_CONFIRM, O::MESSAGE_YES, O::MESSAGE_NO, O::MESSAGE_OK, O::MESSAGE_CANCEL
    };
    return fields;
}

class WordConverter {
public:
    WordConverter(const char *to, const char *from) : converter_(iconv_open(to, from)) {
        if(converter_ == (iconv_t)-1)
            throw std::runtime_error(std::string("ONScripter cannot convert ") + from + " to " + to);
    }
    ~WordConverter() { iconv_close(converter_); }
    WordConverter(const WordConverter &) = delete;
    WordConverter &operator=(const WordConverter &) = delete;

    uint16_t Convert(uint16_t value, uint16_t fallback) const {
        char input[] = {static_cast<char>(value >> 8), static_cast<char>(value)};
        char output[2];
        char *in = input, *out = output;
        size_t left = sizeof(input), room = sizeof(output);
        std::lock_guard<std::mutex> lock(mutex_);
        if(iconv(converter_, &in, &left, &out, &room) == static_cast<size_t>(-1) || left || room)
            return fallback;
        return (uint16_t(static_cast<uint8_t>(output[0])) << 8) | static_cast<uint8_t>(output[1]);
    }
private:
    iconv_t converter_;
    mutable std::mutex mutex_;
};

class LegacyEncoding final : public Coding2UTF16 {
public:
    explicit LegacyEncoding(const char *name) : decode_("UTF-16BE", name), encode_(name, "UTF-16BE") {}
    uint16_t conv2UTF16(uint16_t value) const override {
        return value < 0x80 ? value : decode_.Convert(value, 0xfffd);
    }
    uint16_t convUTF162Coding(uint16_t value) const override {
        return value < 0x80 ? value : encode_.Convert(value, 0);
    }
    void init() override {
        for(const auto &field : Defaults()) {
            // getStringFromInteger indexes two bytes per digit in legacy mode.
            const char *source = field.buffer == num_str ? "０１２３４５６７８９" : field.original.c_str();
            std::string encoded;
            while(*source) {
                const auto code = convUTF162Coding(convUTF8ToUTF16(&source));
                if(code > 0xff) encoded.push_back(static_cast<char>(code >> 8));
                encoded.push_back(code ? static_cast<char>(code) : '?');
            }
            if(encoded.size() >= field.capacity) throw std::runtime_error("ONScripter default text exceeds its buffer");
            std::memcpy(field.buffer, encoded.c_str(), encoded.size() + 1);
        }
    }
private:
    WordConverter decode_, encode_;
};
} // namespace

std::unique_ptr<Coding2UTF16> MakeOnsEncoding(const std::string &name) {
    // GBK and SJIS init() replace these fields. UTF-8 relies on their originals.
    for(const auto &field : Defaults())
        std::memcpy(field.buffer, field.original.c_str(), field.original.size() + 1);
    if(name == "big5" || name == "cp950") return std::make_unique<LegacyEncoding>("CP950");
    if(name == "cp949") return std::make_unique<LegacyEncoding>("CP949");
    if(name == "sjis" || name == "shift-jis" || name == "shift_jis" || name == "cp932")
        return std::make_unique<SJIS2UTF16>();
    auto converter = std::make_unique<GBK2UTF16>();
    converter->force_utf8 = name == "utf8" || name == "utf-8";
    return converter;
}
