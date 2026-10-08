#include "renpy_mobile_loader.h"

#include <cstdlib>
#include <cstring>

#if defined(__ANDROID__) || defined(__APPLE__) || defined(AETHERKIRI_RENPY_PROTOCOL_TEST)
#include <dlfcn.h>
#endif


namespace aetherkiri::renpy::mobile {
namespace {

constexpr int kOk = RENPY_MOBILE_OK;

constexpr const char* kVideoEnvironment[] = {
    "SDL_VIDEODRIVER", "SDL_VIDEO_GL_DRIVER", "SDL_VIDEO_EGL_DRIVER"};

void CaptureVideoEnvironment(std::array<std::string, 3>& values,
                             std::array<bool, 3>& defined) {
  for (size_t index = 0; index < values.size(); ++index) {
    const char* value = std::getenv(kVideoEnvironment[index]);
    defined[index] = value != nullptr;
    values[index] = value ? value : "";
  }
}

bool ReplaceVideoEnvironment(const std::array<std::string, 3>& values,
                             const std::array<bool, 3>& defined) {
  bool success = true;
  for (size_t index = 0; index < values.size(); ++index) {
#if defined(_WIN32)
    const int status = _putenv_s(kVideoEnvironment[index],
                                defined[index] ? values[index].c_str() : "");
#else
    const int status = defined[index]
                           ? setenv(kVideoEnvironment[index], values[index].c_str(), 1)
                           : unsetenv(kVideoEnvironment[index]);
#endif
    if (status != 0) success = false;
  }
  return success;
}

// Snapshot on every call: the host may update its selection between calls.
// Bootstrap supplies the runtime values before the first cooperative tick.
class VideoEnvironmentScope final {
 public:
  VideoEnvironmentScope() { CaptureVideoEnvironment(values_, defined_); }
  ~VideoEnvironmentScope() { ReplaceVideoEnvironment(values_, defined_); }

  bool Apply(const std::array<std::string, 3>& values,
             const std::array<bool, 3>& defined) {
    return ReplaceVideoEnvironment(values, defined);
  }

