# Native Flash player

`packages/ruffle` is a pinned upstream checkout. The bridge depends on its
core, wgpu renderer, and software video decoder without patching the submodule.
Godot owns the UI, audio device, and input overlay.

The Rust static library exposes a small C ABI consumed by
`bridge/godot_extension/src/flash_player.cpp`. Ruffle renders into an offscreen
GPU texture; RGBA readback feeds a Godot `ImageTexture`. Its audio mixer feeds a
44.1 kHz stereo `AudioStreamGenerator`. Input coordinates account for the
letterboxed image, while the shared visual-novel controls supply virtual keys
and pointer events. Focus loss pauses playback and releases held input.
The Flash joystick uses arrow keys. The header offers Back and Refresh only
while the menu options are open; it stays hidden when virtual keys are shown.

SharedObject storage is under `user://flash_saves`, with hashed filenames and
atomic replacement. Relative local resources resolve beside the imported SWF.
The app's bundled CJK font supplies device-font fallback. Remote downloads,
browser scripting, and Flash playback in Web exports are currently unavailable.
Playback requires a Metal, Vulkan, or DX12 adapter supported by wgpu.

## Build

Use current stable Rust and Java 17 or newer. All Rust runtimes in the final
extension must use the same toolchain. The normal native build scripts enable
Flash by default; `AETHERKIRI_ENABLE_FLASH=OFF` disables the native player.

```sh
git submodule update --init packages/ruffle
RUSTUP_TOOLCHAIN=stable ./build.sh macos debug
```

Keep Java's `bin` directory on PATH. The build uses the committed Cargo lockfile.
When changing the Ruffle gitlink, regenerate that lockfile and repeat the tests.

## Validation

Library tests run headlessly and use isolated temporary catalogs. They cover
SWF detection, import pickers, iOS-style directory scanning, search, navigation,
catalog isolation, removal, localization, and virtual input forwarding:

```sh
"$GODOT_BIN" --headless --path apps/godot_app \
  --script res://tests/flash_library_test.gd
```

Native tests require a GPU adapter but no window. They use fixtures from the
pinned Ruffle checkout to verify rendering, animation, AVM1/AVM2 execution,
mouse and key events, pause/resume, MP3 mixing, and persistent SharedObjects:

```sh
RUSTUP_TOOLCHAIN=stable cargo test --locked \
  --manifest-path bridge/flash_runtime/Cargo.toml -- --ignored --nocapture
```

After building the Godot extension, run the actual player smoke test with a
window. It verifies changing textures, pause, restart, virtual controls, viewport
resizing, return to the library, and invalid-file errors:

```sh
"$GODOT_BIN" --path apps/godot_app --script res://tests/flash_player_smoke.gd
```

`AETHERKIRI_TEST_FLASH` can override the default animation fixture;
`AETHERKIRI_FLASH_CAPTURE_DIR` saves screenshots. The native smoke test bypasses
first-use legal dialogs only inside its test subclass.
