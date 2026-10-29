#include "xsystem4_runtime_provider.h"
#include "offscreen_context.h"
#include "shader_resources.h"
extern "C" {
#include "embedded.h"
#include "input.h"
void xsystem4_audio_pause(bool paused);
}
#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <memory>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <thread>
#include <uchardet/uchardet.h>

namespace aetherkiri::xsystem4 {
    namespace {
        namespace fs = std::filesystem;
        std::atomic<void *> active_runtime{ nullptr };
        std::string Lower(std::string value) {
            for(char &c : value)
                if(c >= 'A' && c <= 'Z')
                    c += 'a' - 'A';
            return value;
        }
        bool LooksLikeGame(const char *path) {
            if(!path || !*path)
                return false;
            bool ini = false, ain = false;
            std::error_code error;
            for(const auto &file :
                fs::directory_iterator(fs::u8path(path), error)) {
                if(!file.is_regular_file(error))
                    continue;
                auto name = Lower(file.path().filename().u8string());
                ini |= name == "system40.ini" || name == "alicestart.ini";
                ain |= Lower(file.path().extension().u8string()) == ".ain";
            }
            return !error && ini && ain;
        }
        std::string GameIdentity(const std::string &root) {
            uint64_t value = 14695981039346656037ull;
            auto append = [&](const std::string &data) {
                for(unsigned char c : data) {
                    value ^= c;
                    value *= 1099511628211ull;
                }
            };
            // iOS container prefixes change after an app update. Identify the
            // script content rather than the absolute import path so saves
            // remain reachable.
            std::vector<fs::path> scripts;
            for(const auto &entry : fs::directory_iterator(fs::u8path(root)))
                if(entry.is_regular_file() &&
                   Lower(entry.path().extension().u8string()) == ".ain")
                    scripts.push_back(entry.path());
            std::sort(scripts.begin(), scripts.end(),
                      [](const auto &a, const auto &b) {
                          return Lower(a.filename().u8string()) <
                              Lower(b.filename().u8string());
                      });
            for(const auto &script : scripts) {
                append(Lower(script.filename().u8string()));
                append(std::to_string(fs::file_size(script)));
                std::ifstream stream(script, std::ios::binary);
                std::string data(65536, '\0');
                stream.read(data.data(), data.size());
                data.resize(stream.gcount());
                if(stream.bad())
                    throw std::runtime_error(
                        "Could not read the System 4 script identity");
                append(data);
            }
            std::ostringstream result;
            result << std::hex << value;
            return result.str();
        }
        bool LooksLikeGbk(const std::string &sample) {
            if(sample.empty())
                return false;
            uchardet_t detector = uchardet_new();
            if(!detector)
                return false;
            // A few GBK characters can be reported as UTF-8 with insufficient
            // statistical evidence, even when their bytes are not valid UTF-8.
            // Repeat short text at line boundaries to give the detector enough
            // observations, without admitting comments into the sample.
            std::string observations = sample;
            while(observations.size() < 128) {
                observations += '\n';
                observations += sample;
            }
            uchardet_handle_data(detector, observations.data(),
                                 observations.size());
            uchardet_data_end(detector);
            const std::string encoding = Lower(uchardet_get_charset(detector));
            uchardet_delete(detector);
            return encoding == "gb18030" || encoding == "gb2312" ||
                encoding == "gbk" || encoding == "hz-gb-2312";
        }
        std::string DetectEncoding(const std::string &root) {
            for(const auto &entry : fs::directory_iterator(fs::u8path(root))) {
                const auto name = Lower(entry.path().filename().u8string());
                if(name != "system40.ini" && name != "alicestart.ini")
                    continue;
                std::ifstream stream(entry.path(), std::ios::binary);
                std::string data(65536, '\0');
                stream.read(data.data(), data.size());
                data.resize(stream.gcount());
                // Translations often retain Shift-JIS comments while replacing
                // the actual values with GBK. Comments must not determine the
                // encoding used for script filenames and in-game text.
                std::istringstream lines(data);
                std::string sample, title, line;
                while(std::getline(lines, line)) {
                    bool quoted = false;
                    for(size_t i = 0; i < line.size(); i++) {
                        if(line[i] == '"')
                            quoted = !quoted;
                        if(!quoted &&
                           (line[i] == ';' || line.compare(i, 2, "//") == 0)) {
                            line.resize(i);
                            break;
                        }
                    }
                    const auto start = line.find_first_not_of(" \t\r");
                    if(start == std::string::npos)
                        continue;
                    sample += line;
                    sample += '\n';
                    const auto key_end = line.find_first_of(" \t=", start);
                    if(line.substr(start, key_end - start) != "GameName")
                        continue;
                    const auto equals = line.find('=', key_end);
                    if(equals == std::string::npos)
                        continue;
                    const auto first =
                        line.find_first_not_of(" \t", equals + 1);
                    if(first == std::string::npos || line[first] != '"')
                        continue;
                    const auto last = line.find('"', first + 1);
                    if(last != std::string::npos)
                        title = line.substr(first + 1, last - first - 1);
                }
                // A translated title takes priority over original Japanese
                // labels left in other values (e.g. mixer channel names).
                // Without positive GBK evidence, keep the Japanese default.
                if(LooksLikeGbk(title) || LooksLikeGbk(sample))
                    return "gbk";
            }
            return "sjis";
        }
        struct Frame {
            uint32_t width = 0, height = 0;
            uint64_t serial = 0;
            std::vector<uint8_t> pixels;
        };
        struct Runtime {
            engine_runtime_host_v1_t host{};
            std::string writable, root, saves, font, error, encoding = "auto",
                                                            selected_encoding;
            std::mutex mutex, input_mutex;
            std::condition_variable condition;
            std::thread worker;
            std::atomic<bool> stopping{ false }, paused{ false };
            std::atomic<bool> text_input{ false };
            std::atomic<uint32_t> fps{ 60 };
            bool ended = false, ready = false, requested_exit = false;
            std::shared_ptr<Frame> frame, snapshot;
            std::atomic<uint64_t> serial{ 0 };
            uint64_t delivered = 0;
            std::deque<SDL_Event> input;
            // Do not drain a press and its release in the same VM input poll.
            // System4 games read held key/button state after polling, rather
            // than the events.
            std::chrono::steady_clock::time_point next_button_event;
            int mouse_x = 0, mouse_y = 0;
            OffscreenContext *graphics = nullptr;
            std::chrono::steady_clock::time_point last_present;
            Runtime(const engine_runtime_host_v1_t *h,
                    const engine_create_desc_t *desc) : host(*h) {
                if(desc->writable_path_utf8)
                    writable = desc->writable_path_utf8;
            }
            ~Runtime() { stop(); }
            void fail(const std::string &message) {
                std::lock_guard<std::mutex> guard(mutex);
                if(error.empty())
                    error = message;
                condition.notify_all();
            }
            void stop() {
                stopping = true;
                paused = false;
                condition.notify_all();
                if(worker.joinable())
                    worker.join();
            }
            bool checkpoint() {
                if(stopping)
                    return true;
                if(paused) {
                    key_clear_flag(false);
                    {
                        std::lock_guard<std::mutex> guard(input_mutex);
                        input.clear();
                    }
                    xsystem4_audio_pause(true);
                    std::unique_lock<std::mutex> guard(mutex);
                    condition.wait(guard, [&] { return !paused || stopping; });
                    guard.unlock();
                    xsystem4_audio_pause(false);
                }
                return stopping;
            }
            void publish(int width, int height) {
                auto next = std::make_shared<Frame>();
                std::string message;
                if(width < 1 || height < 1 || width > 8192 || height > 8192 ||
                   !graphics->read(next->pixels, message)) {
                    fail(message.empty() ? "Invalid native frame dimensions"
                                         : message);
                    stopping = true;
                    return;
                }
                next->width = width;
                next->height = height;
                next->serial = ++serial;
                if(next->pixels.size() != size_t(width) * height * 4) {
                    fail("The native frame size changed unexpectedly");
                    stopping = true;
                    return;
                }
                {
                    std::lock_guard<std::mutex> guard(mutex);
                    frame = std::move(next);
                    ready = true;
                    condition.notify_all();
                }
                const uint32_t limit = fps.load();
                if(limit) {
                    auto deadline = last_present +
                        std::chrono::microseconds(1000000 / limit);
                    std::unique_lock<std::mutex> guard(mutex);
                    condition.wait_until(guard, deadline, [&] {
                        return stopping.load() || paused.load();
                    });
                }
                last_present = std::chrono::steady_clock::now();
            }
            void run() {
                OffscreenContext context;
                graphics = &context;
                xsystem4_host hooks{};
                hooks.user = this;
                hooks.init_graphics = [](void *p, int w, int h) -> int {
                    auto &self = *static_cast<Runtime *>(p);
                    std::string message;
                    try {
                        if(self.graphics->initialize(w, h, message))
                            return 1;
                    } catch(const std::exception &error) {
                        message = error.what();
                    }
                    self.fail(message);
                    return 0;
                };
                hooks.framebuffer = [](void *p) {
                    return static_cast<Runtime *>(p)->graphics->framebuffer();
                };
                hooks.present = [](void *p, int w, int h) {
                    auto &self = *static_cast<Runtime *>(p);
                    try {
                        self.publish(w, h);
                    } catch(const std::exception &error) {
                        self.fail(error.what());
                        self.stopping = true;
                    }
                };
                hooks.poll_event = [](void *p, SDL_Event *event) -> int {
                    auto &self = *static_cast<Runtime *>(p);
                    std::lock_guard<std::mutex> guard(self.input_mutex);
                    if(self.input.empty())
                        return 0;
                    const auto type = self.input.front().type;
                    const bool transition = type == SDL_MOUSEBUTTONDOWN ||
                        type == SDL_MOUSEBUTTONUP || type == SDL_KEYDOWN ||
                        type == SDL_KEYUP;
                    const auto now = std::chrono::steady_clock::now();
                    if(transition && now < self.next_button_event)
                        return 0;
                    if(transition)
                        self.next_button_event =
                            now + std::chrono::milliseconds(16);
                    *event = self.input.front();
                    self.input.pop_front();
                    if(event->type == SDL_MOUSEMOTION) {
                        self.mouse_x = event->motion.x;
                        self.mouse_y = event->motion.y;
                    }
                    if(event->type == SDL_MOUSEBUTTONDOWN ||
                       event->type == SDL_MOUSEBUTTONUP) {
                        self.mouse_x = event->button.x;
                        self.mouse_y = event->button.y;
                    }
                    return 1;
                };
                hooks.mouse_position = [](void *p, int *x, int *y, int set) {
                    auto &self = *static_cast<Runtime *>(p);
                    if(set) {
                        self.mouse_x = *x;
                        self.mouse_y = *y;
                    } else {
                        *x = self.mouse_x;
                        *y = self.mouse_y;
                    }
                };
                hooks.checkpoint = [](void *p) -> int {
                    return static_cast<Runtime *>(p)->checkpoint();
                };
                hooks.text_input = [](void *p, int active) {
                    static_cast<Runtime *>(p)->text_input = active != 0;
                };
                hooks.shader = [](void *, const char *path) -> const char * {
                    for(const auto &shader : xsystem4_shaders)
                        if(!std::strcmp(shader.path, path))
                            return shader.source;
                    return nullptr;
                };
                hooks.log = [](void *p, const char *message) {
                    auto &self = *static_cast<Runtime *>(p);
                    self.fail(message ? message : "xsystem4 reported an error");
                    if(self.host.log)
                        self.host.log(self.host.user_data,
                                      ENGINE_RUNTIME_LOG_ERROR, "xsystem4",
                                      message);
                };
                hooks.game_exit = [](void *p, int) {
                    auto &self = *static_cast<Runtime *>(p);
                    std::lock_guard<std::mutex> guard(self.mutex);
                    self.requested_exit = true;
                };
                std::string session_font;
                {
                    std::lock_guard<std::mutex> guard(mutex);
                    session_font = font;
                }
                const int result = xsystem4_host_run(
                    &hooks, root.c_str(), saves.c_str(), session_font.c_str(),
                    selected_encoding.c_str());
                {
                    std::lock_guard<std::mutex> guard(mutex);
                    ended = true;
                    if(result && !requested_exit && error.empty())
                        error = "The System 4 VM exited with code " +
                            std::to_string(result);
                    condition.notify_all();
                }
                graphics = nullptr;
                text_input = false;
                void *expected = this;
                active_runtime.compare_exchange_strong(expected, nullptr);
            }
        };
        engine_result_t Copy(const std::string &text, char *out, uint32_t size,
                             uint32_t *written = nullptr) {
            if(!out || !size)
                return ENGINE_RESULT_INVALID_ARGUMENT;
            const size_t count = std::min(text.size(), size_t(size - 1));
            std::memcpy(out, text.data(), count);
            out[count] = 0;
            if(written)
                *written = uint32_t(count);
            return count == text.size() ? ENGINE_RESULT_OK
                                        : ENGINE_RESULT_INVALID_ARGUMENT;
        }
        int32_t Probe(void *, const char *path) {
            try {
                return LooksLikeGame(path) ? 100 : 0;
            } catch(...) {
                return 0;
            }
        }
        engine_result_t Create(void *, const engine_runtime_host_v1_t *host,
                               const engine_create_desc_t *desc, void **out) {
            if(!host || !desc || !out || host->struct_size < sizeof(*host) ||
               desc->struct_size < sizeof(*desc) ||
               desc->api_version != ENGINE_API_VERSION ||
               host->api_version != ENGINE_RUNTIME_PROVIDER_API_VERSION)
                return ENGINE_RESULT_INVALID_ARGUMENT;
            *out = nullptr;
            try {
                *out = new Runtime(host, desc);
                return ENGINE_RESULT_OK;
            } catch(...) {
                return ENGINE_RESULT_INTERNAL_ERROR;
            }
        }
        void Destroy(void *opaque) { delete static_cast<Runtime *>(opaque); }
        engine_result_t Open(void *opaque, const char *path, const char *) {
            auto *self = static_cast<Runtime *>(opaque);
            if(!self || !path)
                return ENGINE_RESULT_INVALID_ARGUMENT;
            if(!Probe(nullptr, path)) {
                self->fail("Select a System 4 folder containing its INI and "
                           "AIN files");
                return ENGINE_RESULT_INVALID_ARGUMENT;
            }
            self->stop();
            void *expected = nullptr;
            if(!active_runtime.compare_exchange_strong(expected, self)) {
                self->fail("Another System 4 game is running");
                return ENGINE_RESULT_INVALID_STATE;
            }
            try {
                self->root = fs::absolute(fs::u8path(path))
                                 .lexically_normal()
                                 .u8string();
                {
                    std::lock_guard<std::mutex> guard(self->mutex);
                    self->selected_encoding = self->encoding == "auto"
                        ? DetectEncoding(self->root)
                        : self->encoding;
                }
                if(self->writable.empty())
                    throw std::runtime_error(
                        "A writable save directory is required");
                self->saves = (fs::u8path(self->writable) / "xsystem4" /
                               GameIdentity(self->root))
                                  .u8string();
                fs::create_directories(fs::u8path(self->saves));
                {
                    std::lock_guard<std::mutex> guard(self->mutex);
                    self->error.clear();
                    self->ready = self->ended = self->requested_exit = false;
                    self->frame.reset();
                    self->snapshot.reset();
                    self->delivered = 0;
                }
                self->stopping = self->paused = false;
                {
                    std::lock_guard<std::mutex> guard(self->input_mutex);
                    self->input.clear();
                    self->next_button_event = {};
                    self->mouse_x = self->mouse_y = 0;
                }
                self->worker = std::thread([self] {
                    try {
                        self->run();
                    } catch(const std::exception &error) {
                        self->fail(error.what());
                        {
                            std::lock_guard<std::mutex> guard(self->mutex);
                            self->ended = true;
                            self->condition.notify_all();
                        }
                        void *value = self;
                        active_runtime.compare_exchange_strong(value, nullptr);
                    }
                });
                bool succeeded;
                {
                    std::unique_lock<std::mutex> guard(self->mutex);
                    self->condition.wait_for(
                        guard, std::chrono::seconds(45),
                        [&] { return self->ready || self->ended; });
                    succeeded = self->ready && self->error.empty();
                }
                if(!succeeded) {
                    {
                        std::lock_guard<std::mutex> guard(self->mutex);
                        if(self->error.empty())
                            self->error = self->ended
                                ? "System 4 runtime requested termination"
                                : "System 4 did not produce a startup frame";
                    }
                    self->stop();
                    return ENGINE_RESULT_IO_ERROR;
                }
                return ENGINE_RESULT_OK;
            } catch(const std::exception &error) {
                self->fail(error.what());
                self->stop();
                void *value = self;
                active_runtime.compare_exchange_strong(value, nullptr);
                return ENGINE_RESULT_IO_ERROR;
            }
        }
        engine_result_t Tick(void *p, uint32_t) {
            if(!p)
                return ENGINE_RESULT_INVALID_ARGUMENT;
            auto &self = *static_cast<Runtime *>(p);
            std::lock_guard<std::mutex> guard(self.mutex);
            if(self.ended && self.error.empty())
                self.error = "System 4 runtime requested termination";
            return self.error.empty() ? ENGINE_RESULT_OK
                                      : ENGINE_RESULT_IO_ERROR;
        }
        engine_result_t Pause(void *p) {
            if(!p)
                return ENGINE_RESULT_INVALID_ARGUMENT;
            auto &self = *static_cast<Runtime *>(p);
            self.paused = true;
            self.condition.notify_all();
            return ENGINE_RESULT_OK;
        }
        engine_result_t Resume(void *p) {
            if(!p)
                return ENGINE_RESULT_INVALID_ARGUMENT;
            auto &self = *static_cast<Runtime *>(p);
            self.paused = false;
            self.condition.notify_all();
            return ENGINE_RESULT_OK;
        }
        engine_result_t Option(void *p, const engine_option_t *option) {
            if(!p || !option || !option->key_utf8)
                return ENGINE_RESULT_INVALID_ARGUMENT;
            auto &self = *static_cast<Runtime *>(p);
            const std::string key = option->key_utf8,
                              value =
                                  option->value_utf8 ? option->value_utf8 : "";
            if(key == "default_font") {
                std::lock_guard<std::mutex> guard(self.mutex);
                self.font = value;
                return ENGINE_RESULT_OK;
            }
            if(key == "xsystem4_encoding") {
                if(value != "auto" && value != "sjis" && value != "gbk")
                    return ENGINE_RESULT_INVALID_ARGUMENT;
                std::lock_guard<std::mutex> guard(self.mutex);
                self.encoding = value;
                return ENGINE_RESULT_OK;
            }
            if(key == "fps_limit") {
                try {
                    self.fps = std::clamp(std::stoi(value), 0, 240);
                    return ENGINE_RESULT_OK;
                } catch(...) {
                    return ENGINE_RESULT_INVALID_ARGUMENT;
                }
            }
            return ENGINE_RESULT_NOT_SUPPORTED;
        }
        engine_result_t Surface(void *p, uint32_t w, uint32_t h) {
            return p && w && h ? ENGINE_RESULT_OK
                               : ENGINE_RESULT_INVALID_ARGUMENT;
        }
        engine_result_t Describe(void *p, engine_frame_desc_t *out) {
            if(!p || !out || out->struct_size < sizeof(*out))
                return ENGINE_RESULT_INVALID_ARGUMENT;
            auto &self = *static_cast<Runtime *>(p);
            std::lock_guard<std::mutex> guard(self.mutex);
            if(!self.frame)
                return ENGINE_RESULT_INVALID_STATE;
            self.snapshot = self.frame;
            out->width = self.snapshot->width;
            out->height = self.snapshot->height;
            out->stride_bytes = out->width * 4;
            out->pixel_format = ENGINE_PIXEL_FORMAT_RGBA8888;
            out->frame_serial = self.snapshot->serial;
            return ENGINE_RESULT_OK;
        }
        engine_result_t Read(void *p, void *out, size_t size) {
            if(!p || !out)
                return ENGINE_RESULT_INVALID_ARGUMENT;
            auto &self = *static_cast<Runtime *>(p);
            std::lock_guard<std::mutex> guard(self.mutex);
            auto frame = self.snapshot ? self.snapshot : self.frame;
            if(!frame)
                return ENGINE_RESULT_INVALID_STATE;
            if(size < frame->pixels.size())
                return ENGINE_RESULT_INVALID_ARGUMENT;
            std::memcpy(out, frame->pixels.data(), frame->pixels.size());
            self.delivered = frame->serial;
            return ENGINE_RESULT_OK;
        }
        SDL_Scancode Scancode(int key) {
            if(key >= 'A' && key <= 'Z')
                return SDL_Scancode(SDL_SCANCODE_A + key - 'A');
            if(key >= '1' && key <= '9')
                return SDL_Scancode(SDL_SCANCODE_1 + key - '1');
            if(key == '0')
                return SDL_SCANCODE_0;
            if(key >= 0x70 && key <= 0x7b)
                return SDL_Scancode(SDL_SCANCODE_F1 + key - 0x70);
            switch(key) {
                case 8:
                    return SDL_SCANCODE_BACKSPACE;
                case 9:
                    return SDL_SCANCODE_TAB;
                case 13:
                    return SDL_SCANCODE_RETURN;
                case 16:
                    return SDL_SCANCODE_LSHIFT;
                case 17:
                    return SDL_SCANCODE_LCTRL;
                case 18:
                    return SDL_SCANCODE_LALT;
                case 27:
                    return SDL_SCANCODE_ESCAPE;
                case 32:
                    return SDL_SCANCODE_SPACE;
                case 33:
                    return SDL_SCANCODE_PAGEUP;
                case 34:
                    return SDL_SCANCODE_PAGEDOWN;
                case 35:
                    return SDL_SCANCODE_END;
                case 36:
                    return SDL_SCANCODE_HOME;
                case 37:
                    return SDL_SCANCODE_LEFT;
                case 38:
                    return SDL_SCANCODE_UP;
                case 39:
                    return SDL_SCANCODE_RIGHT;
                case 40:
                    return SDL_SCANCODE_DOWN;
                case 45:
                    return SDL_SCANCODE_INSERT;
                case 46:
                    return SDL_SCANCODE_DELETE;
                default:
                    return SDL_SCANCODE_UNKNOWN;
            }
        }
        engine_result_t Input(void *p, const engine_input_event_t *input) {
            if(!p || !input || input->struct_size < sizeof(*input))
                return ENGINE_RESULT_INVALID_ARGUMENT;
            auto &self = *static_cast<Runtime *>(p);
            if(self.stopping || self.paused)
                return ENGINE_RESULT_OK;
            SDL_Event event{};
            event.common.timestamp = SDL_GetTicks();
            switch(input->type) {
                case ENGINE_INPUT_EVENT_POINTER_MOVE:
                    event.type = SDL_MOUSEMOTION;
                    event.motion.x = int(input->x);
                    event.motion.y = int(input->y);
                    break;
                case ENGINE_INPUT_EVENT_POINTER_DOWN:
                case ENGINE_INPUT_EVENT_POINTER_UP:
                    event.type = input->type == ENGINE_INPUT_EVENT_POINTER_DOWN
                        ? SDL_MOUSEBUTTONDOWN
                        : SDL_MOUSEBUTTONUP;
                    event.button.button =
                        input->button == 1 || (input->modifiers & 0x10)
                        ? SDL_BUTTON_RIGHT
                        : input->button == 2 || (input->modifiers & 0x20)
                        ? SDL_BUTTON_MIDDLE
                        : SDL_BUTTON_LEFT;
                    event.button.state = event.type == SDL_MOUSEBUTTONDOWN
                        ? SDL_PRESSED
                        : SDL_RELEASED;
                    event.button.x = int(input->x);
                    event.button.y = int(input->y);
                    break;
                case ENGINE_INPUT_EVENT_POINTER_SCROLL:
                    event.type = SDL_MOUSEWHEEL;
                    event.wheel.y = input->delta_y > 0 ? 1
                        : input->delta_y < 0           ? -1
                                                       : 0;
                    break;
                case ENGINE_INPUT_EVENT_KEY_DOWN:
                case ENGINE_INPUT_EVENT_KEY_UP:
                case ENGINE_INPUT_EVENT_BACK:
                    event.type = input->type == ENGINE_INPUT_EVENT_KEY_UP
                        ? SDL_KEYUP
                        : SDL_KEYDOWN;
                    event.key.state =
                        event.type == SDL_KEYDOWN ? SDL_PRESSED : SDL_RELEASED;
                    event.key.keysym.scancode =
                        Scancode(input->type == ENGINE_INPUT_EVENT_BACK
                                     ? 27
                                     : input->key_code);
                    if(event.key.keysym.scancode == SDL_SCANCODE_UNKNOWN)
                        return ENGINE_RESULT_NOT_SUPPORTED;
                    event.key.keysym.sym = SDL_Keycode(
                        event.key.keysym.scancode | SDLK_SCANCODE_MASK);
                    event.key.keysym.mod =
                        (input->modifiers & 1 ? KMOD_SHIFT : 0) |
                        (input->modifiers & 2 ? KMOD_ALT : 0) |
                        (input->modifiers & 4 ? KMOD_CTRL : 0);
                    event.key.repeat = (input->modifiers & 0x80) != 0;
                    break;
                case ENGINE_INPUT_EVENT_TEXT_INPUT: {
                    const uint32_t c = input->unicode_codepoint;
                    if(c > 0x10ffff || (c >= 0xd800 && c <= 0xdfff))
                        return ENGINE_RESULT_INVALID_ARGUMENT;
                    event.type = SDL_TEXTINPUT;
                    if(c < 0x80)
                        event.text.text[0] = char(c);
                    else if(c < 0x800) {
                        event.text.text[0] = char(0xc0 | c >> 6);
                        event.text.text[1] = char(0x80 | (c & 63));
                    } else if(c < 0x10000) {
                        event.text.text[0] = char(0xe0 | c >> 12);
                        event.text.text[1] = char(0x80 | ((c >> 6) & 63));
                        event.text.text[2] = char(0x80 | (c & 63));
                    } else {
                        event.text.text[0] = char(0xf0 | c >> 18);
                        event.text.text[1] = char(0x80 | ((c >> 12) & 63));
                        event.text.text[2] = char(0x80 | ((c >> 6) & 63));
                        event.text.text[3] = char(0x80 | (c & 63));
                    }
                    break;
                }
                default:
                    return ENGINE_RESULT_NOT_SUPPORTED;
            }
            std::lock_guard<std::mutex> guard(self.input_mutex);
            if(event.type == SDL_MOUSEMOTION && !self.input.empty() &&
               self.input.back().type == SDL_MOUSEMOTION)
                self.input.back() = event;
            else {
                if(self.input.size() >= 256)
                    self.input.pop_front();
                self.input.push_back(event);
            }
            return ENGINE_RESULT_OK;
        }
        engine_result_t Rendered(void *p, uint32_t *out) {
            if(!p || !out)
                return ENGINE_RESULT_INVALID_ARGUMENT;
            auto &self = *static_cast<Runtime *>(p);
            std::lock_guard<std::mutex> guard(self.mutex);
            *out = self.frame && self.frame->serial != self.delivered;
            return ENGINE_RESULT_OK;
        }
        engine_result_t TextInput(void *p, uint32_t *out) {
            if(!p || !out)
                return ENGINE_RESULT_INVALID_ARGUMENT;
            *out = static_cast<Runtime *>(p)->text_input
                ? ENGINE_TEXT_INPUT_STATE_ACTIVE
                : ENGINE_TEXT_INPUT_STATE_NONE;
            return ENGINE_RESULT_OK;
        }
        engine_result_t Renderer(void *p, char *out, uint32_t size) {
            return p ? Copy("backend=xsystem4 native-offscreen frame=rgba", out,
                            size)
                     : ENGINE_RESULT_INVALID_ARGUMENT;
        }
        engine_result_t Debug(void *p, char *out, uint32_t size,
                              uint32_t *written) {
            if(!p)
                return ENGINE_RESULT_INVALID_ARGUMENT;
            auto &self = *static_cast<Runtime *>(p);
            std::lock_guard<std::mutex> guard(self.mutex);
            return Copy("runtime=xsystem4 native-library frames=" +
                            std::to_string(self.serial.load()) + " encoding=" +
                            self.selected_encoding + " saves=" + self.saves,
                        out, size, written);
        }
        const char *Error(void *p) {
            if(!p)
                return "System 4 runtime is unavailable";
            auto &self = *static_cast<Runtime *>(p);
            std::lock_guard<std::mutex> guard(self.mutex);
            thread_local std::string text;
            text = self.error;
            return text.c_str();
        }
    } // namespace
} // namespace aetherkiri::xsystem4

