#include "exhibit_runtime_provider.h"

#include "engine_runtime_provider.h"
#include "exhibit_runtime.h"

#include <algorithm>
#include <cstring>
#include <memory>
#include <mutex>
#include <new>
#include <string>

namespace aetherkiri::exhibit {
    namespace {

        struct ProviderRuntime {
            ProviderRuntime(const engine_runtime_host_v1_t *host_value,
                            const engine_create_desc_t *desc) :
                host(host_value != nullptr ? *host_value
                                           : engine_runtime_host_v1_t{}) {
                Options options;
                options.writable_path =
                    desc != nullptr && desc->writable_path_utf8 != nullptr
                    ? desc->writable_path_utf8
                    : "";
                options.cache_path =
                    desc != nullptr && desc->cache_path_utf8 != nullptr
                    ? desc->cache_path_utf8
                    : "";
                initialized = runtime.initialize(options);
                if(!initialized) {
                    error = runtime.last_error();
                }
            }

            void flush_logs() {
                std::string pending = runtime.drain_logs();
                if(pending.empty() || host.log == nullptr) {
                    return;
                }
                size_t begin = 0;
                while(begin <= pending.size()) {
                    const size_t end = pending.find('\n', begin);
                    const std::string line = pending.substr(
                        begin,
                        end == std::string::npos ? std::string::npos
                                                 : end - begin);
                    if(!line.empty()) {
                        host.log(host.user_data, ENGINE_RUNTIME_LOG_INFO,
                                 "exhibit", line.c_str());
                    }
                    if(end == std::string::npos) {
                        break;
                    }
                    begin = end + 1;
                }
            }

            engine_runtime_host_v1_t host{};
            Runtime runtime;
            Frame frame;
            bool initialized = false;
            bool frame_ready = false;
            // The core exposes no pause verb, so pausing means withholding
            // ticks; the picture simply stops advancing.
            bool paused = false;
            uint64_t delivered_frame_serial = 0;
            std::string error;
        };

        ProviderRuntime *Cast(void *runtime) {
            return static_cast<ProviderRuntime *>(runtime);
        }

        engine_result_t Fail(ProviderRuntime *runtime, engine_result_t result,
                             const std::string &message) {
            if(runtime != nullptr) {
                runtime->error = message;
            }
            return result;
        }

        engine_result_t CopyString(const std::string &value, char *output,
                                   uint32_t output_size,
                                   uint32_t *bytes_written = nullptr) {
            if(output == nullptr || output_size == 0) {
                return ENGINE_RESULT_INVALID_ARGUMENT;
            }
            const size_t copy_size =
                std::min<size_t>(value.size(), output_size - 1u);
            std::memcpy(output, value.data(), copy_size);
            output[copy_size] = '\0';
            if(bytes_written != nullptr) {
                *bytes_written = static_cast<uint32_t>(copy_size);
            }
            return copy_size == value.size() ? ENGINE_RESULT_OK
                                             : ENGINE_RESULT_INVALID_ARGUMENT;
        }

        int32_t Probe(void *, const char *game_root_path) {
            if(game_root_path == nullptr || game_root_path[0] == '\0') {
                return 0;
            }
            try {
                // ExHIBIT.ini is unique to this engine, so the top score
                // cannot steal directories from the other providers.
                return Runtime::looks_like_game(game_root_path) ? 95 : 0;
            } catch(...) {
                return 0;
            }
        }

        engine_result_t Create(void *, const engine_runtime_host_v1_t *host,
                               const engine_create_desc_t *desc,
                               void **out_runtime) {
            if(host == nullptr || desc == nullptr || out_runtime == nullptr) {
                return ENGINE_RESULT_INVALID_ARGUMENT;
            }
            *out_runtime = nullptr;
            if(host->api_version != ENGINE_RUNTIME_PROVIDER_API_VERSION) {
                return ENGINE_RESULT_NOT_SUPPORTED;
            }
            auto runtime = std::unique_ptr<ProviderRuntime>(
                new(std::nothrow) ProviderRuntime(host, desc));
            if(!runtime) {
                return ENGINE_RESULT_INTERNAL_ERROR;
            }
            if(!runtime->initialized) {
                return ENGINE_RESULT_INVALID_STATE;
            }
            *out_runtime = runtime.release();
            return ENGINE_RESULT_OK;
        }

        void Destroy(void *runtime) { delete Cast(runtime); }

