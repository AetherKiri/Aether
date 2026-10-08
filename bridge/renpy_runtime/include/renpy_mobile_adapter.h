#pragma once

#include "engine_api.h"

#include <string>

namespace aetherkiri::renpy::mobile {

/*
 * The Android RAPT package is built around PythonSDLActivity.  AetherKiri
 * already owns the process and its Godot Activity, so this adapter
 * must attach RAPT to that Activity rather than starting another one.
 *
 * This boundary intentionally carries an opaque host pointer.  Android hosts
 * may pass a JNI jobject through it without making the public provider ABI
 * depend on jni.h; non-Android callers can leave it null. PrepareRuntime
 * extracts the bundled private Python tree and initializes SDL's JNI/audio
 * callbacks. Video uses the patched offscreen EGL backend. Preflight/Start
 * preserve the explicit rejection of an official blocking RAPT launcher.
 */
struct BootstrapRequest {
  const char* game_root_path_utf8 = nullptr;
  const char* startup_script_utf8 = nullptr;
  void* existing_host_activity = nullptr;
};

class BootstrapAdapter final {
 public:
  BootstrapAdapter() = default;

  /* Validate the host-owned Android handoff and the staged RAPT payload.
   * This never calls SDL_main or starts a second Activity. */
  engine_result_t Preflight(const BootstrapRequest& request);

  engine_result_t Start(const BootstrapRequest& request);
  engine_result_t PrepareRuntime(const BootstrapRequest& request,
                                 uint32_t width, uint32_t height,
                                 std::string* private_root,
                                 std::string* apk_path);
  engine_result_t Stop();

  bool running() const { return running_; }
  const std::string& last_error() const { return last_error_; }

 private:
  bool running_ = false;
  std::string last_error_;
  void* native_library_handle_ = nullptr;
};

}  // namespace aetherkiri::renpy::mobile
