#include "n2system_runtime.h"
#include "n2system_probe.h"
#include "aether_n2system.h"
#include "engine_runtime_provider.h"
#include <algorithm>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <thread>
#include <filesystem>
#include <condition_variable>
#include <functional>
#include <future>
#include <queue>
#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#else
#include <dlfcn.h>
#endif

namespace aetherkiri::n2system {
namespace {
// The NativeAOT image lives in an isolated directory beside the extension.
// Keeping its FFmpeg/OpenAL dependencies there avoids changing other engines.
struct HostApi {
    decltype(&aether_n2system_abi_version) abi_version = nullptr;
    decltype(&aether_n2system_create) create = nullptr;
    decltype(&aether_n2system_tick) tick = nullptr;
    decltype(&aether_n2system_event) event = nullptr;
    decltype(&aether_n2system_pause) pause = nullptr;
    decltype(&aether_n2system_frame) frame = nullptr;
    decltype(&aether_n2system_status) status = nullptr;
    decltype(&aether_n2system_last_error) last_error = nullptr;
    decltype(&aether_n2system_destroy) destroy = nullptr;
    std::string error;
    void* image = nullptr;
    bool ready = false;
    bool Load();
};
HostApi api;
bool HostApi::Load() {
    static std::mutex mutex;
    std::lock_guard<std::mutex> lock(mutex);
    if(ready) return true;
    if(image) return false;
    std::filesystem::path directory;
#ifdef _WIN32
    HMODULE module = nullptr;
    if(!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                          GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                          reinterpret_cast<LPCWSTR>(&api), &module)) {
        error = "Cannot locate the N2System provider library"; return false;
    }
    wchar_t path[32768]{};
    if(!GetModuleFileNameW(module, path, 32768)) {
        error = "Cannot resolve the N2System provider library path"; return false;
    }
    directory = std::filesystem::path(path).parent_path();
    const auto library = directory / "n2system-runtime" / "aether_n2system.dll";
    image = LoadLibraryExW(library.c_str(), nullptr,
        LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
    auto symbol = [&](const char* name) { return reinterpret_cast<void*>(GetProcAddress(static_cast<HMODULE>(image), name)); };
#else
    Dl_info location{};
    if(!dladdr(static_cast<const void*>(&api), &location) || !location.dli_fname) {
        error = "Cannot locate the N2System provider library"; return false;
    }
    directory = std::filesystem::path(location.dli_fname).parent_path();
#ifdef __APPLE__
    const auto library = directory / "n2system-runtime" / "aether_n2system.dylib";
#else
    const auto library = directory / "n2system-runtime" / "aether_n2system.so";
#endif
    image = dlopen(library.c_str(), RTLD_NOW | RTLD_LOCAL);
    auto symbol = [&](const char* name) { return dlsym(image, name); };
#endif
    if(!image) {
        error = "Cannot load N2System NativeAOT host: " + library.u8string();
#ifdef _WIN32
        error += " (Windows error " + std::to_string(GetLastError()) + ")";
#else
        if(const char* detail = dlerror()) error += ": " + std::string(detail);
#endif
        return false;
    }
    // NativeAOT owns process-global runtime state; keep this image loaded
    // until process exit, including after all game instances are destroyed.
#define N2_BIND(member) member = reinterpret_cast<decltype(member)>(symbol("aether_n2system_" #member)); if(!member) { error = "Missing N2System host export: " #member; return false; }
    N2_BIND(abi_version) N2_BIND(create) N2_BIND(tick) N2_BIND(event)
    N2_BIND(pause) N2_BIND(frame) N2_BIND(status) N2_BIND(last_error) N2_BIND(destroy)
#undef N2_BIND
    ready = true;
    return true;
}
struct Runtime {
    engine_runtime_host_v1_t host{};
    void* instance = nullptr;
    uint32_t width = 1280, height = 720;
    uint64_t delivered = 0;
    std::string writable, error;
    std::mutex mutex;
    std::condition_variable wake;
    std::queue<std::function<void()>> commands;
    bool stopping = false;
    std::thread worker;
    Runtime() : worker([this] {
        for(;;) {
            std::function<void()> command;
            {
                std::unique_lock<std::mutex> lock(mutex);
                wake.wait(lock, [this] { return stopping || !commands.empty(); });
                if(commands.empty() && stopping) return;
                command = std::move(commands.front()); commands.pop();
            }
            command();
        }
    }) {}
    template<class Callback> auto Call(Callback callback) -> decltype(callback()) {
        auto task = std::make_shared<std::packaged_task<decltype(callback())()>>(std::move(callback));
        auto result = task->get_future();
        {
            std::lock_guard<std::mutex> lock(mutex);
            commands.emplace([task] { (*task)(); });
        }
        wake.notify_one();
        return result.get();
    }
    ~Runtime() {
        if(instance) Call([this] { api.destroy(instance); });
        { std::lock_guard<std::mutex> lock(mutex); stopping = true; }
        wake.notify_one(); worker.join();
    }
};
Runtime* Cast(void* opaque) { return static_cast<Runtime*>(opaque); }
engine_result_t Result(Runtime* runtime, int value) {
    if(value == 0) { runtime->error.clear(); return ENGINE_RESULT_OK; }
    runtime->error = runtime->Call([&] {
        const char* error = api.last_error(runtime->instance);
        return std::string(error ? error : "N2System host operation failed");
    });
    if(runtime->host.log) runtime->host.log(runtime->host.user_data,
        ENGINE_RUNTIME_LOG_ERROR, "n2system", runtime->error.c_str());
    return ENGINE_RESULT_INTERNAL_ERROR;
}
engine_result_t Create(void*, const engine_runtime_host_v1_t* host,
                       const engine_create_desc_t* desc, void** output) {
    if(!output) return ENGINE_RESULT_INVALID_ARGUMENT;
    *output = nullptr;
    if(!host || !desc || host->struct_size < sizeof(*host) ||
       desc->struct_size < sizeof(*desc)) return ENGINE_RESULT_INVALID_ARGUMENT;
    if(host->api_version != ENGINE_RUNTIME_PROVIDER_API_VERSION) return ENGINE_RESULT_NOT_SUPPORTED;
    if(!api.Load()) {
        if(host->log) host->log(host->user_data, ENGINE_RUNTIME_LOG_ERROR, "n2system", api.error.c_str());
        return ENGINE_RESULT_IO_ERROR;
    }
    if(api.abi_version() != 1) return ENGINE_RESULT_NOT_SUPPORTED;
    std::unique_ptr<Runtime> runtime;
    try { runtime = std::make_unique<Runtime>(); }
    catch(const std::exception& error) {
        if(host->log) host->log(host->user_data, ENGINE_RUNTIME_LOG_ERROR, "n2system", error.what());
        return ENGINE_RESULT_INTERNAL_ERROR;
    }
    runtime->host = *host;
    if(desc->writable_path_utf8) runtime->writable = desc->writable_path_utf8;
    *output = runtime.release();
    return ENGINE_RESULT_OK;
}
void Destroy(void* opaque) {
    auto* runtime = Cast(opaque);
    if(!runtime) return;
    delete runtime;
}
engine_result_t Open(void* opaque, const char* root, const char* startup) {
    auto* runtime = Cast(opaque);
    if(!root || !*root) return ENGINE_RESULT_INVALID_ARGUMENT;
    if(!runtime) return ENGINE_RESULT_INVALID_STATE;
    if(runtime->instance) return ENGINE_RESULT_INVALID_STATE;
    if(startup && *startup) {
        runtime->error = "N2System startup scripts are selected by aether-n2system.json";
        return ENGINE_RESULT_NOT_SUPPORTED;
    }
    if(!detail::ProbeRoot(root)) {
        runtime->error = "No N2System profile and game assets were found";
        return ENGINE_RESULT_NOT_SUPPORTED;
    }
    return Result(runtime, runtime->Call([&] { return api.create(root, runtime->writable.c_str(),
        0, 0, &runtime->instance); }));
}
engine_result_t Tick(void* opaque, uint32_t delta) {
    auto* runtime = Cast(opaque);
    if(!runtime || !runtime->instance) return ENGINE_RESULT_INVALID_STATE;
    const auto result = Result(runtime, runtime->Call([&] { return api.tick(runtime->instance, double(delta) / 1000.0); }));
    if(result != ENGINE_RESULT_OK) return result;
    const int status = runtime->Call([&] { return api.status(runtime->instance); });
    if(status < 0) return Result(runtime, -1);
    if(status >= 2) {
        runtime->error = "N2System requested termination";
        return ENGINE_RESULT_INVALID_STATE;
    }
    return ENGINE_RESULT_OK;
}
engine_result_t Paused(void* opaque, int paused) {
    auto* runtime = Cast(opaque);
    if(!runtime || !runtime->instance) return ENGINE_RESULT_INVALID_STATE;
    return Result(runtime, runtime->Call([&] { return api.pause(runtime->instance, paused); }));
}
engine_result_t Surface(void* opaque, uint32_t width, uint32_t height) {
    auto* runtime = Cast(opaque);
    if(!runtime || !width || !height) return ENGINE_RESULT_INVALID_ARGUMENT;
    // The engine renders at its profile's design resolution; Godot scales
    // the RGBA surface and supplies pointer coordinates in that space.
    runtime->width = width; runtime->height = height;
    return ENGINE_RESULT_OK;
}
engine_result_t Frame(Runtime* runtime, aether_n2system_frame_info& frame) {
    if(!runtime || !runtime->instance) return ENGINE_RESULT_INVALID_STATE;
    const auto result = Result(runtime, runtime->Call([&] { return api.frame(runtime->instance, &frame); }));
    if(result != ENGINE_RESULT_OK) return result;
    if(!frame.pixels || !frame.width || !frame.height ||
       frame.width > std::numeric_limits<uint32_t>::max() / 4 ||
       frame.stride < frame.width * 4 ||
       frame.height > std::numeric_limits<size_t>::max() / frame.stride) {
        runtime->error = "N2System returned an invalid RGBA frame";
        return ENGINE_RESULT_INTERNAL_ERROR;
    }
    return ENGINE_RESULT_OK;
}
engine_result_t FrameDesc(void* opaque, engine_frame_desc_t* desc) {
    if(!desc || desc->struct_size < sizeof(*desc)) return ENGINE_RESULT_INVALID_ARGUMENT;
    aether_n2system_frame_info frame{};
    const auto result = Frame(Cast(opaque), frame);
    if(result != ENGINE_RESULT_OK) return result;
    const uint32_t size = desc->struct_size;
    *desc = {}; desc->struct_size = size;
    desc->width = frame.width; desc->height = frame.height;
    desc->stride_bytes = frame.stride; desc->frame_serial = frame.sequence;
    desc->pixel_format = ENGINE_PIXEL_FORMAT_RGBA8888;
    return ENGINE_RESULT_OK;
}
engine_result_t Read(void* opaque, void* pixels, size_t size) {
    if(!pixels) return ENGINE_RESULT_INVALID_ARGUMENT;
    auto* runtime = Cast(opaque);
    aether_n2system_frame_info frame{};
    const auto result = Frame(runtime, frame);
    if(result != ENGINE_RESULT_OK) return result;
    const size_t required = size_t(frame.stride) * frame.height;
    if(size < required) return ENGINE_RESULT_INVALID_ARGUMENT;
    std::memcpy(pixels, frame.pixels, required);
    runtime->delivered = frame.sequence;
    return ENGINE_RESULT_OK;
}
int Scancode(int key) {
    if(key >= 'A' && key <= 'Z') return 4 + key - 'A';
    if(key >= '1' && key <= '9') return 30 + key - '1';
    if(key == '0') return 39;
    if(key >= 0x70 && key <= 0x7B) return 58 + key - 0x70;
    switch(key) {
        case 0x0D: return 40; case 0x1B: return 41; case 0x08: return 42;
        case 0x09: return 43; case 0x20: return 44; case 0xBD: return 45;
        case 0xBB: return 46; case 0xDB: return 47; case 0xDD: return 48;
        case 0xDC: return 49; case 0xBA: return 51; case 0xDE: return 52;
        case 0xC0: return 53; case 0xBC: return 54; case 0xBE: return 55;
        case 0xBF: return 56; case 0x14: return 57; case 0x2D: return 73;
        case 0x24: return 74; case 0x21: return 75; case 0x2E: return 76;
        case 0x23: return 77; case 0x22: return 78; case 0x27: return 79;
        case 0x25: return 80; case 0x28: return 81; case 0x26: return 82;
        case 0x11: case 0xA2: return 224; case 0x10: case 0xA0: return 225;
        case 0x12: case 0xA4: return 226; case 0xA3: return 228;
        case 0xA1: return 229; case 0xA5: return 230; default: return 0;
    }
}
engine_result_t Input(void* opaque, const engine_input_event_t* input) {
    auto* runtime = Cast(opaque);
    if(!input || input->struct_size < sizeof(*input)) return ENGINE_RESULT_INVALID_ARGUMENT;
    if(!runtime || !runtime->instance) return ENGINE_RESULT_INVALID_STATE;
    uint32_t type = 0; int code = 0;
    float x = float(input->x), y = float(input->y);
    switch(input->type) {
        case ENGINE_INPUT_EVENT_KEY_DOWN: case ENGINE_INPUT_EVENT_KEY_UP:
            code = Scancode(input->key_code);
            if(!code) return ENGINE_RESULT_NOT_SUPPORTED;
            type = input->type == ENGINE_INPUT_EVENT_KEY_DOWN ? 1 : 2; break;
        case ENGINE_INPUT_EVENT_POINTER_MOVE: type = 3; break;
        case ENGINE_INPUT_EVENT_POINTER_DOWN: case ENGINE_INPUT_EVENT_POINTER_UP:
            if(input->button < 0 || input->button > 2) return ENGINE_RESULT_NOT_SUPPORTED;
            code = input->button == 0 ? 1 : input->button == 1 ? 3 : 2;
            type = input->type == ENGINE_INPUT_EVENT_POINTER_DOWN ? 4 : 5; break;
        case ENGINE_INPUT_EVENT_POINTER_SCROLL:
            type = 6; x = float(input->delta_x); y = float(input->delta_y); break;
        case ENGINE_INPUT_EVENT_BACK: {
            auto result = Result(runtime, runtime->Call([&] { return api.event(runtime->instance, 1, 41, 0, 0); }));
            return result == ENGINE_RESULT_OK ? Result(runtime,
                runtime->Call([&] { return api.event(runtime->instance, 2, 41, 0, 0); })) : result;
        }
        case ENGINE_INPUT_EVENT_TEXT_INPUT: return ENGINE_RESULT_NOT_SUPPORTED;
        default: return ENGINE_RESULT_INVALID_ARGUMENT;
    }
    return Result(runtime, runtime->Call([&] { return api.event(runtime->instance, type, code, x, y); }));
}
engine_result_t Copy(const std::string& value, char* output, uint32_t size, uint32_t* written = nullptr) {
    if(!output || !size) return ENGINE_RESULT_INVALID_ARGUMENT;
    const auto count = std::min<size_t>(value.size(), size - 1);
    std::memcpy(output, value.data(), count); output[count] = 0;
    if(written) *written = uint32_t(count);
    return count == value.size() ? ENGINE_RESULT_OK : ENGINE_RESULT_INVALID_ARGUMENT;
}
engine_runtime_provider_v1_t Provider() {
    engine_runtime_provider_v1_t provider{};
    provider.struct_size = sizeof(provider);
    provider.api_version = ENGINE_RUNTIME_PROVIDER_API_VERSION;
    provider.runtime_id_utf8 = "n2system";
    provider.display_name_utf8 = "N2System (NitroSharp NativeAOT)";
    provider.priority = 85;
    provider.probe = [](void*, const char* root) { return detail::ProbeRoot(root); };
    provider.create = Create; provider.destroy = Destroy; provider.open_game = Open; provider.tick = Tick;
    provider.pause = [](void* runtime) { return Paused(runtime, 1); };
    provider.resume = [](void* runtime) { return Paused(runtime, 0); };
    provider.set_option = [](void*, const engine_option_t*) { return ENGINE_RESULT_NOT_SUPPORTED; };
    provider.set_surface_size = Surface; provider.get_frame_desc = FrameDesc; provider.read_frame_rgba = Read;
    provider.send_input = Input;
    provider.get_frame_rendered_flag = [](void* opaque, uint32_t* output) {
        if(!output) return ENGINE_RESULT_INVALID_ARGUMENT;
        auto* runtime = Cast(opaque); aether_n2system_frame_info frame{};
        const auto result = Frame(runtime, frame);
        if(result == ENGINE_RESULT_OK) *output = frame.sequence != runtime->delivered;
        return result;
    };
    provider.get_renderer_info = [](void*, char* output, uint32_t size) {
        return Copy("backend=n2system runtime=n2system host=NativeAOT render=RGBA8888", output, size);
    };
    provider.get_last_error = [](void* opaque) {
        const auto* runtime = Cast(opaque);
        return runtime ? runtime->error.c_str() : "N2System runtime handle is null";
    };
    return provider;
}
}
void RegisterRuntimeProvider() {
    static const auto provider = Provider();
    static std::once_flag once;
    std::call_once(once, [] { engine_register_runtime_provider(&provider); });
}
}
