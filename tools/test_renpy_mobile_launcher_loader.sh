#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/aetherkiri-renpy-loader.XXXXXX")"
trap 'rm -rf "$work"' EXIT

cat > "$work/fake_launcher.cpp" <<'CPP'
#include "renpy_mobile_launcher.h"
#include <cassert>
#include <cstdlib>
#include <cstring>
static unsigned char pixel[4] = {0x12, 0x34, 0x56, 0xff};
static void verify_runtime_environment() {
  assert(std::getenv("SDL_VIDEODRIVER") && !std::strcmp(std::getenv("SDL_VIDEODRIVER"), "offscreen"));
  assert(std::getenv("SDL_VIDEO_GL_DRIVER") && !std::strcmp(std::getenv("SDL_VIDEO_GL_DRIVER"), "/runtime/MetalANGLE"));
  assert(std::getenv("SDL_VIDEO_EGL_DRIVER") && !std::strcmp(std::getenv("SDL_VIDEO_EGL_DRIVER"), "/runtime/MetalANGLE"));
}
extern "C" int renpy_mobile_init(const renpy_mobile_config_t* config, const renpy_mobile_host_t*) {
  verify_runtime_environment();
  return config->game_root_utf8 && !std::strcmp(config->game_root_utf8, "init_fail") ? RENPY_MOBILE_ERROR : 0;
}
extern "C" int renpy_mobile_bootstrap(const renpy_mobile_config_t* config, const renpy_mobile_host_t*) {
  setenv("SDL_VIDEODRIVER", "offscreen", 1);
  setenv("SDL_VIDEO_GL_DRIVER", "/runtime/MetalANGLE", 1);
  setenv("SDL_VIDEO_EGL_DRIVER", "/runtime/MetalANGLE", 1);
  return config->game_root_utf8 && !std::strcmp(config->game_root_utf8, "bootstrap_fail") ? RENPY_MOBILE_ERROR : 0;
}
extern "C" int renpy_mobile_tick(unsigned int budget) {
  verify_runtime_environment();
  return budget == 13 ? RENPY_MOBILE_ERROR : 0;
}
extern "C" int renpy_mobile_frame(renpy_mobile_frame_t* frame) {
  verify_runtime_environment();
  if (!frame) return -1;
  frame->rgba = pixel; frame->width = 1; frame->height = 1; frame->stride = 4; frame->serial = 7;
  return 0;
}
extern "C" int renpy_mobile_input(const renpy_mobile_input_t*) { verify_runtime_environment(); return 0; }
extern "C" int renpy_mobile_pause(void) { verify_runtime_environment(); return 0; }
extern "C" int renpy_mobile_resume(void) { verify_runtime_environment(); return 0; }
extern "C" int renpy_mobile_bind_window(void* window) { return window ? 0 : -1; }
extern "C" int renpy_mobile_text_input_state(uint32_t* active) { verify_runtime_environment(); if (!active) return -1; *active = 1; return 0; }
extern "C" int renpy_mobile_set_surface_size(uint32_t width, uint32_t height) { verify_runtime_environment(); return width && height ? 0 : -1; }
extern "C" void renpy_mobile_shutdown(void) {
  verify_runtime_environment();
  // A callback can mutate process state; the loader must still restore host values.
  unsetenv("SDL_VIDEODRIVER");
  setenv("SDL_VIDEO_GL_DRIVER", "shutdown changed this", 1);
}
CPP
cat > "$work/test_loader.cpp" <<'CPP'
#include "renpy_mobile_loader.h"
#include <cassert>
#include <cstdlib>
#include <cstring>
using namespace aetherkiri::renpy::mobile;
static void expect_host_environment(const char* driver = "host-uikit") {
  assert(std::getenv("SDL_VIDEODRIVER") && !std::strcmp(std::getenv("SDL_VIDEODRIVER"), driver));
  assert(!std::getenv("SDL_VIDEO_GL_DRIVER"));
  assert(std::getenv("SDL_VIDEO_EGL_DRIVER") && !std::strcmp(std::getenv("SDL_VIDEO_EGL_DRIVER"), ""));
}
int main() {
  setenv("SDL_VIDEODRIVER", "host-uikit", 1);
  unsetenv("SDL_VIDEO_GL_DRIVER");
  setenv("SDL_VIDEO_EGL_DRIVER", "", 1);
  Launcher launcher;
  assert(launcher.available());
  renpy_mobile_config_t config{}; config.struct_size = sizeof(config); config.abi_version = RENPY_MOBILE_LAUNCHER_ABI_VERSION;
  renpy_mobile_host_t host{}; host.struct_size = sizeof(host); host.abi_version = RENPY_MOBILE_LAUNCHER_ABI_VERSION;
  assert(launcher.Init(config, host) == RENPY_MOBILE_OK);
  expect_host_environment();
  assert(launcher.Tick(16) == RENPY_MOBILE_OK);
  expect_host_environment();
  assert(launcher.Tick(13) == RENPY_MOBILE_ERROR);
  expect_host_environment();
  renpy_mobile_frame_t frame{}; frame.struct_size = sizeof(frame);
  assert(launcher.Frame(&frame) == RENPY_MOBILE_OK);
  assert(frame.width == 1 && frame.height == 1 && frame.stride == 4 && frame.serial == 7);
  expect_host_environment();
  renpy_mobile_input_t input{}; input.struct_size = sizeof(input); input.type = RENPY_MOBILE_INPUT_KEY;
  assert(launcher.Input(input) == RENPY_MOBILE_OK);
  expect_host_environment();
  assert(launcher.Pause() == RENPY_MOBILE_OK);
  expect_host_environment();
  // Snapshot every call instead of restoring a stale value from Init.
  setenv("SDL_VIDEODRIVER", "host-driver-changed-while-paused", 1);
  assert(launcher.Resume() == RENPY_MOBILE_OK);
  expect_host_environment("host-driver-changed-while-paused");
  uint32_t active = 0;
  assert(launcher.TextInputState(&active) == RENPY_MOBILE_OK && active == 1);
  expect_host_environment("host-driver-changed-while-paused");
  assert(launcher.SetSurfaceSize(1280, 720) == RENPY_MOBILE_OK);
  expect_host_environment("host-driver-changed-while-paused");
  launcher.Shutdown();
  assert(!launcher.initialized());
  expect_host_environment("host-driver-changed-while-paused");
  for (const char* failure : {"bootstrap_fail", "init_fail"}) {
    Launcher failing;
    config.game_root_utf8 = failure;
    assert(failing.Init(config, host) == RENPY_MOBILE_ERROR);
    expect_host_environment("host-driver-changed-while-paused");
  }
  for (const char* name : {"SDL_VIDEODRIVER", "SDL_VIDEO_GL_DRIVER", "SDL_VIDEO_EGL_DRIVER"}) unsetenv(name);
  {
    Launcher initially_absent;
    config.game_root_utf8 = "game";
    assert(initially_absent.Init(config, host) == RENPY_MOBILE_OK);
    assert(!std::getenv("SDL_VIDEODRIVER") && !std::getenv("SDL_VIDEO_GL_DRIVER") && !std::getenv("SDL_VIDEO_EGL_DRIVER"));
    assert(initially_absent.Tick(16) == RENPY_MOBILE_OK);
    assert(!std::getenv("SDL_VIDEODRIVER") && !std::getenv("SDL_VIDEO_GL_DRIVER") && !std::getenv("SDL_VIDEO_EGL_DRIVER"));
  }
  // Destructor shutdown also restores the three originally absent values.
  assert(!std::getenv("SDL_VIDEODRIVER") && !std::getenv("SDL_VIDEO_GL_DRIVER") && !std::getenv("SDL_VIDEO_EGL_DRIVER"));
  return 0;
}
CPP

cxx="${CXX:-c++}"
"$cxx" -std=c++17 -fPIC -shared -D__ANDROID__ \
  -I"$repo_root/bridge/renpy_runtime/mobile_launcher/include" \
  "$work/fake_launcher.cpp" -o "$work/librenpython.so"
"$cxx" -std=c++17 -D__ANDROID__ \
  -I"$repo_root/bridge/renpy_runtime/mobile_launcher/include" \
  "$work/test_loader.cpp" \
  "$repo_root/bridge/renpy_runtime/mobile_launcher/src/renpy_mobile_loader.cpp" \
  -ldl -o "$work/test_loader"
LD_LIBRARY_PATH="$work${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$work/test_loader"
printf '%s\n' 'Ren''Py mobile lifecycle loader test passed'
