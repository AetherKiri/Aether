#include "mages_runtime.h"

#include "engine_runtime_provider.h"
#include "mages_audio_output.h"
#include "impacto_host.h"

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <memory>
#include <new>
#include <optional>
#include <string>
#include <vector>

namespace aetherkiri::mages {
    namespace {
        constexpr const char* kRuntimeId = "mages";
        constexpr const char* kDisplayName = "MAGES. engine (impacto host bridge)";
        // Below siglus/onscripter (90) so directories both engines could read
        // keep their established resolution.
        constexpr int32_t kProviderPriority = 80;
        constexpr uint32_t kDefaultSurfaceWidth = 1920;
        constexpr uint32_t kDefaultSurfaceHeight = 1080;

        // The impacto distribution (profiles/, resources/, shaders/,
        // gamedefinitions.lua) the bridge boots from. The build injects the
        // package install prefix; AETHERKIRI_MAGES_DATA_DIR overrides it at
        // runtime for relocated setups.
        std::string ResolveDataDir(std::string& error) {
            if(const char* override_dir = std::getenv("AETHERKIRI_MAGES_DATA_DIR")) {
                if(override_dir[0] != '\0') {
                    return std::string(override_dir);
                }
            }
#ifdef AETHERKIRI_MAGES_DATA_DIR
            return std::string(AETHERKIRI_MAGES_DATA_DIR);
#else
            error = "no impacto data directory configured";
            return std::string();
#endif
        }

        // The impacto profile system is game-generic: every game registered
        // in the host package's gamedefinitions.lua (mo8, chlcc, cclcc,
        // mo6tw, darling, dash, rne, ...) mounts its archives from
        // <game-root>/<game-id>/ with a script.* or system.* archive in it.
        // The provider only recognises that layout; the host's "auto" mode
        // resolves the concrete registered game id.
        std::optional<std::string> DetectMagesInstallLayout(
            const std::filesystem::path& root) {
            std::error_code ec;
            if(!std::filesystem::is_directory(root, ec)) {
                return std::nullopt;
            }
            for(const auto& entry :
                std::filesystem::directory_iterator(root, ec)) {
                std::error_code entryEc;
                if(!entry.is_directory(entryEc) || entryEc) continue;
                std::string name = entry.path().filename().string();
                std::transform(name.begin(), name.end(), name.begin(),
                               [](unsigned char c) {
                                   return static_cast<char>(
                                       std::tolower(c));
                               });
                const std::filesystem::path gameDir = entry.path();
                for(const auto& file :
                    std::filesystem::directory_iterator(gameDir, entryEc)) {
                    std::error_code fileEc;
                    if(!file.is_regular_file(fileEc) || fileEc) continue;
                    std::string fileName = file.path().filename().string();
                    std::transform(fileName.begin(), fileName.end(),
                                   fileName.begin(), [](unsigned char c) {
                                       return static_cast<char>(
                                           std::tolower(c));
                                   });
                    if(fileName.rfind("script.", 0) == 0 ||
                       fileName.rfind("system.", 0) == 0) {
                        return name;
                    }
                }
            }
            return std::nullopt;
        }

        int32_t Probe(void*, const char* game_root_path) {
            if(game_root_path == nullptr || game_root_path[0] == '\0') {
                return 0;
            }
            try {
                const std::filesystem::path root(game_root_path);
                // MAGES. install layout: a <game-id>/ directory carrying
                // the script/system archives. The game id itself is
                // resolved against the host registry on open.
                if(DetectMagesInstallLayout(root)) {
                    return 85;
                }
                // PC layout: script.mpk/system.mpk at the game root. No
                // shipped profile mounts that layout yet, so this only
                // marks the directory as a MAGES. game; opening may be
                // limited until a PC profile lands.
                std::error_code ec;
                if(std::filesystem::exists(root / "script.mpk", ec) &&
                   std::filesystem::exists(root / "system.mpk", ec)) {
                    return 70;
                }
                return 0;
            } catch(...) {
                return 0;
            }
        }

