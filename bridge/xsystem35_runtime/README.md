# AliceSoft System 3.5 / 3.9 native runtime

`packages/xsystem35` pins the `aether` branch of
[AetherKiri/xsystem35-sdl2](https://github.com/AetherKiri/xsystem35-sdl2).
The fork's `master` branch is reserved for upstream synchronization. Initialize
the package with:

```sh
git submodule update --init packages/xsystem35
```

Import the complete game directory into the visual-novel library. Detection
uses `*SA.ALD` or `ADISK.ALD`, ignoring case. A System4 INI takes precedence,
so System4 archives continue to use `xsystem4`. Selecting a Windows launcher
still opens its asset directory; Windows executables are never executed.
On iOS, use the existing `Games` directory. The shared virtual controls start
disabled, as for other visual novels.

## Native host

The VM runs on a worker thread inside Aether. SDL2's software renderer draws
to an RGBA surface, which the provider presents through the existing Godot
texture in Aether's window. The same native C/C++ source is wired for macOS,
iOS/iPadOS, Android and Linux. There is no SDL video window or WebAssembly.
Dependencies are SDL2, SDL2_mixer with its mpg123 feature, FreeType, WebP,
zlib, iconv and uchardet. MIDI additionally requires a MIDI-capable SDL_mixer
build and suitable instrument banks.
`AETHERKIRI_ENABLE_XSYSTEM35` defaults to `ON` for native exports; a local
checkout can be selected with `AETHERKIRI_XSYSTEM35_DIR`.

The adapter maps logical pointer/touch coordinates, mouse buttons, wheel,
Windows virtual key codes and UTF-8 text into a private SDL event queue.
Press/release transitions remain separate when scripts poll held input.
Native text-input dialogs use the host keyboard state. Pause suspends the VM
and audio, and clears held input. Closing joins the worker and releases VM,
graphics, font, sprite, archive, modal and audio resources. VM errors return
to the host instead of terminating Aether. One System35 VM can run at a time.

Game-relative file paths are resolved without changing the process working
directory. New saves and settings go to
`<writable>/xsystem35/<scenario-identity>/`; the identity uses scenario archive
names, sizes and leading data, so an iOS container change preserves it.
Existing saves in the imported directory are not automatically migrated.

## Text encodings

Original Japanese games default to Shift-JIS. Unicode translations keep
upstream's script-controlled UTF-8 mode (`ZU`). For older Chinese translations,
`xsystem35_encoding=auto` detects GBK-family text from the decoded AIN `MSGI`
messages, excluding Japanese metadata and binary script instructions.
`gbk` and `sjis` are explicit overrides for the legacy text encoding.
The runtime handles GBK double-byte boundaries in messages/string operations
and converts text with iconv before drawing with Aether's CJK font.

The supplied RanceIV Chinese build uses UTF-8; the supplied Rance5D Chinese
build uses GBK. GBK trail bytes must stay inside their character even when they
look like a script opcode. Mosaic transitions use bounded downsample/magnify
rectangles so the software renderer does not blit enormous negative rectangles.

## Older System3 DAT games

`ADISK.DAT` plus `ACG.DAT` is classified separately as `system3`. Those games
run through Aether’s separate [system3-sdl2 native runtime](../system3_runtime/README.md). In particular,
the supplied Chinese Rance4.1 and Rance4.2 builds use DAT; upstream's supported
Rance4.1/4.2 releases are the newer ALD editions. See the
[upstream compatibility table](https://github.com/AetherKiri/xsystem35-sdl2/blob/master/game_compatibility.md).

## Validation

The asset-free library/import/input regression is:

```sh
Godot --headless --path apps/godot_app --script res://tests/xsystem35_library_test.gd
```

Build the production provider and native JSON probe independently of Godot:

```sh
cmake -S tests/xsystem35_native -B out/xsystem35-native -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake" \
  -DVCPKG_MANIFEST_MODE=OFF -DVCPKG_TARGET_TRIPLET=arm64-osx \
  -DVCPKG_INSTALLED_DIR="$VCPKG_ROOT/installed"
cmake --build out/xsystem35-native --parallel 4
ctest --test-dir out/xsystem35-native --output-on-failure
out/xsystem35-native/aether_xsystem35_native_probe GAME_DIR OUTPUT_DIR \
  apps/godot_app/assets/fonts/aetherkiri-runtime-cjk.otf
```

Atomically replace `OUTPUT_DIR/command.json` with increasing `seq` values:

```json
{"seq":1,"action":"capture","name":"title"}
```

Actions include `capture`, `click` (`x`, `y`, `button`, `count`, `hold_ms`),
`key` (Windows virtual key code), `pause`, `resume`, `reopen` and `quit`.
`status.json` acknowledges commands and reports the frame, selected legacy
encoding, save directory and error. Text hooks are enabled only in the native
probe for diagnostics. Use a fresh output directory for each run.

Four native CTests cover provider detection/ABI, contained errors, repeated
opening and RGB-world allocation, unchanged process cwd, isolated writes,
encoding auto-detection/overrides, GBK/Shift-JIS/UTF-8 conversion and character
boundaries, software mosaic colors at multiple scales, and actual MP3 decoding/playback
through SDL_mixer with synthetic silent frames. They use synthetic
archives and text without game assets.

On 2026-10-24, macOS arm64 native JSON probes verified RanceIV Chinese startup,
640×480 rendering, entering the game, Chinese UI/dialogue, map navigation, MP3 background music, pause/resume
and reopening. Rance5D Chinese passed GBK startup, Chinese title/dialogue, entering the
game, the first-chapter mosaic transition, repeated pointer input, pause/resume
and reopening. The supplied DAT-based Rance4.1/4.2 were checked and rejected by
the System35 provider. Whole-game completion, save/load flows and playback on
other platforms remain unverified. No game assets are included.

The exported macOS Debug app was also checked with its Metal Godot renderer:
RanceIV map navigation and Chinese dialogue, and Rance5D new game and Chinese
dialogue. Both use the same Aether window and production provider.
