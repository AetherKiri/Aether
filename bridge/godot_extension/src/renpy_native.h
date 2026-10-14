#pragma once
#include <cstdint>
namespace godot {
    void RegisterAetherRenpyNativePlayer();
}
extern "C" {
void *aether_renpy_native_open(uint64_t window, const char *sdk,
                               const char *manifest, const char *bootstrap,
                               const char *greenlet, char **error);
bool aether_renpy_native_step(void *handle);
void aether_renpy_native_close(void *handle);
void aether_renpy_native_pause(void *handle, bool paused);
void aether_renpy_native_input(void *handle, const char *event);
bool aether_renpy_native_is_embedded(void *handle);
void aether_renpy_native_rect(void *handle, double x, double y, double width,
                              double height);
}
