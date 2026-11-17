# SystemNNN validation record

Status recorded on 2026-11-17 for the Aether integration worktree. The [runtime document](systemnnn_runtime.md) describes implementation boundaries. Results below are attributed to the coordinating session; this documentation task inspected source and reports and did not rerun runtime tests. Parallel provider fixes and production builds are still in progress, so a pending row must not be promoted to a pass without its final result and revision.

## Available evidence

| Area | Recorded result | What it establishes |
|---|---|---|
| Runtime selector | Four Python tests passed. | Actual CMake native/Web defaults, selective enable and explicit disable. |
| CI initialization | Two Python tests passed; platform/helper shell syntax checks passed. | Submodule initialization and shell parsing, not successful platform builds. |
| Godot shell | Parent reports all five suites exited 0 under Godot 4.6: library, reopen, launch-entry, input mapping and save archive/bank. | Shell regression behavior. Expected warnings report the absent production GDExtension; these runs do not establish native extension linkage or playback. |
| Emberfall child, Windows/Linux | Parent reports `f52d77f` scene tests and fixtures green. | Child engine tests at that revision, not the complete Aether adapter or packaged application. |
| Emberfall child, macOS | Original baseline passed; final runner for `f52d77f` was queued at this snapshot. | Baseline macOS evidence only until the final runner result is collected. |
| Aether provider, local | Parent reports the expanded provider contract passed in approximately 94 seconds, including an actual tiny movie; its fixture alignment issue was fixed and AddressSanitizer checks passed. Native-panel routing policy tests passed. | Synthetic adapter execution, including movie continuation and current slot/settings/Unicode checks. Not a graphical product or real-device audio result. |
| Minigames, local | Parent reports 49,045 Java/C++ board-state observations passed across ten types and four seeds, including rare animation fixtures; sanitizer checks and binding/reward/gallery filtering fixtures passed. | Board-rule and selected frontend/binding behavior. Paint has no clear/reward event by design. No full game or graphical parity claim. |
| Integrated local suite | Parent collected 10/10 configured CTest passes in 167.79 seconds, including the provider contract at 94.98 seconds and both Java compatibility contracts. The ninth native target, minigame-binding, was added after that configure; its separate integrated CTest passed 1/1 in 1.17 seconds. | The collected run covers eight native plus two Java contracts. The current source registers nine native plus two Java; do not describe the newer 11-test inventory as an already collected full-suite pass. |
| Aether hosted desktop adapter | macOS built, then two fixtures failed on font/temp-directory setup; fixes are being submitted for the next hosted run. Windows build failed on OpenAL configuration/debug transitive linkage; source fixes are being submitted for hosted CI. | No final hosted macOS/Windows adapter pass yet. These jobs are separate from the green child-engine tests. |
| Production extension | Build is in progress with Godot-cpp API 4.7 and current FFmpeg 8 / Highway 1.4.0 dependencies because the product APIs exceed the installed system versions; Godot 4.7.2 is available for subsequent verification. | Compilation work is underway. Full graphical application execution remains pending. |
| Mobile linkage | Android/iOS workflow and whole-archive link checks are queued on the branch; a local Android build is compiling the actual FFmpeg target. | Build/link work only. No finished mobile build, exported app execution or device acceptance is claimed. |
| Commercial games / mobile | No Aether acceptance result supplied. | No compatibility or device-runtime claim. |

The current [native test build](../tests/systemnnn_native/CMakeLists.txt) registers nine native contracts: provider, text, startup, progress, audio, presenter, native-panel, minigame and minigame-binding. Java progress and minigame compatibility contracts are added when Python/Java are available. The provider fixture independently authors SPT programs and checks automatic selection, title-to-story, DRAW/dialogue waits, branches, immutable description/read snapshots, serials, PC slot overwrite, failed load/write retention, settings persistence, Unicode startup, pause/input behavior and repeated audio lifecycle. These checks are bounded synthetic cases.