extern "C" engine_result_t aetherkiri_xsystem4_register_runtime_provider() {
    using namespace aetherkiri::xsystem4;
    static engine_runtime_provider_v1_t provider{};
    static std::once_flag flag;
    static engine_result_t result = ENGINE_RESULT_INTERNAL_ERROR;
    std::call_once(flag, [] {
        provider.struct_size = sizeof(provider);
        provider.api_version = ENGINE_RUNTIME_PROVIDER_API_VERSION;
        provider.runtime_id_utf8 = "xsystem4";
        provider.display_name_utf8 = "AliceSoft System 4";
        provider.priority = 100;
        provider.probe = Probe;
        provider.create = Create;
        provider.destroy = Destroy;
        provider.open_game = Open;
        provider.tick = Tick;
        provider.pause = Pause;
        provider.resume = Resume;
        provider.set_option = Option;
        provider.set_surface_size = Surface;
        provider.get_frame_desc = Describe;
        provider.read_frame_rgba = Read;
        provider.send_input = Input;
        provider.get_frame_rendered_flag = Rendered;
        provider.get_renderer_info = Renderer;
        provider.get_plugin_debug_info = Debug;
        provider.get_last_error = Error;
        provider.get_text_input_state = TextInput;
        result = engine_register_runtime_provider(&provider);
    });
    return result;
}