        // Windows VK codes (the engine_api input domain) to the SDL scancode
        // values accepted by the impacto host bridge.
        uint32_t VkToSdlScancode(int32_t vk) {
            if(vk >= 'A' && vk <= 'Z') {
                return IMPACTO_HOST_SCANCODE_A + (vk - 'A');
            }
            if(vk >= '0' && vk <= '9') {
                return IMPACTO_HOST_SCANCODE_1 + (vk - '0');
            }
            if(vk >= 0x70 && vk <= 0x7B) {  // F1..F12
                return IMPACTO_HOST_SCANCODE_F1 + (vk - 0x70);
            }
            switch(vk) {
                case 0x08: return IMPACTO_HOST_SCANCODE_BACKSPACE;
                case 0x09: return IMPACTO_HOST_SCANCODE_TAB;
                case 0x0D: return IMPACTO_HOST_SCANCODE_RETURN;
                case 0x1B: return IMPACTO_HOST_SCANCODE_ESCAPE;
                case 0x20: return IMPACTO_HOST_SCANCODE_SPACE;
                case 0x21: return IMPACTO_HOST_SCANCODE_PAGEUP;
                case 0x22: return IMPACTO_HOST_SCANCODE_PAGEDOWN;
                case 0x23: return IMPACTO_HOST_SCANCODE_END;
                case 0x24: return IMPACTO_HOST_SCANCODE_HOME;
                case 0x25: return IMPACTO_HOST_SCANCODE_LEFT;
                case 0x26: return IMPACTO_HOST_SCANCODE_UP;
                case 0x27: return IMPACTO_HOST_SCANCODE_RIGHT;
                case 0x28: return IMPACTO_HOST_SCANCODE_DOWN;
                case 0x2D: return IMPACTO_HOST_SCANCODE_INSERT;
                case 0x2E: return IMPACTO_HOST_SCANCODE_DELETE;
                case 0xA0: return IMPACTO_HOST_SCANCODE_LSHIFT;
                case 0xA1: return IMPACTO_HOST_SCANCODE_RSHIFT;
                case 0xA2: return IMPACTO_HOST_SCANCODE_LCTRL;
                case 0xA3: return IMPACTO_HOST_SCANCODE_RCTRL;
                case 0xA4: return IMPACTO_HOST_SCANCODE_LALT;
                case 0xA5: return IMPACTO_HOST_SCANCODE_RALT;
                default: return 0;
            }
        }

        uint32_t MouseButtonToSdl(int32_t button) {
            switch(button) {
                case 0: return 1;  // left
                case 1: return 3;  // right
                case 2: return 2;  // middle
                default: return 0;
            }
        }

        engine_result_t MapImpactoResult(int32_t result) {
            switch(result) {
                case IMPACTO_HOST_OK: return ENGINE_RESULT_OK;
                case IMPACTO_HOST_INVALID_ARGUMENT:
                    return ENGINE_RESULT_INVALID_ARGUMENT;
                case IMPACTO_HOST_INVALID_STATE:
                    return ENGINE_RESULT_INVALID_STATE;
                case IMPACTO_HOST_NOT_SUPPORTED:
                    return ENGINE_RESULT_NOT_SUPPORTED;
                case IMPACTO_HOST_IO_ERROR:
                    return ENGINE_RESULT_IO_ERROR;
                default: return ENGINE_RESULT_INTERNAL_ERROR;
            }
        }

        struct ProviderRuntime {
            ProviderRuntime() = default;
            explicit ProviderRuntime(
                const engine_runtime_host_v1_t& host_in)
                : host(host_in) {}

            const engine_runtime_host_v1_t host{};
            void* impact = nullptr;
            bool opened = false;
            bool paused = false;
            bool terminated = false;
            uint32_t pending_width = kDefaultSurfaceWidth;
            uint32_t pending_height = kDefaultSurfaceHeight;
            std::string data_dir;

            // Latest frame served to the host. impacto renders at the design
            // resolution; the Aether presentation layer owns scaling.
            std::vector<uint8_t> frame_rgba;
            uint32_t frame_width = 0;
            uint32_t frame_height = 0;
            uint32_t frame_stride = 0;
            uint64_t frame_serial = 0;
            uint64_t delivered_frame_serial = 0;
            std::string error;
        };

        ProviderRuntime* Cast(void* runtime) {
            return static_cast<ProviderRuntime*>(runtime);
        }