[Generated movie tests](../bridge/systemnnn_runtime/tests/run_movie_test.sh) exercise local MPEG4/AAC and FFV1/PCM media, PTS pacing, stereo conversion, pause, drain/EOF, no-audio-sink completion, delayed audio, malformed input and path resolution. The expanded provider result above includes a tiny real movie. The generated-fixture runner passed with repeated tiny/odd-sized frames; the newly added minigame-binding target passed a separate integrated 1/1 run. The recorded 10-test CTest result still covers its configured inventory only. A later expanded provider-only run passed in 117.13 seconds, including framebuffer-driven Change completion/reward persistence and script-origin Term modal return/cancel. OpenAL contracts use `ALSOFT_DRIVERS=null`; they cannot prove real speaker output or platform audio focus.

## Reproduce the focused checks

Run from the repository root. Use a fresh build directory and dependencies compatible with the selected FFmpeg/OpenAL build.

```sh
python3 -m unittest discover -s tests/python -p test_runtime_selection.py -v
python3 -m unittest discover -s tests/python -p test_runtime_submodule_initialization.py -v
bash -n scripts/build_android.sh scripts/build_ios.sh scripts/build_linux.sh scripts/build_macos.sh scripts/build_web.sh .github/scripts/initialize-private-runtime-submodules.sh
cmake -S tests/systemnnn_native -B build/systemnnn-native -DCMAKE_BUILD_TYPE=Release
cmake --build build/systemnnn-native --config Release --parallel 2
ctest --test-dir build/systemnnn-native -C Release --show-only=json-v1
ctest --test-dir build/systemnnn-native -C Release --output-on-failure --no-tests=error --timeout 120
bash bridge/systemnnn_runtime/tests/run_movie_test.sh
```

Inspect the CTest inventory to ensure the expected contracts were built; a test command that selected no tests is not a pass. [The native workflow](../.github/workflows/systemnnn.yml) records the Windows focused vcpkg configuration and Linux/macOS system dependencies. Keep Release checks enabled as configured by the test targets.

With a compatible Godot executable and imported project resources, run the shell suites:

```sh
"$GODOT_BIN" --headless --path apps/godot_app --script res://tests/systemnnn_library_test.gd
"$GODOT_BIN" --headless --path apps/godot_app --script res://tests/runtime_player_reopen_test.gd
"$GODOT_BIN" --headless --path apps/godot_app --script res://scripts/game_launch_entry_test.gd
"$GODOT_BIN" --headless --path apps/godot_app --script res://scripts/game_input_mapping_test.gd
"$GODOT_BIN" --headless --path apps/godot_app --script res://tests/game_save_archive_test.gd
```

For production acceptance, record parent commit/worktree diff, actual child gitlink and checkout, build preset/triplet, FFmpeg configuration, OpenAL backend, Godot/Godot-cpp versions, test inventory and logs. Then verify the built extension through the actual Godot application, including a fixture session, visible frames, real audio, pause/resume, movie completion/skip/failure and save/load/reopen. Final macOS, Windows/Linux product packaging, Android/iOS exports and device execution need their own evidence.

## Audit reading coverage

The source-review inputs are [EMBERFALL-AUDIT](../../EMBERFALL-AUDIT.md) and [AETHER-ADAPTER-AUDIT](../../AETHER-ADAPTER-AUDIT.md) in this integration workspace. They are historical snapshots, not test logs, and may not travel with a public checkout. Current source supersedes their observations where the adapter has since been implemented.

The Emberfall audit enumerates 227 entries: 11 confirmed full reads, 61 partial reads and **155 unconfirmed/unread entries**. Partial/unconfirmed entries do not satisfy the request to read all core/platform source. Large effects, VM/opcode paths, Java panels and platform implementations remain incompletely reviewed; third-party implementations and all fixtures are not exhaustively covered. The original adapter audit likewise records selected host ranges and public interfaces, with incomplete presenter and Emberfall implementation coverage at its own snapshot. A newer [adapter reading ledger](systemnnn_adapter_reading.md) records full reads of the eight available public non-SystemNNN provider wrappers and their common build boundaries, with separate F/P/U coverage for host, packaging and package-owned engines. Reading those wrappers does not establish complete upstream-engine or whole-project reading.

This documentation update inspected the provider, adapter build, public helper interfaces, selected presenter/startup/progress/audio/movie paths, fixture definitions, branch configuration and both reports. It does not close the original comprehensive-reading request or convert source inspection into runtime proof. In particular, all commands/effects, every modal/minigame, extension scripts, all legacy save layouts, commercial routes and mobile lifecycle remain outside any blanket completeness claim.
