// SDL 2.0.20's documented dynamic API keeps the SDK's real pygame Window and
// GL context intact while Aether adopts its native view. No visible SDL window
// is created. These append-only ABI slots are from SDL_dynapi_procs.h 2.0.20.
#include <cstdint>
#include <cstdlib>
#include <dlfcn.h>

static void *owned;
static void *owned_context;
static void *(*real_create)(const char *, int, int, int, int, uint32_t);
static void *(*real_context)(void *);
static void (*real_show)(void *);
static void (*real_destroy)(void *);
static uint32_t (*real_flags)(void *);
static void *(*real_focus)();
static void (*real_set_size)(void *, int, int);
static void (*real_raise)(void *);
static int (*real_fullscreen)(void *, uint32_t);
static int (*real_make_current)(void *, void *);
static void (*real_delete_context)(void *);
#if defined(__APPLE__)
static void pump_events() {
} // Aether's AppKit loop and input bridge own events.
#endif
static int viewport_width = 960, viewport_height = 540;
static bool installed;

static void *create(const char *title, int x, int y, int width, int height,
                    uint32_t flags) {
    owned = real_create(title, x, y, viewport_width, viewport_height,
                        (flags & ~0x1001u) | 8u); // SDL_WINDOW_HIDDEN
    return owned;
}
static void *context(void *window) {
    void *value = real_context(window);
    if(value && window == owned) {
        owned_context = value;
        const char *address = getenv("AETHER_RENPY_NATIVE_ADOPT");
        auto adopt = address
            ? reinterpret_cast<void (*)(void *)>(strtoull(address, nullptr, 10))
            : nullptr;
        if(adopt)
            adopt(window);
    }
    return value;
}
static void show(void *window) {
    if(window != owned)
        real_show(window);
}
static void raise_window(void *window) {
    if(window != owned)
        real_raise(window);
}
static int fullscreen(void *window, uint32_t flags) {
    return window == owned ? 0 : real_fullscreen(window, flags);
}
static void destroy(void *window) {
    if(window == owned) {
        owned = nullptr;
        owned_context = nullptr;
    }
    real_destroy(window);
}
static void delete_context(void *context) {
    if(context == owned_context)
        owned_context = nullptr;
    real_delete_context(context);
}
static uint32_t flags(void *window) {
    uint32_t value = real_flags(window);
    return window == owned ? (value | 4 | 0x200 | 0x400) & ~8 : value;
}
static void *focus() { return owned ? owned : real_focus(); }
extern "C" __attribute__((visibility("default"))) void
aether_renpy_sdl_bounds(int width, int height) {
    if(width <= 0 || height <= 0 ||
       (width == viewport_width && height == viewport_height))
        return;
    viewport_width = width;
    viewport_height = height;
    if(owned && real_set_size)
        real_set_size(owned, width, height);
}
extern "C" __attribute__((visibility("default"))) bool
aether_renpy_sdl_hook_installed() {
    return installed;
}
extern "C" __attribute__((visibility("default"))) void
aether_renpy_sdl_activate() {
    if(owned && owned_context && real_make_current) {
        // SDL caches the current context in TLS. Aether restores its context
        // through the native API between ticks, so invalidate that cache first.
        real_make_current(nullptr, nullptr);
        real_make_current(owned, owned_context);
    }
}

extern "C" __attribute__((visibility("default"))) int32_t
SDL_DYNAPI_entry(uint32_t version, void *table, uint32_t size) {
    const char *path = getenv("AETHER_RENPY_NATIVE_LIBRARY");
    void *library = path ? dlopen(path, RTLD_NOW | RTLD_NOLOAD) : nullptr;
    if(!library || version != 1 || size < 524 * sizeof(void *))
        return -1;
    auto original = reinterpret_cast<int32_t (*)(uint32_t, void *, uint32_t)>(
        dlsym(library, "SDL_DYNAPI_entry"));
    if(!original || original(version, table, size))
        return -1;
    auto slots = static_cast<void **>(table);
#if defined(__APPLE__)
    // SDL_PumpEvents is slot 75 in the macOS 2.0.20 ABI.
    slots[75] = reinterpret_cast<void *>(pump_events);
#endif
    real_create = reinterpret_cast<decltype(real_create)>(slots[470]);
    slots[470] = reinterpret_cast<void *>(create);
    real_context = reinterpret_cast<decltype(real_context)>(slots[515]);
    slots[515] = reinterpret_cast<void *>(context);
    real_make_current =
        reinterpret_cast<decltype(real_make_current)>(slots[516]);
    real_delete_context =
        reinterpret_cast<decltype(real_delete_context)>(slots[523]);
    slots[523] = reinterpret_cast<void *>(delete_context);
    real_show = reinterpret_cast<decltype(real_show)>(slots[489]);
    slots[489] = reinterpret_cast<void *>(show);
    real_raise = reinterpret_cast<decltype(real_raise)>(slots[491]);
    slots[491] = reinterpret_cast<void *>(raise_window);
    real_fullscreen = reinterpret_cast<decltype(real_fullscreen)>(slots[495]);
    slots[495] = reinterpret_cast<void *>(fullscreen);
    real_flags = reinterpret_cast<decltype(real_flags)>(slots[474]);
    slots[474] = reinterpret_cast<void *>(flags);
    real_focus = reinterpret_cast<decltype(real_focus)>(slots[175]);
    slots[175] = reinterpret_cast<void *>(focus);
    real_destroy = reinterpret_cast<decltype(real_destroy)>(slots[505]);
    slots[505] = reinterpret_cast<void *>(destroy);
    real_set_size = reinterpret_cast<decltype(real_set_size)>(slots[482]);
    installed = true;
    return 0;
}
