# Native Ren’Py integration

Aether imports Ren’Py 8 games from the visual-novel library and runs the original
engine inside the existing application window and process. The renderer uses a
native view/Surface with its own GPU context; there is no WebView, WebAssembly,
child game process, or per-frame pixel copy into Godot. Godot owns the library,
toolbar, play-time accounting and return/refresh actions. Ren’Py owns scripts,
screens, rollback, archives, saves, audio and model rendering.

## Platform hosts

| Platform | Native presentation | Input and scheduling |
| --- | --- | --- |
| macOS | Adopt the SDK’s Cocoa view below the Godot toolbar | Godot pointer/keyboard/IME forwarding; cooperative Python ticks on the UI thread; restore the host GL context between ticks |
| iOS/iPadOS | Adopt the SDK’s UIKit view/controller in Aether’s window; MetalANGLE renders through Metal | Godot touch/keyboard forwarding; cooperative ticks on the UI thread; Aether owns the UIKit event loop |
| Android | SDK SDL Surface in the existing Godot Activity | Private SDL Java package and JNI bindings; SDK native owner thread stays alive across games; ordinary native touch/keyboard/IME |
| Linux | Reparent the SDK’s X11 window inside Godot’s X11 window | Native SDL pointer input, Godot keyboard/IME forwarding when the parent has focus; preserve the host GL context |

Linux defaults to X11, also usable through XWayland on a Wayland desktop.
An explicit `--display-driver wayland` cannot host the X11 child. Android product
builds target `arm64-v8a`; the independent emulator probe also builds `x86_64`.
Virtual keys start **disabled** for every game launch and refresh, like the
other visual novels. They can be enabled in the toolbar or the in-game menu.
Returning releases the native view and renderer; reopening restores the engine
baseline in the same Python interpreter. Pause/resume releases held input and
pauses audio. Android also receives SDL’s normal Activity lifecycle events.

## Runtime and packaging

The reproducible runtime is the official **Ren’Py 8.5.3.26051504**, CPython 3.12.8,
SDL 2.0.20 and greenlet 3.5.6. `tools/prepare_renpy_runtime.py` downloads pinned
SDK/Renios/RAPT and source inputs with SHA-256 checks, then caches a runtime for
the requested platform and architecture under `.devtools/renpy/8.5.3`.
The normal macOS, Linux, iOS and Android build scripts stage that runtime in
their application outputs. A prepared runtime can be reused with
`AETHER_RENPY_RUNTIME_DIR=/absolute/path` during the build.

```sh
python3 tools/prepare_renpy_runtime.py macos --arch arm64
python3 tools/prepare_renpy_runtime.py linux --arch x86_64
python3 tools/prepare_renpy_runtime.py ios --arch arm64
python3 tools/prepare_renpy_runtime.py ios-simulator --arch arm64
python3 tools/prepare_renpy_runtime.py android --arch arm64 --ndk /path/to/ndk
```

Desktop preparation installs the matching Python greenlet wheel. Mobile builds
compile greenlet from source against the matching CPython headers and link the
native host to the official platform SDK. An iOS build needs Xcode selected via
`DEVELOPER_DIR`; Android needs the NDK. SDK binaries and test fonts are generated
only in ignored output/cache directories and are never committed here.

- macOS: Python data in `Contents/Resources/renpy-runtime`; executable SDK files
  in `Contents/Frameworks/renpy-runtime`, with relative import symlinks and signing.
- Linux: a complete `renpy-runtime` directory beside the executable and the SDL
  dynamic-API adapter beside the Godot extension.
- iOS: loose `renpy-runtime` resources, plus signed `AetherRenpy.framework` and
  `MetalANGLE.framework` embedded by `tools/stage_renpy_ios.py`.
- Android: private Java/JNI sources in the generated Godot Gradle project and a
  deterministic compressed runtime asset. The first launch extracts it into an
  app-private directory named by its content hash, using an atomic completion
  marker; subsequent launches reuse it.

The adapters isolate SDK SDL Objective-C/Java names from Godot’s SDL. The desktop
shim uses SDL’s version-checked dynamic API without replacing the Cython Window
object. The iOS framework adapts selected static SDL entry points and resolves
GL functions from its own MetalANGLE framework.

`AETHER_RENPY_SDK` overrides runtime discovery for development; it must point at
the **prepared native runtime**, not an unmodified desktop SDK. The player also
searches the bundled runtime or `user://RenPy/runtime`.

## Game data and controls

Library scanning recognizes loose RPY, RPC2 compiled scripts and RPA-2/3 markers
without executing Python or unpickling archives. Supported layouts include a
normal `game/` directory, a directly imported game directory, and game data in
`Contents/Resources/autorun/game` inside a macOS application.

Each game runs from a private writable mirror. macOS uses APFS copy-on-write
when available; other filesystems copy the data. The mirror excludes imported
saves and engine caches, rejects external file symlinks and directory symlinks,
and is removed on exit. Original assets remain unchanged. Saves, persistent
data, signing keys, backups and compiled-script statement identities persist
under `user://renpy_saves/<game-identity>/`. Normal refresh and reopening can load
those saves without writing compiled files into the imported project.

The JSON probe uses allowlisted commands (`quit`, keys, controls, debug variable
inspection and renderer screenshots) and atomic command/status files. The same
probe works on all native hosts. Session logs remain under `user://renpy_sessions`.
There is no arbitrary Python-evaluation command.

## Validation

```sh
python3 -m unittest discover -s tests/python -p 'test_renpy*.py'
python3 tools/renpy_smoke.py --sdk /path/to/original-sdk --runtime /path/to/prepared-runtime
python3 tools/renpy_smoke.py --sdk /path/to/original-sdk --runtime /path/to/prepared-runtime --packed
```

The desktop product regression checks normal library launch, same-process and
same-window rendering, Chinese dialogue/choices, optional controls, native saves
and thumbnails, refresh, reopen/load, play-time accounting and preservation of
the original game. The packed case runs an original RPA-only fixture.
macOS is tested with both Godot Metal and OpenGL presentation. The UIKit probe
in `tests/renpy_mobile/ios_host_smoke.mm` exercises the actual iOS native host,
touch input, save/load, pause/resume and same-interpreter reopening.

`tools/renpy_native_probe.py` builds an independent Godot app using the production
native player and frontend for local diagnostics. Linux can run in Xvfb/Mesa;
Android can run in an emulator with the production SDL Activity and runtime
installer. The probe checks Chinese choices, native saves, screenshots, controls,
pause/resume, refresh and return/reopen. CI uses the existing product build
workflow; these native-host probes are run manually when needed.

## Compatibility boundaries

The runtime targets Ren’Py 8/Python 3 games. Ren’Py 7/Python 2, Windows hosting,
Web exports and game-supplied platform-native Python extensions are not supported
by this integration. Importing an arbitrary Python game does not sandbox its
code. A successful fixture does not certify every third-party title.

Ren’Py renders and mixes audio independently; Godot’s provider render-backend,
translation, frame-enhancement and audio-bus options do not apply to this player.
Upstream engine and dependency notices are retained in every staged runtime.
See the [official SDK checksums](https://www.renpy.org/dl/8.5.3/checksums.txt),
[Ren’Py sources](https://github.com/renpy/renpy) and
[platform build sources](https://github.com/renpy/renpy-build).
