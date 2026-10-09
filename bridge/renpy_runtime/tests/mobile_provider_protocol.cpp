#include "renpy_runtime.h"
#include "engine_runtime_provider.h"
#include "renpy_mobile_launcher.h"
#include "renpy_godot_input.h"

#include <cassert>
#include <cmath>
#include <cstring>
#include <string>
#include <utility>
#include <vector>

namespace {
const engine_runtime_provider_v1_t* provider;
const renpy_mobile_host_t* callbacks;
int starts;
bool finish;
bool push_frame = true;
renpy_mobile_input_t last_input{};
std::string last_text;
struct InputRecord {
    renpy_mobile_input_t input;
    std::string text;
};
std::vector<InputRecord> inputs;
struct LogEntry {
    uint32_t level;
    std::string subsystem;
    std::string message;
    bool during_shutdown;
};
std::vector<LogEntry> host_logs;
bool shutting_down;
void HostLog(void* user_data, uint32_t level, const char* subsystem, const char* message) {
    assert(user_data == &host_logs);
    host_logs.push_back({level, subsystem, message, shutting_down});
}
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
    inputs.push_back({last_input, last_text});
    inputs.back().input.text_utf8 = nullptr;
    return 0;
}
extern "C" int renpy_mobile_pause() { return 0; }
extern "C" int renpy_mobile_resume() { return 0; }
extern "C" int renpy_mobile_bind_window(void*) { return 0; }
extern "C" int renpy_mobile_text_input_state(uint32_t* active) { *active = 1; return 0; }
extern "C" int renpy_mobile_set_surface_size(uint32_t, uint32_t) { return 0; }
extern "C" void renpy_mobile_shutdown() {
    assert(callbacks);
    shutting_down = true;
    callbacks->log_utf8(callbacks->user_data, 3,
        "Ren'Py terminal cleanup failed; retained runtime resources require a host application restart");
    shutting_down = false;
    callbacks = nullptr;
}

