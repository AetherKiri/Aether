# Cloud iOS Simulator gameplay acceptance

This harness installs the actual Godot app, uses XCUITest for system touch,
software keyboard text, Home, foreground and game exit, and observes the bundled
native Ren'Py provider. It creates a disposable cloud Simulator unless an
explicit cloud UDID is supplied. It never substitutes a stub runtime or fake UI.

Use a cloud Apple Silicon macOS runner with licensed Xcode/iPhoneSimulator SDK,
an installed iOS Simulator runtime, the repository's Godot editor/export template,
vcpkg/Rust build prerequisites, and the rebuilt cooperative Renios payload. The
Simulator export uses Compatibility rendering and separate simulator libraries.
Ren'Py's SDL/Python/FFmpeg closure is embedded in `AetherRenPyRuntime.framework`,
with the matching `MetalANGLE.framework` slice. No Apple developer signing
identity is needed for the Simulator; the packages are signed ad hoc. Godot's
existing Team ID is retained solely to satisfy its export-project validation;
the Xcode simulator build explicitly clears the signing team.

From the repository root, after the actual iOS source runtime build:

```bash
export AETHERKIRI_ENABLE_RENPY=ON
export AETHERKIRI_ENABLE_INTERNAL=OFF
export AETHERKIRI_RENPY_MOBILE_ROOT="$PWD/out/renpy-mobile-source/payload"
bash scripts/build_ios.sh debug --simulator --simulator-arch=arm64
python3 tools/run_renpy_ios_device_acceptance.py \
  --cloud-simulator \
  --app out/godot/ios-simulator-arm64/debug/build-simulator-arm64/Aether.app \
  --output-dir out/renpy-ios-gameplay \
  --overall-timeout 600
```

Public CI uses `AETHERKIRI_ENABLE_INTERNAL=OFF`; a build authorized to access
the private package can retain its normal Internal build configuration.
Archive the simulator `.app` ZIP, runtime source manifest, framework link/export
reports, the entire gameplay output (including `gameplay.xcresult`), and the
Xcode export/build logs. The gameplay directory contains real provider images,
Simulator screenshots, pixel comparisons, UI action acknowledgments, the Ren'Py
script checkpoints, native provider/lifecycle observations and system logs.

`result.json` says `passed` only after real native images appear in OS
screenshots, actual touches and exact keyboard text reach the game, Home pauses
the native runtime, foreground resumes it with a new frame, and the game's Quit
action destroys the runtime and restores the existing application game library,
whose actual viewport pixels must also appear in the system screenshot. The
UIKit host remains foreground; terminating it is not required to exit a game.
Exit code `2` means
`not_run` because tools, runtime or the real app are missing; `1` means a real
execution did not meet the required evidence. Neither result proves phone
gameplay. Simulator results also do not establish physical iPhone support.

The standalone UI test project targets an already installed app by its real
bundle ID. Host commands and acknowledgments use only the UI test runner's own
Documents directory; the game and observer independently write into the test
app's Documents directory. Only the two acceptance directories and one-shot
debug request are reset. The Simulator software-keyboard preference is restored
when the harness exits. This harness has no installation-only or skip-gameplay
mode.
