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

## A small manual Android phone check

An APK that passes compilation, payload checks and signing is a test candidate;
it does not establish that mobile gameplay works. Use the ARM64 artifact on an
Android 8 or later phone with a 64-bit ARM system. The x86_64 artifact is for
that architecture, usually an emulator.

The reproduction workflow's coinstallable Debug build uses package
`org.aetherkiri.renpy.debug`, launcher label **Aether RenPy Test**, and a
disposable signing key. It keeps the production application's installation and
data separate. Earlier APKs use `org.github.krkr2.aetherkiri` and may conflict
with an installed application signed by another key. If Android rejects that
installation, stop and use the coinstallable build. Do not uninstall or clear
an existing application as an automatic workaround. A later test build can
also have a different Debug key; keep any test saves before choosing how to
replace it.

1. Download `renpy-installable-debug-arm64-v8a` from the successful workflow
   run, unzip it on the phone, and open `Aether-debug.apk`. Follow Android's
   installation prompt for the chosen download source.
2. Download `renpy-demo-project` from the same run and unzip its `game` folder
   inside a directory named `aetherkiri-renpy`, for example under Downloads.
   Keep `game/script.rpy`, `game/options.rpy`, and `game/scene.svg` together.
   No desktop Ren'Py SDK or device-request JSON is needed for this manual flow.
3. Open **Aether RenPy Test**, complete the existing first-run agreement and
   file-access prompts, and choose **Import**. Select the `aetherkiri-renpy`
   directory containing `game`, then open its detail page and start it.
4. The real demo should show its scene and dialogue. Advance the dialogue,
   tap **Start**, enter a name with the system keyboard, and confirm. Check
   that the dialogue contains the name. At the menu, press the phone's Home
   button, return to the app, and try **Enter text** again. **Pause / resume**
   also exercises a short in-game pause; it does not replace the Home check.
5. Choose **Quit** and confirm if prompted. Check that the normal application
   library returns and remains responsive. A new Ren'Py session requires a
   host-process restart: use Android's **Force stop** for this test application
   before reopening it. Clearing data or uninstalling is unnecessary.

Record the workflow run, APK filename, Android version, phone model, what
appeared on screen, input/lifecycle results, and any error. Do not report a
pass if it only reaches the library, shows a blank screen, or fails to accept
input. This manual check does not produce the independent automated evidence
below. Its Unicode/IME composition and prolonged background behavior need
separate coverage.

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

For the coinstallable reproduction APK, add
`--package org.aetherkiri.renpy.debug`; the default targets the normal product
package. Both commands run only on the authorized cloud device.

The device mode is enabled only by `game/aether-device-request.json`. Real
Ren'Py statements write a fresh run ID into `aether-device-checkpoints.jsonl`.
The harness requires actual OS touch down/up, Android text/Enter, a visible
system keyboard requested by native text-input state, Home/foreground lifecycle
pause/resume, another game touch after resume, and explicit `renpy.quit` followed
by observed native exit, engine teardown and removal of the actual Android
activity. The automated Android observer exits its host after this check;
the manual normal-app flow above also checks the library's responsiveness.
[Android may retain a cached process](https://developer.android.com/guide/components/activities/process-lifecycle);
its PID is recorded separately.
The regular interactive fixture
remains available when the request file is absent.

Evidence includes APK SHA-256, device build fingerprint, adb command results,
the Ren'Py script checkpoints, native provider RGBA PNGs, OS screenshots,
pixel-comparison reports, native pause/resume/exit state, the flushed per-game
engine log, and process logcat.
Screenshots must show the same nonblank pixels as the provider's real frame;
the script's actual idle/hover button and stage-marker colors must also appear.
Resume requires a new native frame serial after the pause, then a visible
WAIT-to-RESUMED marker change after the next actual system touch. Missing or
unreadable engine logs and recorded Ren'Py errors fail acceptance. Native
shutdown returns void, so these log checks do not infer a successful status.
Viewport fallback images, colorful system screens, startup-only checks, and
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
