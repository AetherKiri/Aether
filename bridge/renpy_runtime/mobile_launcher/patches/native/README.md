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
