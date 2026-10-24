#include "AnteaterADVEngine.h"
#include "system4/ain.h"
#include "system4/utfsjis.h"
#include "vm/page.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char sjis_name[] = "\x89\xe6\x96\xca\x95\xdb\x8a\xc7_t";
static const char gbk_name[] = "\xbb\xad\xc3\xe6\xb1\xa3\xb9\xdc_t";

static void require(bool condition, const char *message) {
    if(!condition) {
        fprintf(stderr, "XSYSTEM4_SCENE_KEEPER_FAILED: %s\n", message);
        exit(EXIT_FAILURE);
    }
}

static void fatal_error(const char *message) { require(false, message); }

static void check_scene(bool chinese, const char *name, int padding,
                        bool include_japanese) {
    use_gbk = chinese;
    ain = ain_new(6, 0);
    // Keep the VM's error diagnostics valid without executing a script.
    ain->code = calloc(2, 1);
    require(ain->code != NULL, "Code allocation failed");
    ain->code_size = 2;
    for(int i = 0; i < padding; i++) {
        char unused[32];
        snprintf(unused, sizeof(unused), "Unused%d", i);
        ain_add_struct(ain, unused);
    }
    if(include_japanese)
        ain_add_struct(ain, sjis_name);
    const int index = ain_add_struct(ain, name);
    struct ain_struct *structure = &ain->structures[index];
    structure->nr_members = 1;
    structure->members = calloc(1, sizeof(*structure->members));
    require(structure->members != NULL, "Member allocation failed");
    structure->members[0].name = strdup("value");
    structure->members[0].type.data = AIN_INT;

    struct page *scene = alloc_page(STRUCT_PAGE, index, 1);
    scene->values[0].i = 42 + padding;
    require(ADVSceneKeeper_AddADVScene(&scene), "Scene type was not found");
    require(ADVSceneKeeper_GetNumofADVScene() == 1, "Scene was not retained");
    struct page *restored = NULL;
    require(ADVSceneKeeper_GetADVScene(0, &restored), "Scene restore failed");
    require(restored && restored->index == index && restored->nr_vars == 1 &&
                restored->values[0].i == scene->values[0].i,
            "Scene used an incorrect or stale structure definition");
    require(use_gbk == chinese, "Scene lookup changed the text encoding");
    free_page(restored);
    free_page(scene);
    ADVSceneKeeper_Clear();
    ain_free(ain);
    ain = NULL;
}

int main(void) {
    sys_error_handler = fatal_error;
    // Translated dialogue can coexist with original Japanese VM identifiers.
    check_scene(true, sjis_name, 0, false);
    // Each fresh script can assign a different index to the same structure.
    check_scene(false, sjis_name, 2, false);
    check_scene(true, gbk_name, 1, false);
    // Prefer the Chinese identifier when both encodings are present.
    check_scene(true, gbk_name, 3, true);
    check_scene(false, sjis_name, 0, false);
    puts("XSYSTEM4_SCENE_KEEPER_OK");
    return 0;
}
