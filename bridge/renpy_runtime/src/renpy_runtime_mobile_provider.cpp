#include "renpy_runtime.h"
#include "engine_runtime_provider.h"
#if defined(__ANDROID__)
#include "renpy_mobile_adapter.h"
#endif
#if defined(AETHERKIRI_RENPY_IOS)
#include "renpy_runtime_ios_adapter.h"
#endif

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
#if defined(__ANDROID__)
    mobile::BootstrapAdapter bootstrap;
#endif
    std::string error =
        "Ren'Py mobile runtime is not supported: official RAPT/Renios inputs "
        "may be staged, but the native adapter is not linked";
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
#if defined(__ANDROID__)
    if (value) Cast(value)->bootstrap.Stop();
#endif
    delete Cast(value);
}

engine_result_t Open(void* value, const char* game_root_path,
                     const char* startup_script) {
    if (!value) return ENGINE_RESULT_INVALID_ARGUMENT;
#if defined(__ANDROID__)
    auto* runtime = Cast(value);
    mobile::BootstrapRequest request{};
    request.game_root_path_utf8 = game_root_path;
    request.startup_script_utf8 = startup_script;
    // reserved_ptr[1] is intentionally host-owned.  The current Godot
    // Android host does not populate it, so the adapter returns
    // NOT_SUPPORTED rather than constructing a second Activity.
    request.existing_host_activity = runtime->host.reserved_ptr[1];
    const auto result = runtime->bootstrap.Start(request);
    runtime->error = runtime->bootstrap.last_error();
    return result;
#elif defined(AETHERKIRI_RENPY_IOS)
    (void)game_root_path;
    (void)startup_script;
    const auto* contract = renpy_get_ios_launcher_contract();
    if (renpy_get_ios_inprocess_adapter() == nullptr) {
        Cast(value)->error =
            "Ren'Py iOS mobile runtime is not supported: the official Renios "
            "libraries are staged, but no host-owned in-process adapter is "
            "linked (a second UIKit/SDL application entrypoint is forbidden)";
    } else {
        Cast(value)->error =
            "Ren'Py iOS mobile runtime is not supported: the host-owned Renios "
            "adapter is present, but lifecycle, input, and surface rendering "
            "integration is not enabled";
    }
    if (contract && contract->limitation_utf8) {
        Cast(value)->error.append(" ");
        Cast(value)->error.append(contract->limitation_utf8);
    }
#else
    Cast(value)->error =
        "Ren'Py Android runtime is not supported: the official RAPT "
        "libraries are staged, but the JNI/Activity and rendering adapters "
        "are not linked";
#endif
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
