#pragma once
#include <cstdint>
#include "engine_api.h"

namespace godot {
class Object;
void RegisterAetherMobileWindow();
engine_handle_t MobileWindowEngine(Object* player);
}

// UIKit work is marshalled to the main thread by the implementation.
void *aether_mobile_window_open(uint64_t native_view);
void aether_mobile_window_configure(void *handle, bool game_active, bool pip_enabled);
void aether_mobile_window_set_engine(void *handle, engine_handle_t engine);
void aether_mobile_window_detach_engine(engine_handle_t engine);
bool aether_mobile_window_handles_lifecycle(void *handle);
bool aether_mobile_window_supported(void *handle);
bool aether_mobile_window_in_pip(void *handle);
void aether_mobile_window_close(void *handle);
char *aether_ios_import_take_event();
void aether_ios_import_consume_pending();
