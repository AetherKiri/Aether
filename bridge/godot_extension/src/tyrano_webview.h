#pragma once
#include <cstdint>

// Apple calls are marshalled to the UI thread. Pass WINDOW_VIEW (UIView) on
// iOS, WINDOW_HANDLE (NSWindow) on macOS. Rectangles use normalized Godot
// viewport coordinates so backing scale and content stretch stay aligned.
extern "C" {
void *aether_tyrano_open(uint64_t window, const char *entry, const char *storage, char **error);
void aether_tyrano_close(void *handle);
void aether_tyrano_rect(void *handle, double x, double y, double width, double height);
void aether_tyrano_pause(void *handle, bool paused);
void aether_tyrano_controls(void *handle, const char *frame_json);
void aether_tyrano_input(void *handle, const char *event_json);
void aether_tyrano_evaluate(void *handle, const char *script);
char *aether_tyrano_poll(void *handle);
void aether_tyrano_free_string(char *value);
}
