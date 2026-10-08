#ifndef AETHERKIRI_RENPY_MOBILE_LOADER_H
#define AETHERKIRI_RENPY_MOBILE_LOADER_H

#include "renpy_mobile_launcher.h"

#include <string>

namespace aetherkiri::renpy::mobile {

/*
 * Loads the optional host-owned launcher ABI from the rebuilt mobile payload.
 *
 * The official RAPT/Renios archives do not export these functions, so an
 * unavailable loader is an expected and safe state. Android resolves the
 * symbols from librenpython.so; iOS links the rebuilt archive with strong
 * references so missing native inputs fail the build. This class never falls back to
 * SDL_main, launcher_main, Py_RunMain, or an application entrypoint.
 */
class Launcher final {
 public:
  Launcher();
  ~Launcher();

  Launcher(const Launcher&) = delete;
  Launcher& operator=(const Launcher&) = delete;

  bool available();
  const std::string& last_error() const { return last_error_; }

  int Init(const renpy_mobile_config_t& config,
           const renpy_mobile_host_t& host);
  int Tick(uint32_t budget_ms);
  int Frame(renpy_mobile_frame_t* out_frame);
  int Input(const renpy_mobile_input_t& event);
  int Pause();
  int Resume();
  int TextInputState(uint32_t* active);
  int SetSurfaceSize(uint32_t width, uint32_t height);
  void Shutdown();

  bool initialized() const { return initialized_; }
  bool finished() const { return finished_; }

 private:
  bool Resolve();
  void Unload();

  using InitFn = int (*)(const renpy_mobile_config_t*,
                         const renpy_mobile_host_t*);
  using BootstrapFn = int (*)(const renpy_mobile_config_t*,
                              const renpy_mobile_host_t*);
  using TickFn = int (*)(uint32_t);
  using FrameFn = int (*)(renpy_mobile_frame_t*);
  using InputFn = int (*)(const renpy_mobile_input_t*);
  using PauseFn = int (*)();
  using ResumeFn = int (*)();
  using TextInputStateFn = int (*)(uint32_t*);
  using SurfaceSizeFn = int (*)(uint32_t, uint32_t);
  using BindWindowFn = int (*)(void*);
  using ShutdownFn = void (*)();

  void* library_handle_ = nullptr;
  InitFn init_ = nullptr;
  BootstrapFn bootstrap_ = nullptr;
  TickFn tick_ = nullptr;
  FrameFn frame_ = nullptr;
  InputFn input_ = nullptr;
  PauseFn pause_ = nullptr;
  ResumeFn resume_ = nullptr;
  TextInputStateFn text_input_state_ = nullptr;
  SurfaceSizeFn surface_size_ = nullptr;
  BindWindowFn bind_window_ = nullptr;
  ShutdownFn shutdown_ = nullptr;
  bool resolved_ = false;
  bool initialized_ = false;
  bool finished_ = false;
  std::string last_error_;
};

}  // namespace aetherkiri::renpy::mobile

#endif  // AETHERKIRI_RENPY_MOBILE_LOADER_H
