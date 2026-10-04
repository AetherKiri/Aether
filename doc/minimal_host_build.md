# Minimal Host-Only Build (no engine submodules)

This branch (`minimal-host-only`) strips the KiriKiri2 engine and every other
visual-novel runtime out of the native build so the **Godot host extension** and
the **engine_api ABI** can be configured, compiled, and run on their own. It is
the smallest surface you need to reuse AetherKiri's rendering layer and other
cross-engine capabilities while integrating a **new** engine behind the runtime
provider ABI.

## What is compiled

| Target | Source | Role |
| --- | --- | --- |
| `engine_api` | `abi/` | Stable C ABI: dispatcher, runtime-provider registry, crash capture, text transform. No engine dependency. |
| `aether_kiri_godot` | `bridge/godot_extension/` | The whole reusable host layer: `AetherRuntimePlayer`, Godot-native renderer (`RenderingDevice` compute pipelines), GPU bridge, CPU readback fallback, input pipeline, external-texture import, frame-effect host, StoreKit/file-picker/diagnostics glue. |

Plus the Godot project shell in `apps/godot_app/` (GDScript; not compiled by
CMake — Godot loads the two libraries above through `aether_kiri.gdextension`).

## What is NOT compiled

All existing engines and their bridges are optional and are turned off:

- `packages/AetherKrkr` + `bridge/krkr2_runtime` (KiriKiri2 core/plugins, ~370 C++ files)
- `packages/OnscripterYuri` + `bridge/onscripter_runtime`
- `packages/AetherSiglus` + `bridge/siglus_runtime` (Rust)
- `packages/AetherMinori` (Rust)
- `packages/rfvp` + `bridge/rfvp_runtime`
- `packages/AetherInternal` (private E-mote/Live2D/Artemis/CatSystem2)
- `packages/psdfile`, `packages/tjs2Decompiler`, tests, tools

## Build switches introduced

- `AETHERKIRI_ENABLE_KRKR` (default **OFF**) — new option. Guards
  `add_subdirectory(packages/AetherKrkr)` and `bridge/krkr2_runtime`. The
  engine_api ABI is now decoupled from the KiriKiri glue, so `abi/` builds
  without it. With no glue installed, the built-in `"kirikiri"` backend returns
  `ENGINE_RESULT_NOT_SUPPORTED`, which is expected for a host-only build.
- `AETHERKIRI_ENABLE_ONSCRIPTER / SIGLUS / MINORI / INTERNAL` default **OFF**.
- `ENABLE_TESTS`, `BUILD_TOOLS` default **OFF**.

`abi/CMakeLists.txt` now links `spdlog` unconditionally: `engine_api_dispatch.cpp`
uses it outside any internal-only guard, so a minimal build still needs it.

## vcpkg (trimmed)

`vcpkg.json` keeps only what the host layer needs:

- `godot-cpp` (required by `bridge/godot_extension`)
- `spdlog` (+ `fmt`) — required by `engine_api`
- `vcpkg-cmake`, `vcpkg-cmake-config` (host build helpers)

Everything engine-specific (ffmpeg, opencv4, openal-soft, sdl2*, lua, freetype,
libjpeg-turbo, libwebp, jxrlib, unrar, highway, uchardet, llama-cpp, ...) is
removed. Add a dependency back only when the engine you integrate requires it.

## Windows build (MSVC)

The native side links the **dynamic** CRT (`/MD`) so the GDExtension loads into a
**release** Godot editor and matches vcpkg's `x64-windows-static-md` triplet.
Use the **Release** preset; do not mix a Debug vcpkg build (/MDd) with the
extension's forced `/MD` + `_ITERATOR_DEBUG_LEVEL=0`, or the link fails with
`LNK2038`.

Requires: VS 2022 with the C++ workload (MSVC + Windows SDK), CMake 3.28+,
Ninja, vcpkg, and a Godot 4.7 editor (godot-cpp overlay port is `10.0.0-rc1`,
which pairs with Godot 4.7; `.gdextension` `compatibility_minimum = "4.6"`).

```bat
:: env.bat loads vcvars64 + sets VCPKG_ROOT + proxy + TMP on D:
cmake --preset "Windows Release Config" -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL
cmake --build --preset "Windows Release Build" --target engine_api aether_kiri_godot
```

The build stages `aether_kiri_godot.dll` and `engine_api.dll` into
`apps/godot_app/bin/windows/release/`. Run the shell UI with:

```bat
Godot_v4.7-stable_win64_console.exe --path apps\godot_app
```

No engine is registered, so the app boots to the home/library/settings UI; games
report `ENGINE_RESULT_NOT_SUPPORTED` until a provider is added.

## Integrating a new engine

A new engine implements `engine_runtime_provider_v1_t`
(`abi/include/engine_runtime_provider.h`) and registers with
`engine_register_runtime_provider()`. It must **not** add another Godot Player
class. Three wiring points:

1. Add `bridge/<engine>_runtime/` producing `aether_<engine>_runtime`, modeled on
   `bridge/onscripter_runtime` (a `RegisterRuntimeProvider()` entry point).
2. In `bridge/godot_extension/CMakeLists.txt`, add an
   `if(TARGET aether_<engine>_runtime)` link block + `AETHERKIRI_WITH_<ENGINE>`
   define (mirror the onscripter/siglus blocks).
3. In `bridge/godot_extension/src/aether_runtime_player.cpp`, add a
   `#if defined(AETHERKIRI_WITH_<ENGINE>)` include and a guarded
   `RegisterRuntimeProvider()` call inside `InitializeAetherRuntime()`.

Rendering: the host already owns presentation. The provider only produces a
frame through one of:

- `get_godot_native_frame_texture` — Godot-native path (return a
  `RenderingDevice` texture id); preferred.
- `read_frame_rgba` + `get_frame_desc` — CPU readback (debug fallback).
- `set_render_target_surface` / `set_render_target_iosurface` — GPU bridge for
  external native GPU targets.
