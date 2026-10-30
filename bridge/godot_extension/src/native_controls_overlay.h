#pragma once
#include <cstdint>
#include <cstddef>

namespace godot { void RegisterAetherNativeControls(); }

#ifdef __APPLE__
void *aether_controls_open(uint64_t window);
void aether_controls_present(void *handle, const uint8_t *rgba, int width, int height,
    const char *regions_json);
void aether_controls_rect(void *handle, double x, double y, double width, double height);
void aether_controls_visible(void *handle, bool visible);
void aether_controls_close(void *handle);
#endif
