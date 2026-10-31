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
PartsEngine releases its shader program and parts table and clears its
initialization state before the GL context is destroyed. Reopening therefore
creates those resources in the new context instead of reusing stale handles.

Saves go under `<writable>/xsystem4/<script-identity>/`, separate from game assets.
The identity uses the AIN filename, size and leading script data, so moving a
game or updating an iOS app container does not create a new save namespace.
Existing saves in the imported game's `SaveData` are not automatically copied.

`xsystem4_encoding=auto` ignores INI comments and gives a GBK-family `GameName`
priority over untranslated Japanese labels in other values. It then checks the
remaining configuration and defaults to Shift-JIS when no GBK evidence is found,
so original Japanese games keep their native encoding. Short samples are
repeated at line boundaries before statistical detection, avoiding insufficient
evidence for short GBK titles such as Sengoku Rance. Quoted `;` and `//`
remain part of string values. `gbk` and `sjis` can be set explicitly before
opening. The default font comes from Aether's staged CJK font; a game-supplied
`.xsys4rc` can provide font paths.
Use `path/to/font.ttc:1` to select a face from a TrueType font collection.
Shaders are embedded in the library and do not depend on the process directory.

Resource archives normally use the AIN script's basename. Some translations
rename the script while retaining the original ALD/AFA names. If no archive
matches the selected script, the runtime uses the sole archive family in the
game directory. Exact script matches take priority; multiple fallback families
are reported and left unselected. Matching ignores ASCII case, keeps ALD
volumes together and does not mix similarly prefixed archive families.

`system.Exit(code)` and returning from the script's main function complete the
session even when the game returns a nonzero process exit code. The host then
returns to the visual-novel library and can reopen the game. VM errors and
assertion failures remain errors; their diagnostics are preserved. Games that
exit before their first frame use the same completion notification.

## Building and validation

`AETHERKIRI_ENABLE_XSYSTEM4` defaults to `ON` for the native app. A local fork can
be selected with `AETHERKIRI_XSYSTEM4_DIR`. Dependencies include SDL2, FFmpeg,
FreeType, libsndfile, SDL2_image, cglm, libffi, uchardet, Flex and Bison. Linux additionally
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

Other actions are `move` (`x`, `y`), `click` (`x`, `y`, `button`: left=0/right=1/middle=2, `count`),
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

The AFA contract covers standard v1/v2 indexes and fan-repacked INFO chunks
whose length excludes the 16-byte INFO header. The reader retries that length
variant only after normal decompression fails, within the index region, with
the original checksum and exact output-size checks. Corrupt, truncated and
out-of-bounds indexes are rejected. Both file I/O and memory-mapped entry
loading are tested. The compatibility adapter is generated in the build
directory; imported archives and the pinned libsys4 sources are unchanged.

The CG adapter uses the existing SDL2_image dependency to decode 24/32-bit TGA
resources, including RLE, image IDs, alpha and both axis origins. It validates
pixel/packet bounds before decoding and supplies RGBA data and CG metrics to
the existing renderer. Its synthetic contract checks channel order, alpha,
orientation and malformed/truncated data without game assets.

Rance Quest's numeric-string CG interface is recognized from its `TapirEngine`
library when a translation changes the displayed title. MonsterInfo determines
its own Shift-JIS/GBK grammar encoding independently of dialogue, preserves
resource identifiers and restores the dialogue encoding after parsing. GBK
dialogue that requests a Shift-JIS-only FNL face uses Aether's Unicode CJK font;
Japanese games retain their original FNL face. Synthetic contracts cover
renamed/Chinese/Japanese/English titles, metadata encoding combinations,
malformed metadata and font selection across encoding changes.

The asset-discovery contract loads synthetic ALD/AFA payloads through the real
asset manager. It covers renamed scripts, multi-volume ALDs, BGM/sound and
sidecar selection, exact-match priority, ambiguous families, overlapping
prefixes, archive-looking directories, mixed ASCII case and original Japanese
script names. No game assets are included.

The lifecycle contract runs encrypted synthetic AIN scripts through the real
provider: explicit exit and main return with zero, positive and negative codes,
early completion before a frame, reopening the same runtime and genuine VM
errors after clean exits. The shell's handle-recreation regression also covers
System 4.

The graphics contract draws through the production renderer and offscreen
context, checking pixels while switching between solid fills and textured
rectangles/quadrilaterals. Inactive shader attributes have location `-1` and
must not be passed to vertex attribute APIs; mobile drivers can remove unused
UV inputs from fill shaders. The test retains GL errors through presentation
so an invalid draw cannot be hidden by clearing errors before frame readback.
On macOS, an independent CGL renderer query marks this GPU test as skipped
(exit code 77) only when no hardware-accelerated renderer is available, as on
hosted virtual machines. Renderer-query errors and all context, shader,
framebuffer and pixel-check failures still fail the test.

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

On 2026-10-25, a regression with the short GBK GameName in **Sengoku Rance**
was reproduced: Shift-JIS was incorrectly selected, corrupting the title text
and stalling new-game initialization. After the fix, native and exported macOS
Debug probes confirmed automatic GBK selection, Chinese title/menu, new-game
startup and 20 dialogue advances with backgrounds and characters. The packaged
app used its existing Metal presentation and existing Aether save namespace.
Synthetic regressions cover short Chinese, Japanese kanji and halfwidth-kana
titles, alongside the existing mixed-encoding fixtures and explicit overrides.

On 2026-10-25, the supplied Chinese **Rance IX / The Helmanian Revolution**
build failed before its first frame because `Rance9CG.afa` and `Rance9CGEx.afa`
store the compressed index payload length rather than the full INFO length.
After the compatibility fix, the native JSON probe reached the opening movie,
Chinese title/menu and new-game narration. The exported macOS arm64 Debug app
also passed the movie, title, new game and 20 dialogue clicks, showing Chinese
text, backgrounds and characters through Aether's Metal presentation. The
three native CTests passed. Battle/3D flows, save/load, full-game completion
and other platforms were not tested for this change. No game assets included.

On 2026-10-25, the supplied Chinese **Rance08 / Rance Quest Magnum** build
reproduced missing numeric CG bindings, a Japanese MonsterInfo parse failure,
unsupported TGA title assets and empty Chinese FNL text. The native JSON probe
confirmed startup, title/menu and Chinese help text after the fixes. The
exported macOS arm64 Debug app passed title/menu, new game and 20 dialogue
clicks with Chinese names/text, backgrounds and characters using Metal
presentation. All six native CTests passed. Battle/3D flows, save/load,
full-game completion and other platforms remain unverified. Imported game
assets are unchanged and are not included in this repository.
