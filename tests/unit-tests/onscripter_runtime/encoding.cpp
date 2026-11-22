#include "onscripter_encoding.h"
#include <catch2/catch_test_macros.hpp>
#include <string>

TEST_CASE("ONScripter renders CP949 and Big5 and resets its shared defaults between games") {
    auto korean = MakeOnsEncoding("cp949");
    korean->init();
    CHECK(korean->conv2UTF16(0xc7d1) == u'한');
    CHECK(korean->conv2UTF16(0x8141) == u'갂');
    CHECK(korean->convUTF162Coding(u'갂') == 0x8141);
    CHECK(std::string(korean->num_str).substr(0, 2) == "\xa3\xb0");

    auto traditional = MakeOnsEncoding("big5");
    traditional->init();
    CHECK(traditional->conv2UTF16(0xc5e9) == u'體');
    CHECK(traditional->convUTF162Coding(u'繁') == 0xc163);
    CHECK(std::string(traditional->num_str).substr(0, 2) == "\xa2\xaf");

    auto unicode = MakeOnsEncoding("utf8");
    CHECK(unicode->force_utf8);
    CHECK(std::string(unicode->num_str) == "0123456789");
    CHECK(std::string(unicode->bracket) == "【】");
}
