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

This layer is not packaged automatically as a fake runtime. The source-build
runner must receive a fork checkout that includes this file and the launcher
entrypoint patch.
