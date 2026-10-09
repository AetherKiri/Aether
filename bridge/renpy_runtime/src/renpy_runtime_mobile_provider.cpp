#include "renpy_runtime.h"
#include "engine_runtime_provider.h"
#include "renpy_mobile_loader.h"
#include "renpy_input_mapping.h"
#if defined(__ANDROID__)
#include "renpy_mobile_adapter.h"
#endif
#if defined(AETHERKIRI_RENPY_IOS)
#include "renpy_runtime_ios_adapter.h"
#endif

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <string>
#include <sstream>
#include <vector>
#if defined(AETHERKIRI_RENPY_IOS)
#include <CoreFoundation/CoreFoundation.h>
#endif

#if !defined(__ANDROID__) && !defined(__APPLE__) && !defined(AETHERKIRI_RENPY_PROTOCOL_TEST)
#error "Ren'Py mobile provider must only be compiled for Android or Apple"
#endif

namespace aetherkiri::renpy {
namespace {

using mobile::Launcher;

struct MobileRuntime final {
    engine_runtime_host_v1_t host{};
    renpy_mobile_host_t launcher_host{};
    renpy_mobile_config_t launcher_config{};
    std::string game_root;
    std::string private_root;
    std::string argv0;
    std::string apk_path;
    Launcher launcher;
#if defined(__ANDROID__)
    mobile::BootstrapAdapter bootstrap;
#endif
    std::mutex frame_mutex;
    std::vector<uint8_t> frame_pixels;
    uint32_t frame_width = 0;
    uint32_t frame_height = 0;
    uint32_t frame_stride = 0;
    uint64_t frame_serial = 0;
    uint64_t delivered_serial = 0;
    bool frame_rendered = false;
    bool opened = false;
    bool paused = false;
    uint32_t surface_width = 0;
    uint32_t surface_height = 0;
    std::string error =
        "Ren'Py mobile runtime is not supported: official RAPT/Renios "
        "inputs do not export the host lifecycle ABI";
};

MobileRuntime* Cast(void* value) {
    return static_cast<MobileRuntime*>(value);
}

engine_result_t MapLauncherStatus(int status) {
    switch (status) {
        case RENPY_MOBILE_OK:
        case RENPY_MOBILE_FINISHED:
            return ENGINE_RESULT_OK;
        case RENPY_MOBILE_INVALID_ARGUMENT:
            return ENGINE_RESULT_INVALID_ARGUMENT;
        case RENPY_MOBILE_INVALID_STATE:
            return ENGINE_RESULT_INVALID_STATE;
        case RENPY_MOBILE_NOT_IMPLEMENTED:
            return ENGINE_RESULT_NOT_SUPPORTED;
        default:
            return ENGINE_RESULT_INTERNAL_ERROR;
    }
}

int PresentRgba(void* user_data, const uint8_t* rgba, uint32_t width,
                uint32_t height, uint32_t stride) {
    auto* runtime = static_cast<MobileRuntime*>(user_data);
    if (!runtime || !rgba || width == 0 || height == 0 ||
        width > std::numeric_limits<uint32_t>::max() / 4u ||
        stride < width * 4u) {
        return -1;
    }
    const size_t size = static_cast<size_t>(stride) * height;
    if (height != 0 && size / height != stride) return -1;
    std::lock_guard<std::mutex> lock(runtime->frame_mutex);
    runtime->frame_pixels.assign(rgba, rgba + size);
    runtime->frame_width = width;
    runtime->frame_height = height;
    runtime->frame_stride = stride;
    ++runtime->frame_serial;
    runtime->frame_rendered = true;
    return 0;
}

void LogUtf8(void* user_data, int level, const char* message) {
    auto* runtime = static_cast<MobileRuntime*>(user_data);
    if (!runtime || !message) return;
    if (level >= 3) runtime->error = message;
    if (runtime->host.log) {
        const uint32_t host_level = level >= 3 ? ENGINE_RUNTIME_LOG_ERROR
            : level == 2 ? ENGINE_RUNTIME_LOG_WARNING
            : level == 1 ? ENGINE_RUNTIME_LOG_INFO : ENGINE_RUNTIME_LOG_TRACE;
        // The host persists this diagnostic before Destroy releases runtime.
        runtime->host.log(runtime->host.user_data, host_level, "renpy-mobile", message);
    }
}

engine_result_t CaptureFrame(MobileRuntime* runtime) {
    renpy_mobile_frame_t frame{};
    frame.struct_size = sizeof(frame);
    const int status = runtime->launcher.Frame(&frame);
    if (status != RENPY_MOBILE_OK) {
        // A launcher may deliver frames exclusively through present_rgba. A
        // missing frame is therefore not a tick failure.
        return status == RENPY_MOBILE_INVALID_STATE ? ENGINE_RESULT_OK
                                                    : MapLauncherStatus(status);
    }
    if (!frame.rgba || frame.width == 0 || frame.height == 0 ||
        frame.width > std::numeric_limits<uint32_t>::max() / 4u ||
        frame.stride < frame.width * 4u) {
        return ENGINE_RESULT_OK;
    }
    const size_t size = static_cast<size_t>(frame.stride) * frame.height;
    if (frame.height != 0 && size / frame.height != frame.stride) {
        runtime->error = "Ren'Py mobile frame stride overflows host size";
        return ENGINE_RESULT_INTERNAL_ERROR;
    }
    std::lock_guard<std::mutex> lock(runtime->frame_mutex);
    if (frame.serial != 0 && frame.serial == runtime->frame_serial) return ENGINE_RESULT_OK;
    runtime->frame_pixels.assign(frame.rgba, frame.rgba + size);
    runtime->frame_width = frame.width;
    runtime->frame_height = frame.height;
    runtime->frame_stride = frame.stride;
    runtime->frame_serial = frame.serial != 0 ? frame.serial : runtime->frame_serial + 1;
    runtime->frame_rendered = true;
    return ENGINE_RESULT_OK;
}

int32_t Probe(void*, const char*) {
    // The provider is discoverable only when a rebuilt lifecycle payload is
    // linked. Official blocking RAPT/Renios archives remain invisible here.
    static Launcher launcher;
    return launcher.available() ? 100 : 0;
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
    if (!value) return;
    auto* runtime = Cast(value);
    runtime->launcher.Shutdown();
#if defined(__ANDROID__)
    runtime->bootstrap.Stop();
#endif
    delete runtime;
}

engine_result_t Open(void* value, const char* game_root_path,
                     const char* startup_script) {
    if (!value || !game_root_path || game_root_path[0] == '\0') {
        return ENGINE_RESULT_INVALID_ARGUMENT;
    }
    auto* runtime = Cast(value);
    if (runtime->opened) return ENGINE_RESULT_INVALID_STATE;
    if (!runtime->launcher.available()) {
#if defined(__ANDROID__)
        mobile::BootstrapRequest request{};
        request.game_root_path_utf8 = game_root_path;
        request.startup_script_utf8 = startup_script;
        request.existing_host_activity = runtime->host.reserved_ptr[1];
        const auto result = runtime->bootstrap.Start(request);
        runtime->error = runtime->bootstrap.last_error();
        return result;
#elif defined(AETHERKIRI_RENPY_IOS)
        const auto* contract = renpy_get_ios_launcher_contract();
        runtime->error =
            "Ren'Py iOS mobile runtime is not supported: the official Renios "
            "libraries are staged, but no host-owned lifecycle payload is "
            "linked (a second UIKit/SDL entrypoint is forbidden)";
        if (contract && contract->limitation_utf8) {
            runtime->error += " ";
            runtime->error += contract->limitation_utf8;
        }
        return ENGINE_RESULT_NOT_SUPPORTED;
#else
        runtime->error = runtime->launcher.last_error();
        return ENGINE_RESULT_NOT_SUPPORTED;
#endif
    }

    // open_game_async runs on a temporary startup thread. Defer CPython,
    // greenlet and GL initialization until the first host Tick, and own every
    // string/callback table for the runtime's entire lifetime.
    runtime->game_root = game_root_path;
    runtime->argv0 = startup_script ? startup_script : "";
    runtime->launcher_host.struct_size = sizeof(runtime->launcher_host);
    runtime->launcher_host.abi_version = RENPY_MOBILE_LAUNCHER_ABI_VERSION;
    runtime->launcher_host.user_data = runtime;
    runtime->launcher_host.present_rgba = PresentRgba;
    runtime->launcher_host.log_utf8 = LogUtf8;
    runtime->opened = true;
    runtime->error.clear();
    return ENGINE_RESULT_OK;
}

engine_result_t Tick(void* value, uint32_t delta_ms) {
    if (!value) return ENGINE_RESULT_INVALID_ARGUMENT;
    auto* runtime = Cast(value);
    if (!runtime->opened) return ENGINE_RESULT_INVALID_STATE;
    runtime->frame_rendered = false;
    if (runtime->launcher.finished()) {
        runtime->error = "Ren'Py runtime requested termination";
        return ENGINE_RESULT_INVALID_STATE;
    }
    if (runtime->paused) return ENGINE_RESULT_OK;
    if (!runtime->launcher.initialized()) {
#if defined(__ANDROID__)
        mobile::BootstrapRequest request{};
        request.game_root_path_utf8 = runtime->game_root.c_str();
        request.existing_host_activity = runtime->host.reserved_ptr[1];
        const auto prepared = runtime->bootstrap.PrepareRuntime(request,
            runtime->surface_width ? runtime->surface_width : 1280u,
            runtime->surface_height ? runtime->surface_height : 720u,
            &runtime->private_root, &runtime->apk_path);
        if (prepared != ENGINE_RESULT_OK) { runtime->error = runtime->bootstrap.last_error(); return prepared; }
        if (runtime->argv0.empty()) runtime->argv0 = runtime->private_root + "/main.py";
#elif defined(AETHERKIRI_RENPY_IOS)
        CFURLRef resources = CFBundleCopyResourcesDirectoryURL(CFBundleGetMainBundle());
        char path[4096]{};
        const bool found = resources && CFURLGetFileSystemRepresentation(resources, true,
            reinterpret_cast<UInt8*>(path), sizeof(path));
        if (resources) CFRelease(resources);
        if (!found) { runtime->error = "Ren'Py could not locate the app's bundled Renios Python payload"; return ENGINE_RESULT_IO_ERROR; }
        runtime->private_root = std::string(path) + "/renios/base";
        if (runtime->argv0.empty()) runtime->argv0 = runtime->private_root + "/renpy.py";
#else
        runtime->private_root = runtime->game_root;
        if (runtime->argv0.empty()) runtime->argv0 = "AetherKiri";
#endif
        auto& config = runtime->launcher_config;
        config.struct_size = sizeof(config);
        config.abi_version = RENPY_MOBILE_LAUNCHER_ABI_VERSION;
        config.private_root_utf8 = runtime->private_root.c_str();
        config.public_root_utf8 = runtime->game_root.c_str();
        config.game_root_utf8 = runtime->game_root.c_str();
        config.argv0_utf8 = runtime->argv0.c_str();
        config.apk_path_utf8 = runtime->apk_path.empty() ? nullptr : runtime->apk_path.c_str();
        runtime->error.clear();
        const auto initialized = MapLauncherStatus(runtime->launcher.Init(config, runtime->launcher_host));
        if (initialized != ENGINE_RESULT_OK) {
            if (runtime->error.empty()) runtime->error = runtime->launcher.last_error();
            return initialized;
        }
        if (runtime->surface_width && runtime->surface_height) {
            const auto resized = MapLauncherStatus(runtime->launcher.SetSurfaceSize(
                runtime->surface_width, runtime->surface_height));
            if (resized != ENGINE_RESULT_OK) return resized;
        }
    }
    runtime->error.clear();
    const int status = runtime->launcher.Tick(delta_ms);
    if (status == RENPY_MOBILE_FINISHED) {
        runtime->error = "Ren'Py runtime requested termination";
        return ENGINE_RESULT_INVALID_STATE;
    }
    const auto result = MapLauncherStatus(status);
    if (result != ENGINE_RESULT_OK) {
        if (runtime->error.empty()) runtime->error = runtime->launcher.last_error();
        return result;
    }
    const auto frame_result = CaptureFrame(runtime);
    if (frame_result != ENGINE_RESULT_OK) return frame_result;
    return ENGINE_RESULT_OK;
}

engine_result_t Pause(void* value) {
    if (!value) return ENGINE_RESULT_INVALID_ARGUMENT;
    auto* runtime = Cast(value);
    if (!runtime->opened) return ENGINE_RESULT_INVALID_STATE;
    const auto result = runtime->launcher.initialized()
        ? MapLauncherStatus(runtime->launcher.Pause()) : ENGINE_RESULT_OK;
    if (result == ENGINE_RESULT_OK) runtime->paused = true;
    return result;
}

engine_result_t Resume(void* value) {
    if (!value) return ENGINE_RESULT_INVALID_ARGUMENT;
    auto* runtime = Cast(value);
    if (!runtime->opened) return ENGINE_RESULT_INVALID_STATE;
    const auto result = runtime->launcher.initialized()
        ? MapLauncherStatus(runtime->launcher.Resume()) : ENGINE_RESULT_OK;
    if (result == ENGINE_RESULT_OK) runtime->paused = false;
    return result;
}

engine_result_t SetSurfaceSize(void* value, uint32_t width, uint32_t height) {
    if (!value || width == 0 || height == 0) return ENGINE_RESULT_INVALID_ARGUMENT;
    auto* runtime = Cast(value);
    runtime->surface_width = width;
    runtime->surface_height = height;
    if (runtime->launcher.initialized()) return MapLauncherStatus(runtime->launcher.SetSurfaceSize(width, height));
    return ENGINE_RESULT_OK;
}

engine_result_t FrameDesc(void* value, engine_frame_desc_t* output) {
    if (!value || !output || output->struct_size < sizeof(*output)) {
        return ENGINE_RESULT_INVALID_ARGUMENT;
    }
    auto* runtime = Cast(value);
    std::lock_guard<std::mutex> lock(runtime->frame_mutex);
    output->width = runtime->frame_width;
    output->height = runtime->frame_height;
    output->stride_bytes = runtime->frame_stride;
    output->pixel_format = ENGINE_PIXEL_FORMAT_RGBA8888;
    output->frame_serial = runtime->frame_serial;
    return ENGINE_RESULT_OK;
}

engine_result_t ReadFrame(void* value, void* output, size_t output_size) {
    if (!value || !output) return ENGINE_RESULT_INVALID_ARGUMENT;
    auto* runtime = Cast(value);
    std::lock_guard<std::mutex> lock(runtime->frame_mutex);
    if (runtime->frame_pixels.empty()) return ENGINE_RESULT_INVALID_STATE;
    if (output_size < runtime->frame_pixels.size()) return ENGINE_RESULT_INVALID_ARGUMENT;
    std::memcpy(output, runtime->frame_pixels.data(), runtime->frame_pixels.size());
    runtime->delivered_serial = runtime->frame_serial;
    return ENGINE_RESULT_OK;
}

engine_result_t NativeFrame(void* value, uint64_t*, uint32_t*, uint32_t*,
                            uint64_t*) {
    // The lifecycle ABI owns an RGBA CPU buffer. It intentionally does not
    // expose an SDL/GLES texture that could steal Godot's render target.
    return value ? ENGINE_RESULT_NOT_SUPPORTED : ENGINE_RESULT_INVALID_ARGUMENT;
}

engine_result_t Input(void* value, const engine_input_event_t* event) {
    if (!value || !event || event->struct_size < sizeof(*event)) {
        return ENGINE_RESULT_INVALID_ARGUMENT;
    }
    auto* runtime = Cast(value);
    if (!runtime->opened) return ENGINE_RESULT_INVALID_STATE;
    if (!std::isfinite(event->x) || !std::isfinite(event->y) ||
        !std::isfinite(event->delta_x) || !std::isfinite(event->delta_y)) return ENGINE_RESULT_INVALID_ARGUMENT;
    renpy_mobile_input_t input{};
    input.struct_size = sizeof(input);
    input.timestamp_ns = event->timestamp_micros * 1000ull;
    input.device_id = event->pointer_id;
    input.code = input_mapping::MapKeyCodeToPygame(event->key_code,
        static_cast<input_mapping::KeyCodeSpace>(event->reserved_u32));
    input.value = static_cast<int32_t>(event->type);
    {
        std::lock_guard<std::mutex> lock(runtime->frame_mutex);
        const auto width = runtime->frame_width ? runtime->frame_width : runtime->surface_width;
        const auto height = runtime->frame_height ? runtime->frame_height : runtime->surface_height;
        input.x = static_cast<float>(event->x / (width ? width : 1280u));
        input.y = static_cast<float>(event->y / (height ? height : 720u));
    }
    input.delta_x = static_cast<float>(event->delta_x);
    input.delta_y = static_cast<float>(event->delta_y);
    input.modifiers = input_mapping::MapModifiersToPygame(event->modifiers);
    input.repeat = input_mapping::IsAetherKeyRepeat(event->modifiers) ? 1u : 0u;
    input.pressure = (event->type == ENGINE_INPUT_EVENT_POINTER_UP) ? 0.0f : 1.0f;
    std::string text;
    switch (event->type) {
        case ENGINE_INPUT_EVENT_POINTER_DOWN:
        case ENGINE_INPUT_EVENT_POINTER_MOVE:
        case ENGINE_INPUT_EVENT_POINTER_UP:
        case ENGINE_INPUT_EVENT_POINTER_SCROLL:
            input.type = RENPY_MOBILE_INPUT_POINTER;
            input.code = input_mapping::MapPointerButtonToPygame(event->button);
            break;
        case ENGINE_INPUT_EVENT_KEY_DOWN:
        case ENGINE_INPUT_EVENT_KEY_UP:
            input.type = RENPY_MOBILE_INPUT_KEY;
            break;
        case ENGINE_INPUT_EVENT_TEXT_INPUT: {
            input.type = RENPY_MOBILE_INPUT_TEXT;
            uint32_t cp = event->unicode_codepoint;
            if (cp == 0 || cp > 0x10ffffu || (cp >= 0xd800u && cp <= 0xdfffu)) return ENGINE_RESULT_INVALID_ARGUMENT;
            if (cp <= 0x7fu) text.push_back(static_cast<char>(cp));
            else if (cp <= 0x7ffu) {
                text.push_back(static_cast<char>(0xc0u | (cp >> 6)));
                text.push_back(static_cast<char>(0x80u | (cp & 0x3fu)));
            } else if (cp <= 0xffffu) {
                text.push_back(static_cast<char>(0xe0u | (cp >> 12)));
                text.push_back(static_cast<char>(0x80u | ((cp >> 6) & 0x3fu)));
                text.push_back(static_cast<char>(0x80u | (cp & 0x3fu)));
            } else if (cp <= 0x10ffffu) {
                text.push_back(static_cast<char>(0xf0u | (cp >> 18)));
                text.push_back(static_cast<char>(0x80u | ((cp >> 12) & 0x3fu)));
                text.push_back(static_cast<char>(0x80u | ((cp >> 6) & 0x3fu)));
                text.push_back(static_cast<char>(0x80u | (cp & 0x3fu)));
            }
            input.text_utf8 = text.c_str();
            break;
        }
        case ENGINE_INPUT_EVENT_BACK:
            input.type = RENPY_MOBILE_INPUT_KEY;
            input.code = 27; // Ren'Py maps Android Back to Escape/game menu.
            break;
        default:
            return ENGINE_RESULT_INVALID_ARGUMENT;
    }
    return MapLauncherStatus(runtime->launcher.Input(input));
}

engine_result_t Rendered(void* value, uint32_t* output) {
    if (!value || !output) return ENGINE_RESULT_INVALID_ARGUMENT;
    auto* runtime = Cast(value);
    *output = runtime->frame_rendered ? 1u : 0u;
    return ENGINE_RESULT_OK;
}

engine_result_t Renderer(void* value, char* buffer, uint32_t size) {
    if (!value || !buffer || size == 0) return ENGINE_RESULT_INVALID_ARGUMENT;
    constexpr char kRenderer[] =
        "Ren'Py mobile host lifecycle (host-owned RGBA frame)";
    if (size < sizeof(kRenderer)) {
        Cast(value)->error = "Ren'Py mobile renderer description buffer is too small";
        return ENGINE_RESULT_INVALID_ARGUMENT;
    }
    std::memcpy(buffer, kRenderer, sizeof(kRenderer));
    return ENGINE_RESULT_OK;
}

engine_result_t Unsupported(void* value) {
    if (!value) return ENGINE_RESULT_INVALID_ARGUMENT;
    Cast(value)->error =
        "Ren'Py mobile runtime operation requires the rebuilt host lifecycle ABI";
    return ENGINE_RESULT_NOT_SUPPORTED;
}

engine_result_t UnsupportedOption(void* value, const engine_option_t* option) {
    if (!value || !option || !option->key_utf8 || !option->value_utf8) {
        return ENGINE_RESULT_INVALID_ARGUMENT;
    }
    return Unsupported(value);
}

engine_result_t TextState(void* value, uint32_t* active) {
    if (!value || !active) return ENGINE_RESULT_INVALID_ARGUMENT;
    auto* runtime = Cast(value);
    *active = 0;
    if (!runtime->launcher.initialized() || runtime->launcher.finished()) return ENGINE_RESULT_OK;
    return MapLauncherStatus(runtime->launcher.TextInputState(active));
}

engine_result_t DebugInfo(void* value, char* buffer, uint32_t size, uint32_t* written) {
    if (!value || !written) return ENGINE_RESULT_INVALID_ARGUMENT;
    auto* runtime = Cast(value);
    std::ostringstream json;
    json << "{\"runtime\":\"renpy\",\"initialized\":" << (runtime->launcher.initialized() ? "true" : "false")
         << ",\"paused\":" << (runtime->paused ? "true" : "false")
         << ",\"exited\":" << (runtime->launcher.finished() ? "true" : "false")
         << ",\"frame_serial\":" << runtime->frame_serial << "}";
    const auto text = json.str();
    *written = static_cast<uint32_t>(text.size());
    if (!buffer || size <= text.size()) return ENGINE_RESULT_INVALID_ARGUMENT;
    std::memcpy(buffer, text.c_str(), text.size() + 1u);
    return ENGINE_RESULT_OK;
}

const char* Error(void* value) {
    return value ? Cast(value)->error.c_str() : "Invalid Ren'Py mobile runtime";
}

const engine_runtime_provider_v1_t& Provider() {
    static const engine_runtime_provider_v1_t provider = [] {
        engine_runtime_provider_v1_t p{};
        p.struct_size = sizeof(p);
        p.api_version = ENGINE_RUNTIME_PROVIDER_API_VERSION;
        p.runtime_id_utf8 = "renpy";
        p.display_name_utf8 = "Ren'Py (mobile host lifecycle)";
        p.priority = 60;
        p.probe = Probe;
        p.create = Create;
        p.destroy = Destroy;
        p.open_game = Open;
        p.tick = Tick;
        p.pause = Pause;
        p.resume = Resume;
        p.set_option = UnsupportedOption;
        p.set_surface_size = SetSurfaceSize;
        p.get_frame_desc = FrameDesc;
        p.read_frame_rgba = ReadFrame;
        p.get_godot_native_frame_texture = NativeFrame;
        p.send_input = Input;
        p.get_frame_rendered_flag = Rendered;
        p.get_renderer_info = Renderer;
        p.get_text_input_state = TextState;
        p.get_plugin_debug_info = DebugInfo;
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
