#include "renpy_mobile_adapter.h"

#if defined(__ANDROID__)
#include <jni.h>

// These accessors are exported by engine_api's existing Android JNI bridge.
// They let the adapter validate the already-running VM/context without
// constructing or launching a second Activity.
extern JavaVM* krkr_GetJavaVM();
extern jobject krkr_GetApplicationContext();
extern jobject krkr_GetHostActivity();
#endif

namespace aetherkiri::renpy::mobile {

engine_result_t BootstrapAdapter::Start(const BootstrapRequest& request) {
  if (request.game_root_path_utf8 == nullptr ||
      request.game_root_path_utf8[0] == '\0') {
    last_error_ = "Ren'Py mobile bootstrap requires a non-empty game root";
    return ENGINE_RESULT_INVALID_ARGUMENT;
  }
  if (running_) {
    last_error_ = "Ren'Py mobile bootstrap is already running";
    return ENGINE_RESULT_INVALID_STATE;
  }

  // There is deliberately no Activity construction here.  The host must
  // provide its existing Activity once the Godot Android plugin owns that
  // handoff; without it, starting RAPT would create a second UI owner.
  void* host_activity = request.existing_host_activity;
#if defined(__ANDROID__)
  if (host_activity == nullptr) {
    // The generated Godot Activity can bind itself through the staged
    // RenPyMobileBridge. This is a global JNI reference owned by engine_api;
    // no second Activity is ever constructed here.
    host_activity = krkr_GetHostActivity();
  }
#endif
  if (host_activity == nullptr) {
    last_error_ =
        "Ren'Py mobile bootstrap requires the existing host Activity; "
        "a second Activity is never created";
    return ENGINE_RESULT_NOT_SUPPORTED;
  }

#if defined(__ANDROID__)
  if (krkr_GetJavaVM() == nullptr || krkr_GetApplicationContext() == nullptr) {
    last_error_ =
        "Ren'Py mobile bootstrap requires the existing Android JavaVM and "
        "Application Context from EngineBridge";
    return ENGINE_RESULT_NOT_SUPPORTED;
  }
#endif

  // Keep this guard until the official RAPT classes/native library and the
  // in-process SDL/asset/lifecycle bridge are linked into the Android app.
  // Returning NOT_SUPPORTED here is intentional and prevents staged inputs
  // from being reported as playable support.
  last_error_ =
      "Ren'Py mobile bootstrap adapter boundary is present, but official "
      "RAPT PythonSDLActivity/librenpython and SDL lifecycle dependencies "
      "are not linked yet";
  return ENGINE_RESULT_NOT_SUPPORTED;
}

engine_result_t BootstrapAdapter::Stop() {
  // Start() cannot currently transition to running, but make destruction
  // idempotent so the provider can call Stop() unconditionally.
  running_ = false;
  last_error_.clear();
  return ENGINE_RESULT_OK;
}

}  // namespace aetherkiri::renpy::mobile
