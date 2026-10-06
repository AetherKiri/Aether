# Native lifecycle fork

`renpy_mobile_lifecycle.c` is the first real native fork layer. It is linked
with the official Ren'Py native payload after the fork has performed Python
initialization and created the existing SDL window. It exports all seven
`renpy_mobile_*` symbols and:

- imports `renpy.main.cooperative_start/tick/stop`
- resumes the same Ren'Py context for bounded host ticks
- returns the SDL window surface as a borrowed RGBA frame
- queues pointer/key events through SDL
- implements pause/resume/shutdown without terminating the process

The file intentionally does not call any process or application entrypoint.
The Android/iOS launcher source still needs a small release-specific patch to
factor Python initialization out of `SDL_main`/`launcher_main`, call
`renpy_mobile_init` after initialization, and call `renpy_mobile_bind_window`
after the host-owned SDL window exists. Build it with the official
`tasks/renpython.py` Android `link_android` or iOS `link_ios` closure, then run
the symbol gate and device/simulator demo smoke before installing artifacts.

Apply `0001-renpy-build-link.patch`, `0002-android-host-bootstrap.patch`, and
`0003-ios-host-bootstrap.patch` in the official `renpy-build` checkout
after copying this C file and `renpy_mobile_launcher.h` into its `runtime/`
directory. The task patch compiles the lifecycle object for Android and
archives it into the iOS `librenpython.a`; the two launcher patches add a
`renpy_mobile_bootstrap` entrypoint that performs the official Python
initialization and then enters the cooperative ABI. The existing
`link_android`/`link_ios` closure carries the exports into the native artifacts.

This layer is not packaged automatically as a fake runtime. Apply all three
native patches to a fork checkout, then the symbol gate and device/simulator
demo smoke must pass before installing artifacts.

## Full source-build command

On Ubuntu 24.04 with the Android NDK r29 and the licensed iOS SDK archives
available to `renpy-build`, the complete opt-in flow is:

```bash
git clone --depth=1 https://github.com/renpy/renpy-build.git /work/renpy-build
(cd /work/renpy-build && ./prepare.sh)
AETHERKIRI_RENPY_LIFECYCLE_FORK=1 \
  AETHERKIRI_RENPY_BUILD_IOS=1 \
  tools/run_renpy_mobile_source_build.sh \
    --mode build --renpy-build /work/renpy-build
```

The runner copies the lifecycle C file and ABI header, applies the task patch
and both platform bootstrap patches, runs the official Android/iOS build
tasks, and gates the canonical `.so`/`.a` outputs with the seven exported
symbols. Install the checked outputs into the staging tree only after that
gate:

```bash
bridge/renpy_runtime/mobile_launcher/build.sh --install \
  --renpy-build /work/renpy-build \
  --stage /work/renpy-mobile-staged \
  --android-so-arm64 /work/renpy-build/renpy/rapt/prototype/renpyandroid/src/main/jniLibs/arm64-v8a/librenpython.so \
  --android-so-armv7 /work/renpy-build/renpy/rapt/prototype/renpyandroid/src/main/jniLibs/armeabi-v7a/librenpython.so \
  --android-so-x86_64 /work/renpy-build/renpy/rapt/prototype/renpyandroid/src/main/jniLibs/x86_64/librenpython.so \
  --ios-debug-a /work/renpy-build/renpy/renios/prototype/prebuilt/debug/librenpython.a \
  --ios-release-a /work/renpy-build/renpy/renios/prototype/prebuilt/release/librenpython.a
RENPY_MOBILE_STAGE_TEST_ROOT=/work/renpy-mobile-staged \
  bash tools/test_stage_renpy_android_support.sh
bash tools/test_renpy_mobile_native_fork.sh
```

Without the fork flag, SDK archives, NDK, and iOS SDK inputs, the runner skips
or refuses the heavy build and the official blocking archives remain guarded
as `NOT_SUPPORTED`.