int main() {
    aetherkiri::renpy::RegisterRuntimeProvider();
    assert(provider && provider->probe(nullptr, nullptr) == 0);
    assert(provider->probe(nullptr, "/not-a-renpy-project") == 0);
    engine_runtime_host_v1_t host{};
    host.struct_size = sizeof(host);
    host.log = HostLog;
    host.user_data = &host_logs;
    engine_create_desc_t desc{};
    desc.struct_size = sizeof(desc);
    void* runtime = nullptr;
    assert(provider->create(nullptr, &host, &desc, &runtime) == ENGINE_RESULT_OK);
    char project[] = "/project";
    assert(provider->open_game(runtime, project, nullptr) == ENGINE_RESULT_OK);
    std::memset(project, 'x', sizeof(project) - 1);
    assert(starts == 0); // async Open cannot bind Python/greenlet to its thread.
    assert(provider->tick(runtime, 16) == ENGINE_RESULT_OK && starts == 1);
    callbacks->log_utf8(callbacks->user_data, 0, "native trace");
    callbacks->log_utf8(callbacks->user_data, 1, "native info");
    callbacks->log_utf8(callbacks->user_data, 2, "native warning");
    callbacks->log_utf8(callbacks->user_data, 3, "native error");
    assert(host_logs.size() == 4);
    assert(host_logs[0].level == ENGINE_RUNTIME_LOG_TRACE);
    assert(host_logs[1].level == ENGINE_RUNTIME_LOG_INFO);
    assert(host_logs[2].level == ENGINE_RUNTIME_LOG_WARNING);
    assert(host_logs[3].level == ENGINE_RUNTIME_LOG_ERROR);
    assert(std::strcmp(provider->get_last_error(runtime), "native error") == 0);
    for (const auto& entry : host_logs) assert(entry.subsystem == "renpy-mobile");
    callbacks->log_utf8(callbacks->user_data, 3, nullptr);
    assert(host_logs.size() == 4);
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
    // The explicit Godot namespace preserves every printable key, including
    // punctuation/lowercase values that collide with legacy Windows VKs.
    namespace mapping = aetherkiri::renpy::input_mapping;
    std::vector<engine_input_event_t> raw_events;
    auto send_godot = [&](bool pressed, int code, int modifiers, uint32_t unicode) {
        return mapping::SendGodotKeyEvents([&](const engine_input_event_t& input) {
            raw_events.push_back(input);
            return provider->send_input(runtime, &input);
        }, pressed, code, modifiers, unicode);
    };
    for (int code = 32; code <= 126; ++code) {
        const size_t before = inputs.size();
        assert(send_godot(true, code, 0, code) == ENGINE_RESULT_OK);
        assert(inputs.size() == before + 2);
        const auto& key = inputs[before].input;
        assert(key.type == RENPY_MOBILE_INPUT_KEY && key.value == ENGINE_INPUT_EVENT_KEY_DOWN);
        assert(key.code == (code >= 'A' && code <= 'Z' ? code + 'a' - 'A' : code));
        assert(inputs[before + 1].input.type == RENPY_MOBILE_INPUT_TEXT);
        assert(inputs[before + 1].text == std::string(1, static_cast<char>(code)));
        assert(raw_events[raw_events.size() - 2].unicode_codepoint == 0);
        assert(raw_events[raw_events.size() - 2].reserved_u32 ==
               static_cast<uint32_t>(mapping::KeyCodeSpace::Godot));
        assert(raw_events.back().reserved_u32 == 0 && raw_events.back().key_code == 0);
        const size_t release_before = inputs.size();
        assert(send_godot(false, code, 0, code) == ENGINE_RESULT_OK);
        assert(inputs.size() == release_before + 1 && last_input.value == ENGINE_INPUT_EVENT_KEY_UP);
    }
    const std::pair<int, int> special_keys[] = {
        {1, 27}, {2, 9}, {3, 9}, {4, 8}, {5, 13},
        {6, mapping::kPygameScancodeMask + 88}, {7, mapping::kPygameScancodeMask + 73},
        {8, 127}, {13, mapping::kPygameScancodeMask + 74},
        {14, mapping::kPygameScancodeMask + 77}, {15, mapping::kPygameScancodeMask + 80},
        {16, mapping::kPygameScancodeMask + 82}, {17, mapping::kPygameScancodeMask + 79},
        {18, mapping::kPygameScancodeMask + 81}, {19, mapping::kPygameScancodeMask + 75},
        {20, mapping::kPygameScancodeMask + 78}, {28, mapping::PygameFunctionKey(1)},
        {51, mapping::PygameFunctionKey(24)}, {132, mapping::kPygameScancodeMask + 99},
    };
    for (const auto& [code, expected] : special_keys) {
        const size_t before = inputs.size();
        // Even a platform newline accompanying Enter is a key command only.
        assert(send_godot(true, mapping::kGodotSpecial + code, 0,
                          code == 5 || code == 6 ? '\n' : 0) == ENGINE_RESULT_OK);
        assert(inputs.size() == before + 1 && last_input.code == expected && last_text.empty());
        assert(raw_events.back().unicode_codepoint == 0);
    }
    const size_t ctrl_before = inputs.size();
    assert(send_godot(true, 'A', mapping::kGodotModifierControl | mapping::kGodotModifierShift |
                      mapping::kAetherModifierEcho, 'A') == ENGINE_RESULT_OK);
    assert(inputs.size() == ctrl_before + 1 && last_input.code == 'a');
    assert(last_input.modifiers == 195 && last_input.repeat == 1);
    const size_t meta_before = inputs.size();
    assert(send_godot(true, 'C', mapping::kGodotModifierMeta, 'c') == ENGINE_RESULT_OK);
    assert(inputs.size() == meta_before + 1 && last_input.modifiers == mapping::kPygameKmodGui);
    const size_t shift_before = inputs.size();
    assert(send_godot(true, '.', mapping::kGodotModifierShift, '>') == ENGINE_RESULT_OK);
    assert(inputs.size() == shift_before + 2 && inputs[shift_before].input.code == '.');
    assert(inputs[shift_before].input.modifiers == mapping::kPygameKmodShift && last_text == ">");
    const size_t soft_before = inputs.size();
    assert(send_godot(true, 0, 0, 0x1f642) == ENGINE_RESULT_OK);
    assert(inputs.size() == soft_before + 1 && last_input.type == RENPY_MOBILE_INPUT_TEXT);
    assert(last_text == "\xf0\x9f\x99\x82");
    for (uint32_t unicode : {0x4f60u, 0x1f642u}) {
        const size_t before = inputs.size();
        // Godot KEY_UNKNOWN is nonzero and remains an unknown key, not a VK.
        assert(send_godot(true, mapping::kGodotCodeMask, 0, unicode) == ENGINE_RESULT_OK);
        assert(inputs.size() == before + 2 && inputs[before].input.code == 0);
        assert(inputs.back().input.type == RENPY_MOBILE_INPUT_TEXT && !inputs.back().text.empty());
    }
    const size_t altgr_before = inputs.size();
    assert(send_godot(true, 'E', mapping::kGodotModifierControl | mapping::kGodotModifierAlt,
                      0x20ac) == ENGINE_RESULT_OK);
    assert(inputs.size() == altgr_before + 2 && last_text == "\xe2\x82\xac");
    for (uint32_t unicode : {0u, 8u, 9u, 10u, 13u, 127u, 0xd800u, 0x110000u}) {
        const size_t before = inputs.size();
        assert(send_godot(true, 0, 0, unicode) == ENGINE_RESULT_OK && inputs.size() == before);
    }
    int calls = 0;
    assert(mapping::SendGodotKeyEvents([&](const engine_input_event_t&) {
        ++calls;
        return ENGINE_RESULT_IO_ERROR;
    }, true, '.', 0, '.') == ENGINE_RESULT_IO_ERROR && calls == 1);
    // Unmarked events retain the old VK and direct SDL contracts.
    event.key_code = 0x2e;
    event.modifiers = 0;
    assert(provider->send_input(runtime, &event) == ENGINE_RESULT_OK && last_input.code == 127);
    event.key_code = 0x70;
    assert(provider->send_input(runtime, &event) == ENGINE_RESULT_OK && last_input.code == mapping::PygameFunctionKey(1));
    event.key_code = mapping::kPygameScancodeMask + 79;
    assert(provider->send_input(runtime, &event) == ENGINE_RESULT_OK && last_input.code == event.key_code);
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
    // Destroy remains void. The launcher error reaches the owned host sink
    // synchronously during shutdown and survives deletion of MobileRuntime.
    assert(host_logs.size() == 5 && host_logs.back().during_shutdown);
    assert(host_logs.back().level == ENGINE_RUNTIME_LOG_ERROR);
    assert(host_logs.back().subsystem == "renpy-mobile");
    assert(host_logs.back().message.find("terminal cleanup failed") != std::string::npos);
}
