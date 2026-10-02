#include "renpy_runtime.h"
#include "engine_runtime_provider.h"

#include <cstring>
#include <memory>
#include <mutex>
#include <string>

// This translation unit is selected only for IOS/ANDROID by CMake.  Keep a
// compile-time guard here as well so a future source-list change cannot turn
// the mobile placeholder into an accidental desktop build.
#if !defined(__ANDROID__) && !defined(__APPLE__)
#error "Ren'Py mobile provider must only be compiled for Android or Apple"
#endif

namespace aetherkiri::renpy {
namespace {

struct MobileRuntime final {
    engine_runtime_host_v1_t host{};
    std::string error =
        "Ren'Py mobile bootstrap is not available; stage official RAPT/Renios "
        "inputs before enabling the native adapter";
};

MobileRuntime* Cast(void* value) {
    return static_cast<MobileRuntime*>(value);
}

int32_t Probe(void*, const char*) {
    // A zero score prevents the host from auto-selecting a provider that
    // cannot execute a game.  Explicit runtime=renpy still reaches Open and
    // gets the same deterministic NOT_SUPPORTED result below.
    return 0;
}

engine_result_t Create(void*, const engine_runtime_host_v1_t* host,
                       const engine_create_desc_t* desc, void** output) {
    if (!host || !desc || !output || host->struct_size < sizeof(*host) ||
        desc->struct_size < sizeof(*desc)) {
        return ENGINE_RESULT_INVALID_ARGUMENT;
    }
    *output = nullptr;
    try {
        auto runtime = std::make_unique<MobileRuntime>();
        runtime->host = *host;
        *output = runtime.release();
        return ENGINE_RESULT_OK;
    } catch (...) {
        return ENGINE_RESULT_INTERNAL_ERROR;
    }
}

void Destroy(void* value) {
    delete Cast(value);
}

engine_result_t Open(void* value, const char*, const char*) {
    if (!value) return ENGINE_RESULT_INVALID_ARGUMENT;
    Cast(value)->error =
        "Ren'Py mobile runtime is not playable yet: native RAPT/Renios "
        "bootstrap, lifecycle, input, and surface rendering adapters are "
        "required";
    return ENGINE_RESULT_NOT_SUPPORTED;
}

engine_result_t Unsupported(void* value) {
    if (!value) return ENGINE_RESULT_INVALID_ARGUMENT;
    Cast(value)->error =
        "Ren'Py mobile runtime is not available until the native adapter is "
        "implemented";
    return ENGINE_RESULT_NOT_SUPPORTED;
}

engine_result_t UnsupportedTick(void* value, uint32_t) {
    return Unsupported(value);
}

engine_result_t UnsupportedOption(void* value, const engine_option_t* option) {
    if (!value || !option || !option->key_utf8 || !option->value_utf8) {
        return ENGINE_RESULT_INVALID_ARGUMENT;
    }
    return Unsupported(value);
}

engine_result_t UnsupportedResize(void* value, uint32_t, uint32_t) {
    return Unsupported(value);
}

engine_result_t UnsupportedFrame(void* value, engine_frame_desc_t*) {
    return Unsupported(value);
}

engine_result_t UnsupportedRead(void* value, void*, size_t) {
    return Unsupported(value);
}

engine_result_t UnsupportedNativeFrame(void* value, uint64_t*, uint32_t*,
                                        uint32_t*, uint64_t*) {
    return Unsupported(value);
}

engine_result_t UnsupportedInput(void* value, const engine_input_event_t*) {
    return Unsupported(value);
}

engine_result_t UnsupportedRendered(void* value, uint32_t*) {
    return Unsupported(value);
}

engine_result_t Renderer(void* value, char* buffer, uint32_t size) {
    if (!value || !buffer || size == 0) return ENGINE_RESULT_INVALID_ARGUMENT;
    constexpr char kRenderer[] =
        "Ren'Py mobile stub (official RAPT/Renios staged; bootstrap unavailable)";
    constexpr uint32_t kRequired = sizeof(kRenderer);
    if (size < kRequired) {
        Cast(value)->error = "Ren'Py mobile renderer description buffer is too small";
        return ENGINE_RESULT_INVALID_ARGUMENT;
    }
    std::memcpy(buffer, kRenderer, kRequired);
    return ENGINE_RESULT_OK;
}

engine_result_t TextInput(void* value, uint32_t*) {
    return Unsupported(value);
}

const char* Error(void* value) {
    return value ? Cast(value)->error.c_str()
                 : "Invalid Ren'Py mobile runtime";
}

const engine_runtime_provider_v1_t& Provider() {
    static const engine_runtime_provider_v1_t provider = [] {
        engine_runtime_provider_v1_t p{};
        p.struct_size = sizeof(p);
        p.api_version = ENGINE_RUNTIME_PROVIDER_API_VERSION;
        p.runtime_id_utf8 = "renpy";
        p.display_name_utf8 = "Ren'Py (mobile bootstrap unavailable)";
        p.priority = 60;
        p.probe = Probe;
        p.create = Create;
        p.destroy = Destroy;
        p.open_game = Open;
        p.tick = UnsupportedTick;
        p.pause = Unsupported;
        p.resume = Unsupported;
        p.set_option = UnsupportedOption;
        p.set_surface_size = UnsupportedResize;
        p.get_frame_desc = UnsupportedFrame;
        p.read_frame_rgba = UnsupportedRead;
        p.get_godot_native_frame_texture = UnsupportedNativeFrame;
        p.send_input = UnsupportedInput;
        p.get_frame_rendered_flag = UnsupportedRendered;
        p.get_renderer_info = Renderer;
        p.get_text_input_state = TextInput;
        p.get_last_error = Error;
        return p;
    }();
    return provider;
}

}  // namespace

void RegisterRuntimeProvider() {
    static std::once_flag once;
    std::call_once(once, [] { engine_register_runtime_provider(&Provider()); });
}

}  // namespace aetherkiri::renpy
