#include "utfsjis.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define REQUIRE(expr)                                                          \
    do {                                                                       \
        if(!(expr)) {                                                          \
            fprintf(stderr, "Failed: %s\n", #expr);                            \
            return 1;                                                          \
        }                                                                      \
    } while(0)

int main(void) {
    const char *gbk = "\xd6\xd0\xce\xc4\xb2\xe2\xca\xd4";
    char *utf8 = codeconv(UTF8, GBK, gbk);
    REQUIRE(utf8 && !strcmp(utf8, "中文测试"));
    char *back = codeconv(GBK, UTF8, utf8);
    REQUIRE(back && !strcmp(back, gbk));
    free(utf8);
    free(back);

    const char *sjis = "\x83\x65\x83\x58\x83\x67";
    utf8 = codeconv(UTF8, SHIFT_JIS, sjis);
    REQUIRE(utf8 && !strcmp(utf8, "テスト"));
    free(utf8);
    const char *trail_opcode = "\x81\x7e@";
    REQUIRE(advance_char(trail_opcode, GBK) == trail_opcode + 2);
    REQUIRE(*advance_char(trail_opcode, GBK) == '@');
    const char *halfwidth_range = "\xa3\xe5@";
    REQUIRE(advance_char(halfwidth_range, GBK) == halfwidth_range + 2);
    REQUIRE(advance_char(halfwidth_range, SHIFT_JIS) == halfwidth_range + 1);
    const char *truncated = "\x81";
    REQUIRE(advance_char(truncated, GBK) == truncated + 1);
    utf8 = codeconv(UTF8, GBK, truncated);
    REQUIRE(utf8 && !strcmp(utf8, "?"));
    free(utf8);
    const char *unicode = "中文";
    REQUIRE(advance_char(unicode, UTF8) == unicode + 3);
    REQUIRE(MAX_BYTES_PAR_CHAR(GBK) == 2);
    puts("XSYSTEM35_ENCODING_OK");
    return 0;
}