        engine_result_t OpenGame(void *opaque, const char *game_root,
                                 const char *startup_script) {
            ProviderRuntime *runtime = Cast(opaque);
            if(runtime == nullptr || game_root == nullptr ||
               game_root[0] == '\0') {
                return ENGINE_RESULT_INVALID_ARGUMENT;
            }
            runtime->error.clear();
            runtime->frame = {};
            runtime->frame_ready = false;
            runtime->delivered_frame_serial = 0;
            if(startup_script != nullptr && startup_script[0] != '\0') {
                // TODO: honour an explicit startup script. ExHIBIT's
                // equivalent is `[exec] entry=` in ExHIBIT.ini; the core
                // always boots from the INI today, so record the request and
                // continue with the default entry.
                const std::string message =
                    "startup script requested but not honoured yet: " +
                    std::string(startup_script);
                if(runtime->host.log != nullptr) {
                    runtime->host.log(runtime->host.user_data,
                                      ENGINE_RUNTIME_LOG_INFO, "exhibit",
                                      message.c_str());
                }
            }
            // Unlike ONScripter, the core opens synchronously (marker probe,
            // then compose the initial picture), so the bool maps directly
            // onto the provider contract with no startup-state polling.
            if(!runtime->runtime.open_game(game_root)) {
                return Fail(runtime, ENGINE_RESULT_IO_ERROR,
                            runtime->runtime.last_error());
            }
            runtime->flush_logs();
            return ENGINE_RESULT_OK;
        }

        engine_result_t Tick(void *opaque, uint32_t delta_ms) {
            ProviderRuntime *runtime = Cast(opaque);
            if(runtime == nullptr) {
                return ENGINE_RESULT_INVALID_ARGUMENT;
            }
            runtime->flush_logs();
            if(runtime->paused) {
                return ENGINE_RESULT_OK;
            }
            if(runtime->runtime.tick(delta_ms)) {
                runtime->error.clear();
                return ENGINE_RESULT_OK;
            }
            return Fail(runtime, ENGINE_RESULT_INVALID_STATE,
                        runtime->runtime.last_error());
        }

        engine_result_t Pause(void *opaque) {
            ProviderRuntime *runtime = Cast(opaque);
            if(runtime == nullptr) {
                return ENGINE_RESULT_INVALID_ARGUMENT;
            }
            runtime->paused = true;
            return ENGINE_RESULT_OK;
        }

        engine_result_t Resume(void *opaque) {
            ProviderRuntime *runtime = Cast(opaque);
            if(runtime == nullptr) {
                return ENGINE_RESULT_INVALID_ARGUMENT;
            }
            runtime->paused = false;
            return ENGINE_RESULT_OK;
        }

        engine_result_t SetOption(void *opaque, const engine_option_t *option) {
            ProviderRuntime *runtime = Cast(opaque);
            if(runtime == nullptr || option == nullptr ||
               option->key_utf8 == nullptr) {
                return ENGINE_RESULT_INVALID_ARGUMENT;
            }
            const std::string value =
                option->value_utf8 != nullptr ? option->value_utf8 : "";
            // The core is lenient: unknown keys are accepted and ignored so
            // the shared player can broadcast its common option set.
            if(!runtime->runtime.set_option(option->key_utf8, value)) {
                return Fail(runtime, ENGINE_RESULT_INVALID_ARGUMENT,
                            runtime->runtime.last_error());
            }
            runtime->error.clear();
            return ENGINE_RESULT_OK;
        }

        engine_result_t SetSurfaceSize(void *opaque, uint32_t width,
                                       uint32_t height) {
            if(Cast(opaque) == nullptr || width == 0 || height == 0) {
                return ENGINE_RESULT_INVALID_ARGUMENT;
            }
            // ExHIBIT composes at script-native resolution. The shared Godot
            // player owns target-size scaling and frame enhancement.
            return ENGINE_RESULT_OK;
        }

        engine_result_t RefreshFrame(ProviderRuntime *runtime) {
            if(runtime == nullptr) {
                return ENGINE_RESULT_INVALID_ARGUMENT;
            }
            Frame frame;
            if(!runtime->runtime.read_frame(frame)) {
                return Fail(runtime, ENGINE_RESULT_INVALID_STATE,
                            runtime->runtime.last_error().empty()
                                ? "ExHIBIT frame is not ready"
                                : runtime->runtime.last_error());
            }
            runtime->frame = std::move(frame);
            runtime->frame_ready = true;
            runtime->error.clear();
            return ENGINE_RESULT_OK;
        }

