# AliceSoft System 1–3 native runtime

`packages/system3` pins the `aether` branch of
[AetherKiri/system3-sdl2](https://github.com/AetherKiri/system3-sdl2).
The fork’s `master` branch is reserved for upstream synchronization.

```sh
git submodule update --init --recursive packages/system3
```

Import the complete DAT game directory into the visual-novel library. Detection
requires a scenario archive (`ADISK.DAT`, `GDISK.DAT`, `AGAME.DAT` or `ADISK.PAT`)
and `ACG.DAT` or `GCG.DAT`, ignoring case. System4 INI and System35 ALD markers
take precedence. Windows launchers select their containing asset directory.
On iOS, use the existing `Games` folder. Shared virtual controls default off.

## Native host

The C++ VM runs on a worker thread. SDL2’s software renderer produces RGBA frames
for the existing Godot texture inside Aether’s window. The same native source is
wired for macOS, iOS/iPadOS, Android and Linux. No SDL video window or WebAssembly
is involved. `AETHERKIRI_ENABLE_SYSTEM3` defaults to `ON` for native exports;
`AETHERKIRI_SYSTEM3_DIR` selects an alternate checkout.

Mouse/touch coordinates, buttons, wheel and Windows virtual keys enter a private
queue. Held presses and releases remain separate between interpreter polls.
Pause suspends the VM and its SDL audio device and clears held inputs. Closing
joins the worker and releases graphics, fonts, archives and audio. C++ exceptions
contain fatal VM errors without terminating Aether. One System3 VM can run at a
time. Dependencies are SDL2, SDL2_ttf and the fork’s pinned ymfm; the existing
native MP3/Ogg/WAV decoders and FM emulation provide audio without an external
MIDI device.

Relative resources resolve against the selected game root, including Windows
backslashes and inconsistent filename case, without changing process cwd.
New saves and read-history data go to `<writable>/system3/<scenario-identity>/`.
The identity uses archive content rather than the absolute path so iOS container
changes do not orphan saves. Existing saves in the imported game are read as a
fallback; a saved slot inside Aether takes precedence. Imported files are not
overwritten.

## Text and translated games

The game’s `system3.ini` retains its `game`, `encoding`, `fontfile` and `playlist`
settings. Original games default to Shift-JIS, while Unicode translations can
select UTF-8. If the game does not specify a font, Aether supplies its CJK font.
`system3_encoding=auto` preserves the game configuration; `sjis`, `utf8` and
`utf-8` are explicit overrides. Text hooks default off in the product and are
enabled only by the native diagnostic probe.

The supplied Chinese Rance4.1 and Rance4.2 DAT editions explicitly select their
game IDs, UTF-8, a Chinese font and MP3 playlists. They use this runtime; their
newer ALD editions continue to use xsystem35.

## Validation

```sh
cmake -S tests/system3_native -B out/system3-native -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake" \
  -DVCPKG_MANIFEST_MODE=OFF -DVCPKG_TARGET_TRIPLET=arm64-osx \
  -DVCPKG_INSTALLED_DIR="$VCPKG_ROOT/installed"
cmake --build out/system3-native --parallel 4
ctest --test-dir out/system3-native --output-on-failure
Godot --headless --path apps/godot_app --script res://tests/system3_library_test.gd
out/system3-native/aether_system3_native_probe GAME_DIR OUTPUT_DIR \
  apps/godot_app/assets/fonts/aetherkiri-runtime-cjk.otf
```

The probe accepts atomic `command.json` replacements with an increasing `seq`:

```json
{"seq":1,"action":"capture","name":"title"}
```

Actions are `capture`, `click` (`x`, `y`, `button`, `count`, `hold_ms`), `key`
(Windows virtual key code), `pause`, `resume`, `reopen` and `quit`. `status.json`
acknowledges commands and reports the frame, errors, isolated save path and
audio peak. Tests use synthetic archives or upstream’s checked-in scenario
fixtures, without game assets. Contracts cover detection, contained errors,
repeated opening, RGBA reads, pause/resume, save fallback/isolation, unchanged
cwd, Chinese UTF-8/Japanese Shift-JIS and all four System 1/2/3/Gakuen King
interpreter variants. Other platforms and full-game completion need separate
playback verification.

On 2026-10-24, macOS arm64 native JSON probes and the exported Debug app
verified Chinese Rance4.1/4.2 DAT startup, 640×400 frames, Chinese menus and
dialogue, graphics, 20 dialogue advances and MP3 music. Both games’ existing
imported saves were loaded in the native probe. Rance4.1 additionally saved an
isolated slot and loaded it after reopening; Rance4.2 passed pause/resume and
reopening. This is initial-flow coverage, not full-game completion. iOS,
Android and Linux playback remains unverified.
