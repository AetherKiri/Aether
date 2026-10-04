# Embedded ExHIBIT provider

Opt-in native provider for ExHIBIT titles, adapting the checked-in
`packages/AetherExhibit` core to `engine_runtime_provider_v1_t`. Godot
presents the core's software-composited RGBA8888 frame and owns the window
and input coordinates; the provider ignores `set_surface_size` exactly like
the ONScripter bridge, because the core composes at script-native
resolution.

Unlike every other runtime package, AetherExhibit is checked in directly
rather than tracked as a submodule: there is no upstream ExHIBIT core to
follow, since the engine semantics were derived from binary analysis of a
specific title.

## Build

Enable `AETHERKIRI_ENABLE_EXHIBIT=ON` on the normal application CMake
preset; the default is OFF. The root `CMakeLists.txt` adds
`packages/AetherExhibit` (target `aether_exhibit_core`) and then this
bridge, and `bridge/godot_extension` links the result into
`aether_kiri_godot` with `AETHERKIRI_WITH_EXHIBIT=1`. Web/Emscripten is
excluded. There is no Rust, no vcpkg dependency and no toolchain
requirement beyond the host C++17 compiler.

The core alone configures and ctests headless without the extension:

```sh
cmake -S packages/AetherExhibit -B out/exhibit-core-check -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build out/exhibit-core-check
ctest --test-dir out/exhibit-core-check --output-on-failure
```

## Status and behavior

- `probe` scores 95 when `Runtime::looks_like_game` matches
  (`ExHIBIT.ini` plus at least one `.rld` scenario in `rld/` or the root,
  case-insensitive). `ExHIBIT.ini` is unique to this engine, so the top
  score cannot steal directories from the other providers.
- `open_game` is synchronous: the core probes its markers and composes the
  initial picture inline, so the provider maps the bool straight onto the
  result with no startup-state polling. A non-null `startup_script_utf8`
  is logged but not honoured yet; ExHIBIT's equivalent is `[exec] entry=`
  in `ExHIBIT.ini`.
- The core currently renders a diagnostic placeholder frame (a 1280x720
  gradient with a sweeping band, border and centred box). That is
  intentional: it proves the probe → create → open_game → tick → frame →
  host-upload chain before the real decoders (.rld bytecode, .gyu images,
  layout/i18n text, script VM, compositor) land beside it.
- `tick` forwards the caller-provided `delta_ms`. `pause`/`resume` set a
  provider-side flag; a paused runtime keeps returning OK without ticking.
- `send_input` translates every host input event kind (pointer
  down/move/up/scroll, key down/up, text input, back) into the core's
  queued `InputEvent`. A saturated queue maps to
  `ENGINE_RESULT_INVALID_STATE` so a stuck drain stays visible.
- `set_option` forwards to the lenient core `set_option`, including
  `renderer` (Auto/Gpu/Cpu preference; the GPU bridge is future work, so
  everything resolves to software compositing for now).
- No GPU bridge, native-window, menu, IME or platform-request callbacks
  are implemented yet; those vtable slots stay null.