        engine_result_t GetFrameDesc(void *opaque,
                                     engine_frame_desc_t *output) {
            ProviderRuntime *runtime = Cast(opaque);
            if(runtime == nullptr || output == nullptr ||
               output->struct_size < sizeof(engine_frame_desc_t)) {
                return ENGINE_RESULT_INVALID_ARGUMENT;
            }
            const engine_result_t result = RefreshFrame(runtime);
            if(result != ENGINE_RESULT_OK) {
                return result;
            }
            output->width = runtime->frame.width;
            output->height = runtime->frame.height;
            output->stride_bytes = runtime->frame.stride_bytes;
            output->pixel_format = ENGINE_PIXEL_FORMAT_RGBA8888;
            output->frame_serial = runtime->frame.serial;
            return ENGINE_RESULT_OK;
        }

        engine_result_t ReadFrame(void *opaque, void *output,
                                  size_t output_size) {
            ProviderRuntime *runtime = Cast(opaque);
            if(runtime == nullptr || output == nullptr) {
                return ENGINE_RESULT_INVALID_ARGUMENT;
            }
            if(!runtime->frame_ready) {
                const engine_result_t result = RefreshFrame(runtime);
                if(result != ENGINE_RESULT_OK) {
                    return result;
                }
            }
            if(output_size < runtime->frame.rgba.size()) {
                return Fail(runtime, ENGINE_RESULT_INVALID_ARGUMENT,
                            "RGBA frame output buffer is too small");
            }
            std::memcpy(output, runtime->frame.rgba.data(),
                        runtime->frame.rgba.size());
            runtime->delivered_frame_serial = runtime->frame.serial;
            runtime->error.clear();
            return ENGINE_RESULT_OK;
        }

        engine_result_t SendInput(void *opaque,
                                  const engine_input_event_t *event) {
            ProviderRuntime *runtime = Cast(opaque);
            if(runtime == nullptr || event == nullptr ||
               event->struct_size < sizeof(engine_input_event_t)) {
                return ENGINE_RESULT_INVALID_ARGUMENT;
            }

            InputEvent input;
            switch(event->type) {
                case ENGINE_INPUT_EVENT_POINTER_DOWN:
                    input.kind = InputKind::PointerDown;
                    break;
                case ENGINE_INPUT_EVENT_POINTER_MOVE:
                    input.kind = InputKind::PointerMove;
                    break;
                case ENGINE_INPUT_EVENT_POINTER_UP:
                    input.kind = InputKind::PointerUp;
                    break;
                case ENGINE_INPUT_EVENT_POINTER_SCROLL:
                    input.kind = InputKind::PointerScroll;
                    break;
                case ENGINE_INPUT_EVENT_KEY_DOWN:
                    input.kind = InputKind::KeyDown;
                    break;
                case ENGINE_INPUT_EVENT_KEY_UP:
                    input.kind = InputKind::KeyUp;
                    break;
                case ENGINE_INPUT_EVENT_TEXT_INPUT:
                    input.kind = InputKind::TextInput;
                    break;
                case ENGINE_INPUT_EVENT_BACK:
                    input.kind = InputKind::Back;
                    break;
                default:
                    return ENGINE_RESULT_INVALID_ARGUMENT;
            }
            input.pointer_id = event->pointer_id;
            input.x = event->x;
            input.y = event->y;
            input.delta_x = event->delta_x;
            input.delta_y = event->delta_y;
            input.button = event->button;
            input.key_code = event->key_code;
            input.modifiers = event->modifiers;
            input.unicode_codepoint = event->unicode_codepoint;
            if(!runtime->runtime.send_input(input)) {
                // send_input only fails on a saturated queue; report it so a
                // stuck VM drain stays visible instead of silently eating
                // clicks.
                return Fail(runtime, ENGINE_RESULT_INVALID_STATE,
                            runtime->runtime.last_error().empty()
                                ? "ExHIBIT input queue is saturated"
                                : runtime->runtime.last_error());
            }
            runtime->error.clear();
            return ENGINE_RESULT_OK;
        }

        engine_result_t GetFrameRenderedFlag(void *opaque, uint32_t *output) {
            ProviderRuntime *runtime = Cast(opaque);
            if(runtime == nullptr || output == nullptr) {
                return ENGINE_RESULT_INVALID_ARGUMENT;
            }
            const engine_result_t result = RefreshFrame(runtime);
            if(result != ENGINE_RESULT_OK) {
                *output = 0;
                return result;
            }
            *output = runtime->frame.serial != runtime->delivered_frame_serial
                ? 1u
                : 0u;
            return ENGINE_RESULT_OK;
        }

