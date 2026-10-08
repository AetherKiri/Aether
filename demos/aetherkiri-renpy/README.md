# AetherKiri Ren'Py fixture

This is a real, minimal Ren'Py project used to validate the AetherKiri
Ren'Py runtime path. It exercises:

- startup and scene rendering with a bundled SVG image
- text rendering and menu navigation
- pointer/touch activation of screen buttons
- `renpy.input` text entry
- a blocking `renpy.pause` that the host must pause/resume around
- returning from the script and an explicit quit action

Run it with an official Ren'Py SDK:

```bash
RENPY_SDK=/path/to/renpy-sdk bash ../../tools/run_renpy_smoke.sh
```

The automated smoke command compiles the project and initializes Ren'Py. A
device or simulator run is still required to verify the host lifecycle and
input behavior on mobile.

For a real **cloud-hosted Android** debug APK and authorized device/emulator:

```bash
python3 tools/run_renpy_android_device_acceptance.py \
  --apk out/godot/android/debug/Aether-debug.apk \
  --serial emulator-5554 --cloud-device \
  --output-dir /tmp/aether-renpy-android-acceptance
```

Run this command from the repository root inside the cloud task. It installs the
APK with adb, uses Android `run-as` to stage this public demo and a one-shot debug
request in the app's private test directory, and launches the actual app. It
requires a debuggable APK containing the native Ren'Py runtime; stock RAPT alone
does not satisfy the host lifecycle ABI. It does not use a user computer.

The device mode is enabled only by `game/aether-device-request.json`. Real
Ren'Py statements write a fresh run ID into `aether-device-checkpoints.jsonl`.
The harness requires actual OS touch down/up, Android text/Enter, a visible
system keyboard requested by native text-input state, Home/foreground lifecycle
pause/resume, another game touch after resume, and explicit `renpy.quit` followed
by observed native exit, engine teardown, and removal of the actual Android
activity. [Android may retain a cached process](https://developer.android.com/guide/components/activities/process-lifecycle);
its PID is recorded separately.
The regular interactive fixture
remains available when the request file is absent.

Evidence includes APK SHA-256, device build fingerprint, adb command results,
the Ren'Py script checkpoints, native provider RGBA PNGs, OS screenshots,
pixel-comparison reports, native pause/resume/exit state, and process logcat.
Screenshots must show the same nonblank pixels as the provider's real frame;
resume additionally requires a new native frame serial after the pause.
viewport fallback images, colorful system screens, startup-only checks, and
simulated provider frames cannot satisfy this gameplay run.

`result.json` distinguishes `passed`, `failed`, and `not_run`. Exit status is
respectively 0, 1, or 2. Missing tools, device, APK, or permitted debug staging
produce `not_run`; a timeout or missing gameplay/frame/lifecycle evidence after
launch is a failure. Neither result means mobile gameplay passed. This Linux
cloud task cannot execute iOS Simulator acceptance without an authorized macOS
cloud runner with Xcode/iOS Simulator; iOS execution remains unverified.

The automatic Android text check covers an ASCII string and Enter from the
system keyboard path. Unicode text and IME composition need separate real
device coverage before claiming those input methods were tested.
