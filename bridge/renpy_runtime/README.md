# Ren'Py SDK provider

This is an explicitly opt-in bootstrap milestone. Configure
`AETHERKIRI_ENABLE_RENPY=ON` and point `AETHERKIRI_RENPY_SDK_ROOT` at an
official desktop Ren'Py SDK checkout. The provider validates a `game/script.rpy`
project and launches the SDK executable directly, without a shell.

The provider stages an opt-in Python overlay into `game/libs` while a game is
open. The overlay exports real renderer pixels through the AKRF1 transport and
forwards input through JSONL; staging is removed when the provider closes. A
read-only game root returns `ENGINE_RESULT_NOT_SUPPORTED` with a diagnostic.
Native GPU texture import remains unsupported, so hosts use the RGBA frame
path while the SDK-owned window stays available for debugging.

The Ren'Py game keeps its own logical canvas size from `game/options.rpy` (for
example 640x360). AetherKiri presents that frame in the same aspect-preserving
host surface used by the AR/KrKr runtimes, so a 16:9 Ren'Py game is enlarged to
the available display without stretching. Pointer coordinates are mapped back
from the enlarged display to the logical Ren'Py canvas before input is sent.

The process is started with an argv array and an exec-error pipe, polled with
`waitpid`/`WaitForSingleObject`, and terminated during provider destruction.
Paths are validated before launch and are never passed through a shell.

## Experimental Python overlay

`python/aether_renpy_overlay.py` is an opt-in Ren'Py-side prototype. Set
`AETHERKIRI_RENPY_OVERLAY=1` and import `install()` from the game's
`game/options.rpy` to hook `renpy.display.core.Interface.draw_screen`.

The hook uses the active SDK renderer (`renpy.display.draw`) after the real
draw. On Ren'Py 8.5.x, the compatibility `pygame.image` module does not
provide `tostring`; the overlay copies the live `Surface._pixels_address`
using its pitch and channel masks, then emits tightly packed RGBA bytes. The
frame file is atomically replaced on each draw and has this little-endian
layout:

```
AKRF1\0\0\0 | u32 width | u32 height | u64 serial | u32 payload_len | RGBA...
```

Set `AETHERKIRI_RENPY_FRAME` to select the frame path. Input is consumed from
`AETHERKIRI_RENPY_INPUT` as JSON lines during Ren'Py periodic callbacks:
`{"type": 768, "attributes": {"key": 13, "mod": 0, "unicode": "\r", "scancode": 40, "repeat": false}}`
is a `KEYDOWN` event; `mod`, `unicode`, `scancode`, and `repeat` default to
zero, empty, zero, and false when omitted. Mouse events use the usual `pos`,
`button`, and `rel` attributes. Set `AETHERKIRI_RENPY_ERROR` to an optional
append-only diagnostics path; frame and input failures are reported there
without terminating the SDK process.

The reproducible desktop probe is `tools/run_renpy_overlay_probe.sh`; run it
with `RENPY_SDK=/path/to/renpy-8.5.3-sdk`. It launches the official SDK with
SDL's dummy drivers, verifies a nonblank 640x360 frame, injects Down+Return,
and checks that the Ren'Py menu selection reaches script code. It uses the
SDK's `gl2` renderer by default; set `RENPY_RENDERER=sw` to exercise the
software renderer instead.

The overlay is desktop-only. Mobile builds use the in-process lifecycle fork,
with its own packaged Python home and stack-preserving cooperative loop.

## Mobile build and runtime status

Mobile gameplay is **unverified**. There is no accepted APK/device or
IPA/simulator gameplay result for this change. Exported symbols, host fixture
tests, and a successful application build do not establish mobile support.

The source runner pins a coherent, independently rebuilt 8.5.3 fork:

- renpy-build: `7bfab40c1174f622f644b24669afd5fb167fbb79`
- Ren'Py: `39895c1e017f0b36ffea2447d97eccd69d76ee1c`
- greenlet: `65f8da82b13a1273e55a6bfcbd1f9da09fc4eb7a`

It applies both the Python and native patches before compiling the actual
runtime. Greenlet preserves the script and interaction stacks on the host
thread. Game initialization starts in the first tick, after asynchronous game
open has returned. Frames come from the real renderer screenshot, copied from
its Surface with row pitch respected. Input retains press, release, motion,
scroll and committed UTF-8 text semantics. Pause, resume and natural exit are
observable through the provider.

Android compilation requires a supported Ubuntu 24.04 cloud builder, LLVM 18,
NDK r29 and at least 64 GiB of free disk. The fork uses SDL2's offscreen
EGL/pbuffer path to avoid taking Godot's display Surface. This path still
requires real Android graphics, input and lifecycle acceptance.

The iOS native archive must be rebuilt with legally supplied Apple SDKs. Its
stock SDL UIKit/MetalANGLE window path is not a verified Godot rendering
integration; this remains an implementation and simulator/device validation
blocker. Device builds also require the appropriate signing credentials;
simulator verification does not require distribution signing.

Enabling Ren'Py in a mobile application build now requires the rebuilt native
library and matching cooperative Python/standard-library resources. CMake and
packaging reject an official blocking RAPT/Renios archive, missing resources,
incompatible native targets and missing lifecycle exports. iOS native linking
is enabled by default. No second launcher entrypoint is copied into Godot.

## Reproducible cloud commands

Prepare pinned sources without installing system packages or licensed SDKs:

```bash
bash tools/run_renpy_mobile_source_build.sh --mode prepare --fetch \
  --platform android --renpy-build /workspace/renpy-build
```

Run the actual source build on a provisioned cloud builder:

```bash
bash tools/run_renpy_mobile_source_build.sh --mode build \
  --platform android --renpy-build /workspace/renpy-build
```

The output is `out/renpy-mobile-source/payload` plus a provenance manifest.
Android private assets are in `payload/rapt/runtime/private`. Build the debug
app with that payload, then run the real device gate described in
[`demos/aetherkiri-renpy/README.md`](../../demos/aetherkiri-renpy/README.md).

The Build workflow requires the source-build job's output before packaging
Android. It preserves a debug APK for installation. For iOS, the workflow
requires `AETHER_RENPY_IOS_RUNTIME_RUN_ID` and
`AETHER_RENPY_IOS_RUNTIME_ARTIFACT` repository variables identifying a rebuilt
payload artifact named `renpy-ios-runtime.tar.gz` with `payload/renios` inside.
A missing input is a build failure with a diagnostic, rather than a successful
package containing only a mobile guard.

The Mobile Contract workflow validates contracts and compilation, with no
playability claim. Desktop Acceptance runs the SDK fixtures; its Linux job
also exercises a real rendered frame, input and quit. The device gate requires
actual APK installation, executed Ren'Py script checkpoints, native RGBA
pixels matching an OS screenshot, touch, text/keyboard, background/resume,
and normal game exit while the application process stays alive.