        engine_result_t GetRendererInfo(void *opaque, char *output,
                                        uint32_t output_size) {
            ProviderRuntime *runtime = Cast(opaque);
            if(runtime == nullptr) {
                return ENGINE_RESULT_INVALID_ARGUMENT;
            }
            return CopyString(runtime->runtime.renderer_info(), output,
                              output_size);
        }

        engine_result_t GetMemoryStats(void *opaque,
                                       engine_memory_stats_t *output) {
            if(Cast(opaque) == nullptr || output == nullptr ||
               output->struct_size < sizeof(engine_memory_stats_t)) {
                return ENGINE_RESULT_INVALID_ARGUMENT;
            }
            const uint32_t struct_size = output->struct_size;
            std::memset(output, 0, sizeof(*output));
            output->struct_size = struct_size;
            return ENGINE_RESULT_OK;
        }

        engine_result_t GetDebugInfo(void *opaque, char *output,
                                     uint32_t output_size,
                                     uint32_t *bytes_written) {
            if(Cast(opaque) == nullptr) {
                return ENGINE_RESULT_INVALID_ARGUMENT;
            }
            return CopyString(
                "runtime=exhibit provider=engine_runtime_provider_v1 "
                "integration=AetherRuntimePlayer vm=Game (own thread, "
                "host-thread tick and present)",
                output, output_size, bytes_written);
        }

        const char *GetLastError(void *opaque) {
            ProviderRuntime *runtime = Cast(opaque);
            if(runtime == nullptr) {
                return "ExHIBIT runtime handle is null";
            }
            if(runtime->error.empty()) {
                runtime->error = runtime->runtime.last_error();
            }
            if(runtime->error.empty()) {
                // The ABI contract forbids a null return; an empty string is
                // the "no error recorded" spelling.
                return "";
            }
            return runtime->error.c_str();
        }

        // Positional aggregate: C++17 has no designated initializers, so the
        // entries must stay in engine_runtime_provider_v1_t declaration order
        // with every field spelled out. Field map:
        //   1 struct_size                  2 api_version
        //   3 runtime_id_utf8              4 display_name_utf8
        //   5 priority                     6 provider_user_data
        //   7 probe                        8 create
        //   9 destroy                     10 open_game
        //  11 tick                        12 pause
        //  13 resume                      14 set_option
        //  15 set_surface_size            16 get_frame_desc
        //  17 read_frame_rgba             18 get_godot_native_frame_texture
        //  19 get_host_native_window      20 get_host_native_view
        //  21 send_input                  22 get_main_menu_json
        //  23 activate_menu_item          24 set_render_target_iosurface
        //  25 set_render_target_surface   26 get_frame_rendered_flag
        //  27 get_renderer_info           28 get_memory_stats
        //  29 get_plugin_debug_info       30 get_last_error
        //  31 reserved_u64                32 submit_platform_response
        //  33 get_text_input_state        34 get_godot_presentation_state
        //  35 get_text_input_details      36 copy_text_input_text
        //  37 reserved_ptr
        engine_runtime_provider_v1_t g_provider = {
            sizeof(engine_runtime_provider_v1_t),
            ENGINE_RUNTIME_PROVIDER_API_VERSION,
            "exhibit",
            "ExHIBIT",
            95,
            nullptr,
            Probe,
            Create,
            Destroy,
            OpenGame,
            Tick,
            Pause,
            Resume,
            SetOption,
            SetSurfaceSize,
            GetFrameDesc,
            ReadFrame,
            nullptr, // GPU texture handoff arrives with the GPU bridge step
            nullptr, // no native window embedding
            nullptr, // no native view embedding
            SendInput,
            nullptr, // no main menu export yet
            nullptr, // no menu activation yet
            nullptr, // macOS IOSurface target: not applicable
            nullptr, // Android Surface target: not applicable
            GetFrameRenderedFlag,
            GetRendererInfo,
            GetMemoryStats,
            GetDebugInfo,
            GetLastError,
            {},
            nullptr, // no platform request/response flow yet
            nullptr, // no IME text-input state yet
            nullptr, // no Godot presentation state yet
            nullptr, // no IME snapshot yet
            nullptr, // no IME text copy yet
            {}
        };

    } // namespace

    void RegisterRuntimeProvider() {
        static std::once_flag once;
        std::call_once(
            once, [] { (void)engine_register_runtime_provider(&g_provider); });
    }

} // namespace aetherkiri::exhibit
