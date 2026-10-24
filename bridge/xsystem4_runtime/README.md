# AliceSoft System 4 native runtime

`packages/xsystem4` uses the dedicated
[`aether` branch](https://github.com/AetherKiri/xsystem4/tree/aether) of the public
AetherKiri fork for native embedding hooks. The fork's default `master` branch
is reserved for upstream synchronization. Aether pins an exact commit from
`aether`, including its recursive `subprojects/libsys4` dependency. Initialize
both with:

```sh
git submodule update --init --recursive packages/xsystem4
```

Import the complete game directory into the visual-novel library. Detection
requires `System40.ini` or `AliceStart.ini` and an `.ain` script, ignoring case.
The app passes the directory to runtime `xsystem4`; Windows launchers are not
executed. On iOS, place the directory in Aether's existing `Games` folder.
Virtual controls use the shared visual-novel overlay and start disabled.

## Native host

The VM, HLL plugins, archives, FreeType/FNL fonts, audio mixer and FFmpeg decoder
run in the Aether process. A dedicated VM thread owns an offscreen GL context:

| Platform | Game renderer | Presentation |
| --- | --- | --- |
| macOS | CGL / OpenGL | RGBA frame → existing Godot texture |
| iOS/iPadOS | EAGL / OpenGL ES 3 | RGBA frame → existing Godot texture |
| Android | EGL / OpenGL ES 3 | RGBA frame → existing Godot texture |
| Linux | EGL / OpenGL ES 3 | RGBA frame → existing Godot texture |

There is no helper process, standalone SDL window or WebAssembly. The current
adapter reads back each frame before uploading it to Godot; it does not expose
a shared GPU texture. Upstream's process-global VM permits one System 4 session
at a time. Closing joins the VM thread and releases session resources; fatal
VM errors are contained at the native host boundary instead of exiting Aether.

The host supplies pointer/touch positions in the game's logical frame,
zero-based engine mouse buttons, Windows virtual key codes and UTF-8 text.
Press/release transitions remain observable to games that poll held state.
InputString IME requests activate the host's native keyboard. Pausing suspends
the VM and SDL audio; shaders, fonts, movies, HLL bindings and input are reset
when the session ends.

Saves go under `<writable>/xsystem4/<script-identity>/`, separate from game assets.
The identity uses the AIN filename, size and leading script data, so moving a
game or updating an iOS app container does not create a new save namespace.
Existing saves in the imported game's `SaveData` are not automatically copied.

`xsystem4_encoding=auto` ignores INI comments and gives a GBK-family `GameName`
priority over untranslated Japanese labels in other values. It then checks the
remaining configuration and defaults to Shift-JIS when no GBK evidence is found,
so original Japanese games keep their native encoding. Quoted `;` and `//`
remain part of string values. `gbk` and `sjis` can be set explicitly before
opening. The default font comes from Aether's staged CJK font; a game-supplied
`.xsys4rc` can provide font paths.
Shaders are embedded in the library and do not depend on the process directory.

## Building and validation

`AETHERKIRI_ENABLE_XSYSTEM4` defaults to `ON` for the native app. A local fork can
be selected with `AETHERKIRI_XSYSTEM4_DIR`. Dependencies include SDL2, FFmpeg,
FreeType, libsndfile, cglm, libffi, uchardet, Flex and Bison. Linux additionally
needs EGL and GLES development libraries. iOS packaging merges both the adapter
archive and `libsys4.a` into the existing static extension and links OpenGLES.

The asset-free library/import/input regression runs with:

```sh
Godot --headless --path apps/godot_app --script res://tests/xsystem4_library_test.gd
```

The native JSON probe builds the production provider without the Godot shell:

```sh
cmake -S tests/xsystem4_native -B out/xsystem4-native -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake" \
  -DVCPKG_MANIFEST_MODE=OFF -DVCPKG_TARGET_TRIPLET=arm64-osx \
  -DVCPKG_INSTALLED_DIR="$VCPKG_ROOT/installed"
cmake --build out/xsystem4-native --parallel 4
ctest --test-dir out/xsystem4-native --output-on-failure
out/xsystem4-native/aether_xsystem4_native_probe GAME_DIR OUTPUT_DIR \
  apps/godot_app/assets/fonts/aetherkiri-runtime-cjk.otf
```

Write an atomically replaced `OUTPUT_DIR/command.json` with increasing `seq`:

```json
{"seq":1,"action":"capture","name":"title"}
```

Other actions are `click` (`x`, `y`, `button`: left=0/right=1/middle=2, `count`),
`key` (`key`: Windows virtual key code, `count`), `pause`, `resume`, `reopen` and
`quit`. `status.json` acknowledges each command and reports frame dimensions,
serial, selected encoding, save directory and errors. Use a fresh output
directory, or remove an earlier command before starting a new probe.

The native contract includes encoding regressions for Chinese and Japanese
configurations, mixed-encoding comments, Chinese title priority, inline comments,
quoted comment markers, ASCII titles and explicit encoding overrides. Each case
also checks that a non-ASCII AIN filename is resolved before script parsing.
The scene-keeper contract checks that Chinese dialogue can use original
Shift-JIS VM structure names, GBK names take priority when both exist, and
scene serialization follows the current script's structure indices after
switching games. These tests use synthetic data without game assets.

On 2026-10-18, the supplied **Sengoku Rance v1.01** Chinese build was tested on
macOS arm64: 800×600 startup, opening movie/audio, title, new game, Chinese
dialogue and character rendering, pointer advancement and the in-game menu.
The same flow was exercised through Aether's main window with its Metal Godot
renderer. Native pause/resume, closing and repeated reopening during a movie
were also checked. iOS and Android context/source compile checks passed; device
playback and Linux playback still need validation. No game files are included.

On 2026-10-24, the supplied Chinese builds of **Rance01** (1024×768) and
**Rance02** (800×600) were tested with the macOS arm64 native JSON probe: startup,
title/menu, new game, Chinese dialogue and pointer advancement. Rance02's
GBK-encoded `CodeName` resolves its Japanese-named AIN file, and 20 consecutive
dialogue clicks pass the scene-history boundary with original Shift-JIS
structure names. These checks used
isolated probe save directories; the packaged app and other platforms were not
retested for this encoding change.
