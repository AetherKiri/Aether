#include "renpy_runtime.h"
#include "engine_runtime_provider.h"
#include "renpy_mobile_launcher.h"

#include <cassert>
#include <cmath>
#include <cstring>
#include <string>

namespace {
const engine_runtime_provider_v1_t* provider;
const renpy_mobile_host_t* callbacks;
int starts;
bool finish;
bool push_frame = true;
renpy_mobile_input_t last_input{};
std::string last_text;
}  // namespace

// A controlled launcher verifies the provider protocol. This is explicitly
// separate from actual Ren'Py rendering and Android/iOS acceptance.
extern "C" engine_result_t engine_register_runtime_provider(const engine_runtime_provider_v1_t* value) {
    provider = value;
    return ENGINE_RESULT_OK;
}
extern "C" int renpy_mobile_bootstrap(const renpy_mobile_config_t*, const renpy_mobile_host_t*) { return 0; }
extern "C" int renpy_mobile_init(const renpy_mobile_config_t* config, const renpy_mobile_host_t* host) {
    assert(std::strcmp(config->game_root_utf8, "/project") == 0);
    callbacks = host;
    ++starts;
    return 0;
}
extern "C" int renpy_mobile_tick(uint32_t) {
    assert(callbacks->struct_size == sizeof(*callbacks));
    if (push_frame) {
        const uint8_t pixels[] = {1, 2, 3, 255};
        assert(callbacks->present_rgba(callbacks->user_data, pixels, 1, 1, 4) == 0);
    }
    return finish ? RENPY_MOBILE_FINISHED : RENPY_MOBILE_OK;
}
extern "C" int renpy_mobile_frame(renpy_mobile_frame_t*) { return RENPY_MOBILE_INVALID_STATE; }
extern "C" int renpy_mobile_input(const renpy_mobile_input_t* input) {
    last_input = *input;
    last_text = input->text_utf8 ? input->text_utf8 : "";
    return 0;
}
extern "C" int renpy_mobile_pause() { return 0; }
extern "C" int renpy_mobile_resume() { return 0; }
extern "C" int renpy_mobile_bind_window(void*) { return 0; }
extern "C" int renpy_mobile_text_input_state(uint32_t* active) { *active = 1; return 0; }
extern "C" int renpy_mobile_set_surface_size(uint32_t, uint32_t) { return 0; }
extern "C" void renpy_mobile_shutdown() { callbacks = nullptr; }

int main() {
    aetherkiri::renpy::RegisterRuntimeProvider();
    assert(provider && provider->probe(nullptr, "/project") > 0);
    engine_runtime_host_v1_t host{};
    host.struct_size = sizeof(host);
    engine_create_desc_t desc{};
    desc.struct_size = sizeof(desc);
    void* runtime = nullptr;
    assert(provider->create(nullptr, &host, &desc, &runtime) == ENGINE_RESULT_OK);
    char project[] = "/project";
    assert(provider->open_game(runtime, project, nullptr) == ENGINE_RESULT_OK);
    std::memset(project, 'x', sizeof(project) - 1);
    assert(starts == 0); // async Open cannot bind Python/greenlet to its thread.
    assert(provider->tick(runtime, 16) == ENGINE_RESULT_OK && starts == 1);
    uint32_t rendered = 0;
    assert(provider->get_frame_rendered_flag(runtime, &rendered) == ENGINE_RESULT_OK && rendered == 1);
    uint8_t pixels[4]{};
    assert(provider->read_frame_rgba(runtime, pixels, sizeof(pixels)) == ENGINE_RESULT_OK && pixels[0] == 1);
    push_frame = false;
    assert(provider->tick(runtime, 16) == ENGINE_RESULT_OK);
    assert(provider->get_frame_rendered_flag(runtime, &rendered) == ENGINE_RESULT_OK && rendered == 0);
    engine_input_event_t event{};
    event.struct_size = sizeof(event);
    event.type = ENGINE_INPUT_EVENT_POINTER_DOWN;
    event.x = .5;
    event.y = .25;
    event.button = 1;
    assert(provider->send_input(runtime, &event) == ENGINE_RESULT_OK);
    assert(last_input.type == RENPY_MOBILE_INPUT_POINTER && last_input.value == RENPY_MOBILE_POINTER_DOWN && last_input.code == 3);
    assert(last_input.x == .5f && last_input.y == .25f);
    event.type = ENGINE_INPUT_EVENT_KEY_DOWN;
    event.key_code = 0x41;
    event.modifiers = 0x01 | 0x04 | 0x80;
    assert(provider->send_input(runtime, &event) == ENGINE_RESULT_OK);
    assert(last_input.code == 'a' && last_input.modifiers == 195 && last_input.repeat == 1);
    event.type = ENGINE_INPUT_EVENT_TEXT_INPUT;
    event.unicode_codepoint = 0x1f642;
    assert(provider->send_input(runtime, &event) == ENGINE_RESULT_OK && last_text == "\xf0\x9f\x99\x82");
    event.unicode_codepoint = 0xd800;
    assert(provider->send_input(runtime, &event) == ENGINE_RESULT_INVALID_ARGUMENT);
    event.type = ENGINE_INPUT_EVENT_POINTER_MOVE;
    event.x = std::nan("");
    assert(provider->send_input(runtime, &event) == ENGINE_RESULT_INVALID_ARGUMENT);
    uint32_t active = 0;
    assert(provider->get_text_input_state(runtime, &active) == ENGINE_RESULT_OK && active == 1);
    char debug[256]{};
    uint32_t written = 0;
    assert(provider->pause(runtime) == ENGINE_RESULT_OK);
    assert(provider->get_plugin_debug_info(runtime, debug, sizeof(debug), &written) == ENGINE_RESULT_OK);
    assert(std::strstr(debug, "\"paused\":true"));
    assert(provider->resume(runtime) == ENGINE_RESULT_OK);
    finish = true;
    assert(provider->tick(runtime, 16) == ENGINE_RESULT_INVALID_STATE);
    assert(std::strstr(provider->get_last_error(runtime), "runtime requested termination"));
    assert(provider->get_plugin_debug_info(runtime, debug, sizeof(debug), &written) == ENGINE_RESULT_OK);
    assert(std::strstr(debug, "\"exited\":true"));
    provider->destroy(runtime);
    assert(!callbacks);
}
