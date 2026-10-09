# Host-owned Ren'Py mobile lifecycle fork

This fork separates Python initialization from the official blocking launchers
and runs the full Ren'Py bootstrap inside a stack-preserving greenlet. It is a
reviewable runtime implementation and build path; mobile gameplay remains
unverified. The contract templates are separate, deliberately non-playable
fixtures and are never packaged.

## Pinned source build

`tools/run_renpy_mobile_source_build.sh` pins the Ren'Py build/source and greenlet
revisions documented in the [provider README](../README.md). It applies the
Python patch to the actual source compiled by renpy-build, compiles the native
lifecycle and greenlet objects for each selected Android/iOS target, and checks
the exports before assembling a payload. The legacy Python patch filename
contains `skeleton`, but its implementation now preserves the actual Python
and Cython stacks with greenlet rather than exception-based yields.

```bash
bash tools/run_renpy_mobile_source_build.sh --mode prepare --fetch \
  --platform android --renpy-build /workspace/renpy-build
bash tools/run_renpy_mobile_source_build.sh --mode build \
  --platform android --renpy-build /workspace/renpy-build
```

Preparation does not run upstream `prepare.sh`, which resets or pulls source
revisions and installs system packages. Build requires a provisioned Ubuntu
24.04 cloud builder, LLVM 18, NDK r29 and 64 GiB of free disk. iOS source builds
also require the legally supplied SDK archives requested by the pinned
renpy-build toolchain. `--platform ios` or `all` selects those targets explicitly.

`--mode check` only checks prerequisites. `--mode auto` with an existing checkout
performs compilation; an absent optional checkout reports a skip. CI uses
`--mode build` explicitly. Successful export checks or compilation do not assert
mobile playability.

## Runtime ownership

ABI version 2 is defined in `include/renpy_mobile_launcher.h`. The loader requires
bootstrap, window binding, init/tick/frame/input, pause/resume, shutdown, text
input state and surface sizing. Native initialization copies the host callback
table. The provider owns the paths and initializes Python and greenlet on the
first host tick, rather than the asynchronous open thread.

Frame capture occurs on Ren'Py's rendering thread through its GL screenshot.
The fork copies visible Surface rows and retains the bytes while the host reads
them. It does not use `SDL_GetWindowSurface` for a GL window. Input preserves
pointer actions, key transitions, scroll deltas and committed UTF-8 text.
Android uses the patched SDL2 offscreen EGL/pbuffer backend and restores the
host's EGL context when returning to Godot. The Java bridge supplies the actual
SDL JNI callback closure without launching another Activity.

The stock iOS SDL UIKit/MetalANGLE path still requires a host rendering
integration. The provider refuses that unimplemented path explicitly instead
of activating it merely because an archive exports the lifecycle symbols.

## Acceptance and artifacts

The application build must carry the native library, cooperative Ren'Py modules
and matching Python standard library. `tools/validate_renpy_mobile_payload.py`
checks staged inputs and actual Android APK contents. Missing or official
blocking launchers fail the enabled build rather than producing a guard-only
Ren'Py package.

Run the real cloud-device gate documented in
[the demo README](../../../demos/aetherkiri-renpy/README.md) after building an
installable debug APK. It requires executed game checkpoints, native pixels
matching an OS screenshot, actual touch and text/keyboard events,
background/resume and normal exit. Host boundary tests and simulated library
fixtures are reported separately and cannot satisfy this gate. No mobile
APK/IPA gameplay result has been accepted for this change.