        engine_result_t CopyString(const std::string& value, char* output,
                                   uint32_t output_size,
                                   uint32_t* bytes_written = nullptr) {
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

        void LogHost(ProviderRuntime* runtime, uint32_t level,
                     const char* message) {
            if(runtime != nullptr && runtime->host.log != nullptr) {
                runtime->host.log(runtime->host.user_data, level,
                                  kRuntimeId, message);
            }
        }

        // Refreshes the frame cache after a tick.
        engine_result_t RefreshFrame(ProviderRuntime* runtime) {
            uint32_t width = 0, height = 0, stride = 0;
            const int32_t desc = impacto_host_get_frame_desc(
                runtime->impact, &width, &height, &stride);
            if(desc != IMPACTO_HOST_OK) {
                runtime->error = "impacto_host_get_frame_desc: " +
                                 std::to_string(desc);
                return MapImpactoResult(desc);
            }
            if(width == 0 || height == 0) {
                // No frame produced yet (e.g. first ticks of the boot
                // sequence); keep the previous cache.
                return ENGINE_RESULT_OK;
            }
            const size_t needed = static_cast<size_t>(width) * height * 4u;
            if(runtime->frame_rgba.size() != needed) {
                runtime->frame_rgba.resize(needed);
            }
            const int32_t read = impacto_host_read_frame_rgba(
                runtime->impact, runtime->frame_rgba.data(), needed);
            if(read != IMPACTO_HOST_OK) {
                runtime->error = "impacto_host_read_frame_rgba: " +
                                 std::to_string(read);
                return MapImpactoResult(read);
            }
            runtime->frame_width = width;
            runtime->frame_height = height;
            runtime->frame_stride = stride != 0 ? stride : width * 4u;
            runtime->frame_serial += 1;
            return ENGINE_RESULT_OK;
        }

        engine_result_t Tick(void* opaque, uint32_t delta_ms) {
            ProviderRuntime* runtime = Cast(opaque);
            if(runtime == nullptr || runtime->impact == nullptr ||
               !runtime->opened) {
                return ENGINE_RESULT_INVALID_STATE;
            }
            if(runtime->terminated) {
                runtime->error = "runtime has been terminated";
                return ENGINE_RESULT_INVALID_STATE;
            }
            if(runtime->paused) return ENGINE_RESULT_OK;
            const int32_t step = impacto_host_tick(runtime->impact, delta_ms);
            if(step != IMPACTO_HOST_OK) {
                runtime->error = "impacto_host_tick: " + std::to_string(step);
                return MapImpactoResult(step);
            }
            if(impacto_host_should_quit(runtime->impact)) {
                LogHost(runtime, ENGINE_RUNTIME_LOG_INFO,
                        "engine requested exit");
                runtime->terminated = true;
                runtime->error = "runtime requested termination";
                audio::StopOutput();
                return ENGINE_RESULT_INVALID_STATE;
            }
            const engine_result_t refreshed = RefreshFrame(runtime);
            if(refreshed == ENGINE_RESULT_OK) {
                runtime->error.clear();
            }
            return refreshed;
        }

        engine_result_t Create(void*, const engine_runtime_host_v1_t* host,
                               const engine_create_desc_t* desc,
                               void** out_runtime) {
            if(host == nullptr || desc == nullptr || out_runtime == nullptr) {
                return ENGINE_RESULT_INVALID_ARGUMENT;
            }
            *out_runtime = nullptr;
            if(host->api_version != ENGINE_RUNTIME_PROVIDER_API_VERSION) {
                return ENGINE_RESULT_NOT_SUPPORTED;
            }

            std::string data_error;
            const std::string data_dir = ResolveDataDir(data_error);
            if(data_dir.empty()) {
                return ENGINE_RESULT_INTERNAL_ERROR;
            }
            std::error_code ec;
            if(!std::filesystem::is_directory(
                   std::filesystem::path(data_dir) / "profiles", ec) ||
               !std::filesystem::exists(
                   std::filesystem::path(data_dir) / "gamedefinitions.lua",
                   ec)) {
                return ENGINE_RESULT_IO_ERROR;
            }

            // The writable path is the engine's own generated-file area
            // (userconfig, basepaths, saves).
            const char* writable_path =
                desc->writable_path_utf8 != nullptr &&
                        desc->writable_path_utf8[0] != '\0'
                    ? desc->writable_path_utf8
                    : "/tmp";
            std::filesystem::create_directories(writable_path, ec);

            auto runtime = std::unique_ptr<ProviderRuntime>(
                new(std::nothrow) ProviderRuntime(*host));
            if(!runtime) {
                return ENGINE_RESULT_INTERNAL_ERROR;
            }
            runtime->data_dir = data_dir;

            impacto_host_desc_t impacto_desc{};
            impacto_desc.struct_size = sizeof(impacto_desc);
            impacto_desc.api_version = IMPACTO_HOST_API_VERSION;
            impacto_desc.data_dir_utf8 = runtime->data_dir.c_str();
            impacto_desc.writable_dir_utf8 = writable_path;
            impacto_desc.initial_width = runtime->pending_width;
            impacto_desc.initial_height = runtime->pending_height;
            impacto_desc.log_level = 3;  // Warning and up to stderr.
            const int32_t created =
                impacto_host_create(&impacto_desc, &runtime->impact);
            if(created != IMPACTO_HOST_OK) {
                runtime->error = "impacto_host_create: " +
                                 std::to_string(created);
                return MapImpactoResult(created);
            }

            *out_runtime = runtime.release();
            return ENGINE_RESULT_OK;
        }

        void Destroy(void* runtime) {
            ProviderRuntime* instance = Cast(runtime);
            if(instance == nullptr) {
                return;
            }
            audio::StopOutput();
            if(instance->impact != nullptr) {
                impacto_host_destroy(instance->impact);
                instance->impact = nullptr;
            }
            delete instance;
        }

        engine_result_t OpenGame(void* runtime,
                                 const char* game_root_path_utf8,
                                 const char*) {
            ProviderRuntime* instance = Cast(runtime);
            if(instance == nullptr || instance->impact == nullptr ||
               game_root_path_utf8 == nullptr ||
               game_root_path_utf8[0] == '\0') {
                return ENGINE_RESULT_INVALID_ARGUMENT;
            }
            if(instance->opened) {
                // The embedded engine is single-open by construction; a
                // second open needs a fresh provider runtime.
                instance->error =
                    "impacto host bridge supports one game per runtime";
                return ENGINE_RESULT_NOT_SUPPORTED;
            }

            // A root carrying the MAGES. install layout is opened through
            // the host's "auto" mode, which resolves the registered game id
            // from gamedefinitions.lua; any other root (including one with
            // an unregistered or PC-layout game) falls back to the engine's
            // data-free launcher loop, which still renders frames at the
            // design resolution.
            const std::filesystem::path gamedata(game_root_path_utf8);
            const std::optional<std::string> detected =
                DetectMagesInstallLayout(gamedata);
            const char* game_id = detected ? "auto" : "launcher";
            if(!detected) {
                LogHost(instance, ENGINE_RUNTIME_LOG_WARNING,
                        "no MAGES. game data found; opening the data-free "
                        "launcher loop");
            }

            const int32_t result = impacto_host_open_game(
                instance->impact, game_root_path_utf8, game_id,
                gamedata.string().c_str());
            if(result != IMPACTO_HOST_OK) {
                const char* detail =
                    impacto_host_get_last_error(instance->impact);
                instance->error = std::string("impacto_host_open_game: ") +
                                  (detail != nullptr ? detail : "");
                LogHost(instance, ENGINE_RUNTIME_LOG_ERROR,
                        (std::string("open failed: ") + instance->error)
                            .c_str());
                return MapImpactoResult(result);
            }

            instance->opened = true;
            instance->paused = false;
            instance->terminated = false;
            instance->error.clear();
            audio::SetPaused(false);
            LogHost(instance, ENGINE_RUNTIME_LOG_INFO, "mages game opened");
            // Wire the impacto mixer FIFO to an OpenAL streaming output;
            // failure only downgrades to silence.
            std::string audio_error;
            if(!audio::StartOutput(instance->impact, audio_error)) {
                LogHost(instance, ENGINE_RUNTIME_LOG_WARNING,
                        ("mages audio disabled: " + audio_error).c_str());
            }
            return RefreshFrame(instance);
        }

        engine_result_t Pause(void* runtime) {
            auto* instance = Cast(runtime);
            if(instance == nullptr || !instance->opened) {
                return ENGINE_RESULT_INVALID_STATE;
            }
            const int32_t result = impacto_host_set_paused(instance->impact, 1);
            if(result == IMPACTO_HOST_OK) {
                instance->paused = true;
                audio::SetPaused(true);
            }
            return MapImpactoResult(result);
        }

        engine_result_t Resume(void* runtime) {
            auto* instance = Cast(runtime);
            if(instance == nullptr || !instance->opened) {
                return ENGINE_RESULT_INVALID_STATE;
            }
            const int32_t result = impacto_host_set_paused(instance->impact, 0);
            if(result == IMPACTO_HOST_OK) {
                instance->paused = false;
                audio::SetPaused(false);
            }
            return MapImpactoResult(result);
        }

        engine_result_t SetOption(void* runtime,
                                  const engine_option_t* option) {
            ProviderRuntime* instance = Cast(runtime);
            if(instance == nullptr || option == nullptr ||
               option->key_utf8 == nullptr || option->value_utf8 == nullptr) {
                return ENGINE_RESULT_INVALID_ARGUMENT;
            }
            return ENGINE_RESULT_NOT_SUPPORTED;
        }

        engine_result_t SetSurfaceSize(void* runtime, uint32_t width,
                                       uint32_t height) {
            ProviderRuntime* instance = Cast(runtime);
            if(instance == nullptr || width == 0 || height == 0) {
                return ENGINE_RESULT_INVALID_ARGUMENT;
            }
            instance->pending_width = width;
            instance->pending_height = height;
            // Presentations scale on the host side; the engine keeps its
            // design resolution. The size applies to the next open.
            return ENGINE_RESULT_OK;
        }

        engine_result_t GetFrameDesc(void* runtime,
                                     engine_frame_desc_t* out_frame_desc) {
            ProviderRuntime* instance = Cast(runtime);
            if(instance == nullptr || out_frame_desc == nullptr ||
               out_frame_desc->struct_size < sizeof(engine_frame_desc_t)) {
                return ENGINE_RESULT_INVALID_ARGUMENT;
            }
            const uint32_t struct_size = out_frame_desc->struct_size;
            std::memset(out_frame_desc, 0, sizeof(*out_frame_desc));
            out_frame_desc->struct_size = struct_size;
            out_frame_desc->width = instance->frame_width;
            out_frame_desc->height = instance->frame_height;
            out_frame_desc->stride_bytes = instance->frame_stride;
            out_frame_desc->pixel_format = ENGINE_PIXEL_FORMAT_RGBA8888;
            out_frame_desc->frame_serial = instance->frame_serial;
            return ENGINE_RESULT_OK;
        }

        engine_result_t ReadFrame(void* runtime, void* out_pixels,
                                  size_t out_pixels_size) {
            ProviderRuntime* instance = Cast(runtime);
            if(instance == nullptr || out_pixels == nullptr) {
                return ENGINE_RESULT_INVALID_ARGUMENT;
            }
            const size_t frame_bytes = instance->frame_rgba.size();
            if(frame_bytes == 0) {
                instance->error = "no frame rendered yet";
                return ENGINE_RESULT_INVALID_STATE;
            }
            if(out_pixels_size < frame_bytes) {
                instance->error = "RGBA frame output buffer is too small";
                return ENGINE_RESULT_INVALID_ARGUMENT;
            }
            std::memcpy(out_pixels, instance->frame_rgba.data(), frame_bytes);
            instance->delivered_frame_serial = instance->frame_serial;
            instance->error.clear();
            return ENGINE_RESULT_OK;
        }

        engine_result_t SendInput(void* runtime,
                                  const engine_input_event_t* event) {
            ProviderRuntime* instance = Cast(runtime);
            if(instance == nullptr || instance->impact == nullptr ||
               !instance->opened || event == nullptr ||
               event->struct_size < sizeof(engine_input_event_t)) {
                return ENGINE_RESULT_INVALID_ARGUMENT;
            }
            int32_t result = IMPACTO_HOST_OK;
            switch(event->type) {
                case ENGINE_INPUT_EVENT_POINTER_DOWN:
                case ENGINE_INPUT_EVENT_POINTER_UP:
                    result = impacto_host_send_pointer(
                        instance->impact, event->x, event->y,
                        static_cast<int32_t>(MouseButtonToSdl(event->button)),
                        event->type == ENGINE_INPUT_EVENT_POINTER_DOWN ? 1 : 0);
                    break;
                case ENGINE_INPUT_EVENT_POINTER_MOVE:
                    result = impacto_host_send_pointer(
                        instance->impact, event->x, event->y, 0, -1);
                    break;
                case ENGINE_INPUT_EVENT_POINTER_SCROLL:
                    result = impacto_host_send_wheel(
                        instance->impact, event->delta_x, event->delta_y);
                    break;
                case ENGINE_INPUT_EVENT_KEY_DOWN:
                case ENGINE_INPUT_EVENT_KEY_UP: {
                    const uint32_t scancode = VkToSdlScancode(event->key_code);
                    if(scancode == 0) {
                        // Unmapped key; drop silently to keep the game
                        // unaffected.
                        return ENGINE_RESULT_OK;
                    }
                    result = impacto_host_send_key(
                        instance->impact, scancode,
                        event->type == ENGINE_INPUT_EVENT_KEY_DOWN ? 1 : 0);
                    break;
                }
                case ENGINE_INPUT_EVENT_TEXT_INPUT: {
                    // Encode the single Unicode scalar value as UTF-8.
                    char utf8[5] = {0, 0, 0, 0, 0};
                    uint32_t cp = event->unicode_codepoint;
                    if(cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) {
                        return ENGINE_RESULT_INVALID_ARGUMENT;
                    }
                    size_t length = 0;
                    if(cp <= 0x7F) {
                        utf8[length++] = static_cast<char>(cp);
                    } else if(cp <= 0x7FF) {
                        utf8[length++] = static_cast<char>(0xC0 | (cp >> 6));
                        utf8[length++] =
                            static_cast<char>(0x80 | (cp & 0x3F));
                    } else if(cp <= 0xFFFF) {
                        utf8[length++] =
                            static_cast<char>(0xE0 | (cp >> 12));
                        utf8[length++] =
                            static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
                        utf8[length++] =
                            static_cast<char>(0x80 | (cp & 0x3F));
                    } else {
                        utf8[length++] =
                            static_cast<char>(0xF0 | (cp >> 18));
                        utf8[length++] =
                            static_cast<char>(0x80 | ((cp >> 12) & 0x3F));
                        utf8[length++] =
                            static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
                        utf8[length++] =
                            static_cast<char>(0x80 | (cp & 0x3F));
                    }
                    result = impacto_host_send_text(instance->impact, utf8);
                    break;
                }
                case ENGINE_INPUT_EVENT_BACK:
                    result = impacto_host_send_key(
                        instance->impact, IMPACTO_HOST_SCANCODE_ESCAPE, 1);
                    if(result == IMPACTO_HOST_OK) {
                        result = impacto_host_send_key(
                            instance->impact, IMPACTO_HOST_SCANCODE_ESCAPE, 0);
                    }
                    break;
                default:
                    return ENGINE_RESULT_INVALID_ARGUMENT;
            }
            if(result != IMPACTO_HOST_OK) {
                instance->error =
                    "impacto input dispatch: " + std::to_string(result);
            }
            return MapImpactoResult(result);
        }

        engine_result_t GetFrameRenderedFlag(void* runtime,
                                             uint32_t* out_rendered) {
            ProviderRuntime* instance = Cast(runtime);
            if(instance == nullptr || out_rendered == nullptr) {
                return ENGINE_RESULT_INVALID_ARGUMENT;
            }
            *out_rendered =
                instance->frame_serial != instance->delivered_frame_serial
                    ? 1u
                    : 0u;
            return ENGINE_RESULT_OK;
        }

        engine_result_t GetRendererInfo(void* runtime, char* output,
                                        uint32_t output_size) {
            ProviderRuntime* instance = Cast(runtime);
            if(instance == nullptr || output == nullptr) {
                return ENGINE_RESULT_INVALID_ARGUMENT;
            }
            std::string info =
                "runtime=mages provider=engine_runtime_provider_v1 "
                "render=opengl-offscreen-readback";
            if(instance->impact != nullptr) {
                const char* impacto_info =
                    impacto_host_get_renderer_info(instance->impact);
                if(impacto_info != nullptr) {
                    info += " ";
                    info += impacto_info;
                }
            }
            return CopyString(info, output, output_size);
        }

        engine_result_t GetDebugInfo(void* runtime, char* output,
                                     uint32_t output_size,
                                     uint32_t* bytes_written) {
            ProviderRuntime* instance = Cast(runtime);
            if(instance == nullptr) {
                return ENGINE_RESULT_INVALID_ARGUMENT;
            }
            uint64_t written = 0, dropped = 0;
            if(instance->impact != nullptr) {
                impacto_host_get_audio_stats(instance->impact, &written,
                                             &dropped);
            }
            return CopyString(
                "runtime=mages audio_frames_written=" +
                    std::to_string(written) +
                    " audio_frames_dropped=" + std::to_string(dropped),
                output, output_size, bytes_written);
        }

        const char* GetLastError(void* runtime) {
            ProviderRuntime* instance = Cast(runtime);
            if(instance == nullptr) {
                return "MAGES. runtime handle is null";
            }
            if(!instance->error.empty()) {
                return instance->error.c_str();
            }
            if(instance->impact != nullptr) {
                const char* detail =
                    impacto_host_get_last_error(instance->impact);
                if(detail != nullptr) {
                    return detail;
                }
            }
            return "";
        }

        engine_runtime_provider_v1_t MakeProvider() {
            engine_runtime_provider_v1_t provider{};
            provider.struct_size = sizeof(provider);
            provider.api_version = ENGINE_RUNTIME_PROVIDER_API_VERSION;
            provider.runtime_id_utf8 = kRuntimeId;
            provider.display_name_utf8 = kDisplayName;
            provider.priority = kProviderPriority;
            provider.provider_user_data = nullptr;

            provider.probe = Probe;
            provider.create = Create;
            provider.destroy = Destroy;
            provider.open_game = OpenGame;
            provider.tick = Tick;
            provider.pause = Pause;
            provider.resume = Resume;
            provider.set_option = SetOption;
            provider.set_surface_size = SetSurfaceSize;
            provider.get_frame_desc = GetFrameDesc;
            provider.read_frame_rgba = ReadFrame;
            provider.get_godot_native_frame_texture =
                [](void*, uint64_t*, uint32_t*, uint32_t*, uint64_t*) {
                    return ENGINE_RESULT_NOT_SUPPORTED;
                };
            provider.get_host_native_window =
                [](void*, void**) { return ENGINE_RESULT_NOT_SUPPORTED; };
            provider.get_host_native_view =
                [](void*, void**) { return ENGINE_RESULT_NOT_SUPPORTED; };
            provider.send_input = SendInput;
            provider.get_main_menu_json =
                [](void*, char*, uint32_t, uint32_t*) {
                    return ENGINE_RESULT_NOT_SUPPORTED;
                };
            provider.activate_menu_item =
                [](void*, const char*) {
                    return ENGINE_RESULT_NOT_SUPPORTED;
                };
            provider.set_render_target_iosurface =
                [](void*, uint32_t, uint32_t, uint32_t) {
                    return ENGINE_RESULT_NOT_SUPPORTED;
                };
            provider.set_render_target_surface =
                [](void*, void*, uint32_t, uint32_t) {
                    return ENGINE_RESULT_NOT_SUPPORTED;
                };
            provider.get_frame_rendered_flag = GetFrameRenderedFlag;
            provider.get_renderer_info = GetRendererInfo;
            provider.get_memory_stats =
                [](void*, engine_memory_stats_t*) {
                    return ENGINE_RESULT_NOT_SUPPORTED;
                };
            provider.get_plugin_debug_info = GetDebugInfo;
            provider.get_last_error = GetLastError;
            provider.submit_platform_response =
                [](void*, const char*, const char*) {
                    return ENGINE_RESULT_NOT_SUPPORTED;
                };
            provider.get_text_input_state =
                [](void*, uint32_t* out_state_flags) {
                    if(out_state_flags != nullptr) {
                        *out_state_flags = 0;
                    }
                    return ENGINE_RESULT_OK;
                };
            provider.get_godot_presentation_state =
                [](void*, uint32_t* out_state_flags) {
                    if(out_state_flags != nullptr) {
                        *out_state_flags = 0;
                    }
                    return ENGINE_RESULT_OK;
                };
            return provider;
        }

        engine_result_t RegisterOnce() {
            static engine_runtime_provider_v1_t provider = MakeProvider();
            return engine_register_runtime_provider(&provider);
        }
    }  // namespace

    void RegisterRuntimeProvider() {
        // Registration failures must not crash the host; the runtime simply
        // stays unavailable and probe() reports no match.
        (void)RegisterOnce();
    }

}  // namespace aetherkiri::mages
