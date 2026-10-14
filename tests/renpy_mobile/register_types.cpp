#include "renpy_native.h"
#include <godot_cpp/godot.hpp>
#include <godot_cpp/core/defs.hpp>
using namespace godot;
static void initialize(ModuleInitializationLevel level) {
    if (level == MODULE_INITIALIZATION_LEVEL_SCENE) RegisterAetherRenpyNativePlayer();
}
static void terminate(ModuleInitializationLevel) {}
extern "C" GDExtensionBool GDE_EXPORT renpy_probe_init(GDExtensionInterfaceGetProcAddress proc,
    GDExtensionClassLibraryPtr library, GDExtensionInitialization *initialization) {
    GDExtensionBinding::InitObject init(proc, library, initialization);
    init.register_initializer(initialize);
    init.register_terminator(terminate);
    init.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
    return init.init();
}
