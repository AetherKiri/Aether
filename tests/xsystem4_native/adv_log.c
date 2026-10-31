#include "AnteaterADVEngine.h"
#include "system4/ain.h"
#include "system4/string.h"
#include "vm.h"
#include "vm/page.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern struct static_library lib_AnteaterADVEngine;
extern void xsystem4_libraries_destroy(void);

static void require(bool condition, const char *message) {
    if(!condition) {
        fprintf(stderr, "XSYSTEM4_ADV_LOG_FAILED: %s\n", message);
        exit(EXIT_FAILURE);
    }
}

static void *exported_function(const char *name) {
    for(struct static_hll_function *f = lib_AnteaterADVEngine.functions;
        f->name; ++f)
        if(!strcmp(f->name, name))
            return f->fun;
    require(false, "Missing Anteater export");
    return NULL;
}

static void signature(struct ain_hll_function *f, const char *name,
                      enum ain_data_type result, int count,
                      const enum ain_data_type *arguments) {
    f->name = strdup(name);
    f->return_type.data = result;
    f->nr_arguments = count;
    f->arguments = calloc(count, sizeof(*f->arguments));
    require(f->name && f->arguments, "Signature allocation failed");
    for(int i = 0; i < count; ++i) {
        f->arguments[i].name = strdup("arg");
        f->arguments[i].type.data = arguments[i];
    }
}

static void check_session(bool named) {
    ain = ain_new(6, 0);
    const int libno = ain_add_library(ain, "AnteaterADVEngine");
    struct ain_library *lib = &ain->libraries[libno];
    lib->nr_functions = 3;
    lib->functions = calloc(lib->nr_functions, sizeof(*lib->functions));
    require(lib->functions != NULL, "Library allocation failed");
    const enum ain_data_type text_args[] = {named ? AIN_STRING : AIN_REF_STRING, AIN_INT};
    const enum ain_data_type voice_args[] = {named ? AIN_STRING : AIN_INT};
    const enum ain_data_type get_args[] = {AIN_INT, AIN_INT, AIN_REF_STRING};
    signature(&lib->functions[0], "ADVLogList_AddText", AIN_VOID,
              named ? 2 : 1, text_args);
    signature(&lib->functions[1], "ADVLogList_AddVoice", AIN_VOID, 1, voice_args);
    signature(&lib->functions[2], "ADVLogList_GetADVLogVoice",
              named ? AIN_VOID : AIN_INT, named ? 3 : 2, get_args);
    init_libraries();

    struct string *text = make_string("dialogue", 8);
    struct string *voice = make_string("voice_001.ogg", 13);
    if(named) {
        ((void (*)(struct string *, int))exported_function("ADVLogList_AddText"))(text, 0);
        ((void (*)(struct string *))exported_function("ADVLogList_AddVoice"))(voice);
    } else {
        ((void (*)(struct string **))exported_function("ADVLogList_AddText"))(&text);
        ((void (*)(int))exported_function("ADVLogList_AddVoice"))(123);
    }
    free_string(text);
    free_string(voice);

    struct page *saved = NULL;
    printf("Saving %s voice log\n", named ? "named" : "numeric");
    fflush(stdout);
    require(ADVLogList_Save(&saved), "Log save failed");
    ADVLogList_Clear();
    require(ADVLogList_Load(&saved), "Log load failed");
    // Loading a log prepends a blank page, as required by the engine API.
    require(ADVLogList_GetNumofADVLogVoice(1) == 1, "Voice count changed");
    struct string *restored = NULL;
    ADVLogList_GetADVLogText(1, 0, &restored);
    require(restored && !strcmp(restored->text, "dialogue"), "Dialogue changed");
    free_string(restored);
    if(named) {
        restored = NULL;
        ((void (*)(int, int, struct string **))exported_function("ADVLogList_GetADVLogVoice"))(1, 0, &restored);
        require(restored && !strcmp(restored->text, "voice_001.ogg"), "Voice name changed");
        free_string(restored);
    } else {
        require(((int (*)(int, int))exported_function("ADVLogList_GetADVLogVoice"))(1, 0) == 123,
                "Numeric voice changed after a named-voice session");
    }
    free_page(saved);
    exit_libraries();
    xsystem4_libraries_destroy();
    ain_free(ain);
    ain = NULL;
}

int main(void) {
    check_session(false);
    check_session(true);
    check_session(true);
    check_session(false);
    check_session(true);
    check_session(false);
    puts("XSYSTEM4_ADV_LOG_OK");
    return 0;
}
