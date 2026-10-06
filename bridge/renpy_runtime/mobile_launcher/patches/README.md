# Upstream patch slot

Keep the future lifecycle fork as a small, reviewable patch against the exact
`renpy-build` commit used for a release. The patch should replace or factor
`runtime/librenpython_android.c` and `runtime/librenpython.c` while preserving
Ren'Py's Python/SDL initialization and JNI callbacks.

Required review checks for that patch:

1. `SDL_main`, `launcher_main`, `SDL_RunApp`, and `Py_RunMain` are not used as
   host lifecycle entrypoints
2. the seven `renpy_mobile_*` exports in the sibling ABI header are present on
   every Android and iOS architecture
3. init/tick/frame/input/pause/resume/shutdown are re-entrant only as stated by
   the ABI and return promptly
4. no second Android Activity, UIKit application, SDL application loop, or
   process exit is introduced
5. Android links with the `tasks/renpython.py` `link_android` closure and iOS
   archives with its `link_ios` closure
6. the resulting archives pass symbol checks, host unit tests, and device or
   simulator smoke tests before replacing staged artifacts

`android/librenpython_android_host.c.template` and
`ios/librenpython_ios_host.c.template` provide compile-tested C entrypoints and
argument validation for the first fork. They explicitly return
`RENPY_MOBILE_NOT_IMPLEMENTED`, define `AETHERKIRI_RENPY_LIFECYCLE_STUB`, and are
compiled only as contract-test objects. They are never installed as runtime
archives. `build.sh --install` remains the handoff for an audited, functional
fork rebuilt with the official SDK toolchain.

The C patch alone is insufficient. The Python loop also has to yield and
resume safely at `renpy/bootstrap.py::bootstrap`, `renpy/main.py::main/run`,
`renpy/execution.py::run_context`, and
`renpy/display/core.py::Interface.interact/interact_core`. A runtime shim that
calls one of these blocking functions from `renpy_mobile_tick` is not a valid
implementation.

Once an audited fork exports the ABI, the host loader in
`../src/renpy_mobile_loader.cpp` resolves it without using a second SDL,
Activity, or UIKit entrypoint. It is deliberately inert for the official
blocking libraries, so staging those archives alone cannot accidentally enable
mobile gameplay.

## Native lifecycle fork

`native/renpy_mobile_lifecycle.c` is the shared host-owned implementation for
the seven ABI exports. It calls the cooperative Python entrypoints, publishes
the existing SDL window surface, queues input, and shuts down without process
exit. The release-specific Android and iOS launcher patch must factor Python
initialization out of `SDL_main`/`launcher_main`, then bind the existing SDL
window and call this implementation. The source-build runner must compile this
file with the official `link_android`/`link_ios` closures and run the export
gate before installing any artifact.

## Python cooperative-loop seam

`python/0001-cooperative-loop-skeleton.patch` is an opt-in, syntax-checked
patch for `renpy/main.py`, `renpy/execution.py`, and
`renpy/display/core.py`. The scaffold validates or applies it with
`--check-python-patch` / `--apply-python-patch`. It adds
`cooperative_start/tick/stop`, preserves the active execution context across
bounded ticks, raises `CooperativeYield` at the context and interaction-loop
boundaries, and provides host-safe cleanup while preserving default launcher
behavior. The native fork must still call these APIs and provide the SDL/GLES
or Metal frame/input bridge before mobile gameplay can be enabled.
