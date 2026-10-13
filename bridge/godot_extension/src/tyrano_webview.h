#pragma once
#include <cstdint>

// All calls are made on the application/UI thread. Rectangles use normalized
// Godot viewport coordinates so backing scale and content stretch stay aligned.
extern "C" {
void *aether_tyrano_open(uint64_t window, const char *entry, const char *storage, char **error);
void aether_tyrano_close(void *handle);
void aether_tyrano_rect(void *handle, double x, double y, double width, double height);
void aether_tyrano_pause(void *handle, bool paused);
void aether_tyrano_controls(void *handle, bool visible);
void aether_tyrano_evaluate(void *handle, const char *script);
char *aether_tyrano_poll(void *handle);
void aether_tyrano_free_string(char *value);
}
