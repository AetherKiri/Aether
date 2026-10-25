#include "gfx/font.h"
#include "system4/utfsjis.h"
#include <stdio.h>
#include <stdlib.h>

extern struct font *font_ttf[2];
extern struct font *font_fnl[32];

static struct font_size selected;

static struct font_size *get_size(struct font *font, float size) {
    selected.font = font;
    selected.size = size;
    return &selected;
}

static void require(bool condition, const char *message) {
    if(!condition) {
        fprintf(stderr, "XSYSTEM4_FONT_FALLBACK_FAILED: %s\n", message);
        exit(EXIT_FAILURE);
    }
}

int main(void) {
    struct font gothic = { .get_size = get_size };
    struct font mincho = { .get_size = get_size };
    struct font fnl = { .get_size = get_size };
    font_ttf[FONT_GOTHIC] = &gothic;
    font_ttf[FONT_MINCHO] = &mincho;
    font_fnl[0] = &fnl;
    // An FNL selector in a translation must resolve to the Unicode CJK font.
    use_gbk = true;
    require(gfx_font_get_size(256, 28)->font == &gothic,
            "GBK dialogue selected a Shift-JIS-only bitmap font");
    require(selected.size == 28, "Fallback changed the requested font size");
    require(gfx_font_get_size(0, 24)->font == &gothic,
            "Gothic selection changed");
    require(gfx_font_get_size(1, 24)->font == &mincho,
            "Mincho selection changed");
    // Japanese games retain the authored bitmap glyphs and metrics.
    use_gbk = false;
    require(gfx_font_get_size(256, 28)->font == &fnl,
            "Japanese dialogue lost its original bitmap font");
    use_gbk = true;
    require(gfx_font_get_size(256, 28)->font == &gothic,
            "Font choice leaked across encoding changes");
    font_ttf[0] = font_ttf[1] = font_fnl[0] = NULL;
    puts("XSYSTEM4_FONT_FALLBACK_OK");
    return 0;
}