 private:
  std::array<std::string, 3> values_;
  std::array<bool, 3> defined_{};
};

#if defined(__ANDROID__) || defined(__APPLE__) || defined(AETHERKIRI_RENPY_PROTOCOL_TEST)
template <typename Function>
Function ResolveSymbol(void* handle, const char* name) {
  return reinterpret_cast<Function>(dlsym(handle, name));
}
#endif

}  // namespace

Launcher::Launcher() = default;

Launcher::~Launcher() {
  Shutdown();
  Unload();
}

bool Launcher::Resolve() {
  if (resolved_) return init_ != nullptr;
  resolved_ = true;

#if defined(__ANDROID__)
  const char* library_name = "librenpython.so";
  library_handle_ = dlopen(library_name, RTLD_NOW | RTLD_LOCAL);
  if (!library_handle_) {
    const char* detail = dlerror();
    last_error_ = "host lifecycle launcher unavailable: could not load ";
    last_error_ += library_name;
    if (detail) {
      last_error_ += ": ";
      last_error_ += detail;
    }
    return false;
  }
  init_ = ResolveSymbol<InitFn>(library_handle_, "renpy_mobile_init");
  bootstrap_ = ResolveSymbol<BootstrapFn>(library_handle_, "renpy_mobile_bootstrap");
  tick_ = ResolveSymbol<TickFn>(library_handle_, "renpy_mobile_tick");
  frame_ = ResolveSymbol<FrameFn>(library_handle_, "renpy_mobile_frame");
  input_ = ResolveSymbol<InputFn>(library_handle_, "renpy_mobile_input");
  pause_ = ResolveSymbol<PauseFn>(library_handle_, "renpy_mobile_pause");
  resume_ = ResolveSymbol<ResumeFn>(library_handle_, "renpy_mobile_resume");
  text_input_state_ = ResolveSymbol<TextInputStateFn>(library_handle_, "renpy_mobile_text_input_state");
  surface_size_ = ResolveSymbol<SurfaceSizeFn>(library_handle_, "renpy_mobile_set_surface_size");
  bind_window_ = ResolveSymbol<BindWindowFn>(library_handle_, "renpy_mobile_bind_window");
  shutdown_ = ResolveSymbol<ShutdownFn>(library_handle_, "renpy_mobile_shutdown");
#elif defined(AETHERKIRI_RENPY_IOS)
  // Strong references bind the isolated AetherRenPyRuntime framework. Missing
  // lifecycle exports fail at link time instead of producing a stub app.
  init_ = renpy_mobile_init;
  bootstrap_ = renpy_mobile_bootstrap;
  tick_ = renpy_mobile_tick;
  frame_ = renpy_mobile_frame;
  input_ = renpy_mobile_input;
  pause_ = renpy_mobile_pause;
  resume_ = renpy_mobile_resume;
  text_input_state_ = renpy_mobile_text_input_state;
  surface_size_ = renpy_mobile_set_surface_size;
  bind_window_ = renpy_mobile_bind_window;
  shutdown_ = renpy_mobile_shutdown;
#elif defined(__APPLE__) || defined(AETHERKIRI_RENPY_PROTOCOL_TEST)
  // Optional protocol-test lookup. Production iOS binds the isolated runtime
  // framework above and never resolves its internal SDL or Python symbols.
  init_ = ResolveSymbol<InitFn>(RTLD_DEFAULT, "renpy_mobile_init");
  bootstrap_ = ResolveSymbol<BootstrapFn>(RTLD_DEFAULT, "renpy_mobile_bootstrap");
  tick_ = ResolveSymbol<TickFn>(RTLD_DEFAULT, "renpy_mobile_tick");
  frame_ = ResolveSymbol<FrameFn>(RTLD_DEFAULT, "renpy_mobile_frame");
  input_ = ResolveSymbol<InputFn>(RTLD_DEFAULT, "renpy_mobile_input");
  pause_ = ResolveSymbol<PauseFn>(RTLD_DEFAULT, "renpy_mobile_pause");
  resume_ = ResolveSymbol<ResumeFn>(RTLD_DEFAULT, "renpy_mobile_resume");
  text_input_state_ = ResolveSymbol<TextInputStateFn>(RTLD_DEFAULT, "renpy_mobile_text_input_state");
  surface_size_ = ResolveSymbol<SurfaceSizeFn>(RTLD_DEFAULT, "renpy_mobile_set_surface_size");
  bind_window_ = ResolveSymbol<BindWindowFn>(RTLD_DEFAULT, "renpy_mobile_bind_window");
  shutdown_ = ResolveSymbol<ShutdownFn>(RTLD_DEFAULT, "renpy_mobile_shutdown");
#else
  last_error_ = "host lifecycle launcher unavailable on this platform";
#endif

  if (!init_ || !bootstrap_ || !tick_ || !frame_ || !input_ || !pause_ || !resume_ ||
      !text_input_state_ || !surface_size_ || !bind_window_ || !shutdown_) {
    last_error_ =
        "host lifecycle launcher unavailable: rebuilt Ren'Py payload must "
        "export the complete ABI v2 lifecycle, bootstrap, renderer binding, text state and resize functions";
    Unload();
    return false;
  }
  return true;
}

bool Launcher::available() {
  return Resolve();
}

int Launcher::Init(const renpy_mobile_config_t& config,
                  const renpy_mobile_host_t& host) {
  if (!Resolve()) return RENPY_MOBILE_NOT_IMPLEMENTED;
  if (initialized_) return RENPY_MOBILE_INVALID_STATE;
  VideoEnvironmentScope environment;
  int result = bootstrap_ ? bootstrap_(&config, &host) : RENPY_MOBILE_OK;
  CaptureVideoEnvironment(video_environment_values_, video_environment_defined_);
  if (result == kOk) result = init_(&config, &host);
  if (result == kOk) {
    initialized_ = true;
    finished_ = false;
  } else {
    last_error_ = "host lifecycle launcher init failed with status " +
                  std::to_string(result);
  }
  return result;
}

int Launcher::Tick(uint32_t budget_ms) {
  if (!initialized_ || !tick_) return RENPY_MOBILE_INVALID_STATE;
  VideoEnvironmentScope environment;
  if (!environment.Apply(video_environment_values_, video_environment_defined_)) return RENPY_MOBILE_ERROR;
  const int result = tick_(budget_ms);
  if (result == RENPY_MOBILE_FINISHED) finished_ = true;
  return result;
}

int Launcher::Frame(renpy_mobile_frame_t* out_frame) {
  if (!initialized_ || !frame_ || !out_frame) return RENPY_MOBILE_INVALID_STATE;
  VideoEnvironmentScope environment;
  if (!environment.Apply(video_environment_values_, video_environment_defined_)) return RENPY_MOBILE_ERROR;
  return frame_(out_frame);
}

int Launcher::Input(const renpy_mobile_input_t& event) {
  if (!initialized_ || !input_) return RENPY_MOBILE_INVALID_STATE;
  VideoEnvironmentScope environment;
  if (!environment.Apply(video_environment_values_, video_environment_defined_)) return RENPY_MOBILE_ERROR;
  return input_(&event);
}

int Launcher::Pause() {
  if (!initialized_ || !pause_) return RENPY_MOBILE_INVALID_STATE;
  VideoEnvironmentScope environment;
  if (!environment.Apply(video_environment_values_, video_environment_defined_)) return RENPY_MOBILE_ERROR;
  return pause_();
}

int Launcher::Resume() {
  if (!initialized_ || !resume_) return RENPY_MOBILE_INVALID_STATE;
  VideoEnvironmentScope environment;
  if (!environment.Apply(video_environment_values_, video_environment_defined_)) return RENPY_MOBILE_ERROR;
  return resume_();
}

int Launcher::TextInputState(uint32_t* active) {
  if (!initialized_ || !active) return RENPY_MOBILE_INVALID_STATE;
  VideoEnvironmentScope environment;
  if (!environment.Apply(video_environment_values_, video_environment_defined_)) return RENPY_MOBILE_ERROR;
  return text_input_state_ ? text_input_state_(active) : RENPY_MOBILE_NOT_IMPLEMENTED;
}

int Launcher::SetSurfaceSize(uint32_t width, uint32_t height) {
  if (!initialized_) return RENPY_MOBILE_INVALID_STATE;
  VideoEnvironmentScope environment;
  if (!environment.Apply(video_environment_values_, video_environment_defined_)) return RENPY_MOBILE_ERROR;
  return surface_size_ ? surface_size_(width, height) : RENPY_MOBILE_NOT_IMPLEMENTED;
}

void Launcher::Shutdown() {
  if (initialized_ && shutdown_) {
    VideoEnvironmentScope environment;
    if (!environment.Apply(video_environment_values_, video_environment_defined_)) {
      last_error_ = "Could not select the Ren'Py video environment for shutdown";
    }
    shutdown_();
  }
  initialized_ = false;
  finished_ = false;
}

void Launcher::Unload() {
#if defined(__ANDROID__)
  if (library_handle_) dlclose(library_handle_);
#endif
  library_handle_ = nullptr;
  init_ = nullptr;
  bootstrap_ = nullptr;
  tick_ = nullptr;
  frame_ = nullptr;
  input_ = nullptr;
  pause_ = nullptr;
  resume_ = nullptr;
  text_input_state_ = nullptr;
  surface_size_ = nullptr;
  bind_window_ = nullptr;
  shutdown_ = nullptr;
  resolved_ = false;
}

}  // namespace aetherkiri::renpy::mobile
