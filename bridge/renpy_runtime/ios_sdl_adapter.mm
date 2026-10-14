// Linked inside the isolated Ren'Py framework, never into Godot's SDL.
// The build tool renames these entry points in the supplied SDL archive to
// RNP_*. pygame keeps the SDK's real SDL_Window and native GL context.
#include <cstdint>
#include <dlfcn.h>
extern "C" {
void *RNP_CreateWindow(const char *, int, int, int, int, uint32_t);
void *RNP_GL_CreateContext(void *);
void RNP_DestroyWindow(void *);
uint32_t RNP_GetWindowFlags(void *);
void RNP_GetWindowSize(void *, int *, int *);
void *RNP_GetKeyboardFocus();
void RNP_SetWindowSize(void *, int, int);
int RNP_SetWindowFullscreen(void *, uint32_t);
void SDL_SetMainReady();
void SDL_iPhoneSetEventPump(int);
void init_librenpy();
int PyImport_AppendInittab(const char *, void *(*)());
void *PyInit__greenlet();
}
static void *owned;
static void (*adopt_view)(void *);
static int viewport_width = 960, viewport_height = 540;

extern "C" __attribute__((visibility("default"))) void aether_renpy_ios_adapter(void (*adopt)(void *), int width, int height) {
    adopt_view = adopt;
    viewport_width = width;
    viewport_height = height;
}
extern "C" __attribute__((visibility("default"))) void aether_renpy_runtime_init() {
    SDL_SetMainReady();
    // Aether owns UIApplication's run loop. Pumping it again from Python can
    // re-enter CADisplayLink/Godot while a Ren'Py frame is still on the stack.
    SDL_iPhoneSetEventPump(0);
    init_librenpy();
    PyImport_AppendInittab("greenlet._greenlet", PyInit__greenlet);
}
extern "C" void *SDL_CreateWindow(const char *title, int x, int y, int, int, uint32_t flags) {
    owned = RNP_CreateWindow(title, x, y, viewport_width, viewport_height, (flags & ~0x1001u) | 8u);
    return owned;
}
extern "C" void *SDL_GL_CreateContext(void *window) {
    void *context = RNP_GL_CreateContext(window);
    if (context && window == owned && adopt_view) adopt_view(window);
    return context;
}
extern "C" void SDL_ShowWindow(void *) {}
extern "C" void SDL_RaiseWindow(void *) {}
extern "C" void *SDL_GL_GetProcAddress(const char *name) {
    // UIKit's stock SDL resolver searches RTLD_DEFAULT, which can select
    // Apple's OpenGLES functions while the SDK owns a MetalANGLE context.
    // Resolve against the framework that implements this context instead.
    static void *angle = dlopen("@rpath/MetalANGLE.framework/MetalANGLE", RTLD_NOW | RTLD_LOCAL);
    return angle ? dlsym(angle, name) : nullptr;
}
extern "C" void SDL_DestroyWindow(void *window) {
    if (window == owned) owned = nullptr;
    RNP_DestroyWindow(window);
}
extern "C" uint32_t SDL_GetWindowFlags(void *window) {
    uint32_t value = RNP_GetWindowFlags(window);
    return window == owned ? (value | 4u | 0x200u | 0x400u) & ~(8u | 0x1001u) : value;
}
extern "C" void *SDL_GetKeyboardFocus() { return owned ? owned : RNP_GetKeyboardFocus(); }
extern "C" void SDL_GetWindowSize(void *window, int *width, int *height) {
    if (window != owned) { RNP_GetWindowSize(window, width, height); return; }
    if (width) *width = viewport_width;
    if (height) *height = viewport_height;
}
extern "C" void SDL_SetWindowSize(void *window, int width, int height) {
    if (window != owned) RNP_SetWindowSize(window, width, height);
}
extern "C" int SDL_SetWindowFullscreen(void *window, uint32_t flags) {
    return window == owned ? 0 : RNP_SetWindowFullscreen(window, flags);
}
