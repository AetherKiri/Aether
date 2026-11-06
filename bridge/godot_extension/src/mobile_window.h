#pragma once
#include <cstdint>

namespace godot { void RegisterAetherMobileWindow(); }

// UIKit work is marshalled to the main thread by the implementation.
void *aether_mobile_window_open(uint64_t native_view);
void aether_mobile_window_configure(void *handle, bool game_active, bool pip_enabled);
bool aether_mobile_window_supported(void *handle);
bool aether_mobile_window_in_pip(void *handle);
void aether_mobile_window_close(void *handle);
