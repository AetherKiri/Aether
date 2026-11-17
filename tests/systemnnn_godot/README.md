# Production SystemNNN graphical test

This Linux x86-64 test loads the real production GDExtension into graphical Godot, generates its own small story, and verifies texture readback, visible glyphs, input, and PC save/load. It does not substitute a mock provider or use commercial assets. The Python generator writes the SPT word/table format used by the independently authored [native provider fixture](../systemnnn_native/provider.cpp); generated scripts and runtime data stay outside this source directory.

Prerequisites:

- Build the real `aether_kiri_godot` target with `KRKR2;SYSTEMNNN` selected. See [production build validation](../../doc/systemnnn_production_validation.md) for the tested toolchain and minimal selection.
- Stage the extension, `libengine_api.so`, and its non-system shared dependencies in a local bundle with `$ORIGIN` RUNPATH. Confirm `env -u LD_LIBRARY_PATH ldd -r /absolute/bundle/libaether_kiri_godot.so` reports no missing libraries or undefined symbols. This harness consumes the existing library and does not build, patch, copy, or redistribute it.
- Godot matching the extension API: the verified combination is godot-cpp 10.0.0/API 4.7 and official Godot 4.7.2. Python 3.9+, Xvfb/xauth, and an OpenGL driver are required. Do not use `--headless`; this test requires X11 and actual Godot textures. Mesa software GL is sufficient.
- Install a usable font available to SystemNNN, or supply `SYSTEMNNN_FONT` with an absolute font file path. The generated fixture includes no font binary.

Run from the checkout root, substituting your own absolute paths. Choose a new output directory on each run; preparation refuses to overwrite an existing directory.

```sh
python3 tests/systemnnn_godot/prepare.py \
  --output /absolute/new-systemnnn-test \
  --library /absolute/bundle/libaether_kiri_godot.so

timeout 90s xvfb-run -a env -u LD_LIBRARY_PATH \
  GODOT_SILENCE_ROOT_WARNING=1 LIBGL_ALWAYS_SOFTWARE=1 \
  /absolute/Godot_v4.7.2-stable_linux.x86_64 \
  --path /absolute/new-systemnnn-test \
  --rendering-method gl_compatibility --audio-driver Dummy \
  --script res://runtime_exercise.gd
```

The generated project contains a descriptor pointing at the supplied production library and an independently authored fixture at `fixture/日本語 Game`. Mixed-case `SpT/SyS.SpT` exercises case-insensitive resource resolution. It shows “First independent line.” and “Second independent line.” on RGB (180,30,60), offers Amber/Azure choices, and shows “Selected route.” on RGB (10,80,220) for choice 2. It waits for progressive text completion, saves PC slot 13, advances dialogue, restores its continuation, selects choice 2, and reads back textures. Bright pixels in the authored text region must exceed 100; this prevents solid-color frames or toolbar text from satisfying visible-dialogue validation.

Success requires process exit 0 and `SYSTEMNNN_GRAPHICAL_PRODUCTION_EXERCISE_OK`. Artifacts are `artifacts/production-story-finished.png` and `artifacts/production-choice-finished.png` under the generated project; saves go under `writable/systemnnn`. The check sends keyboard events through the registered production player API; it does not claim OS mouse event coverage or a full Godot application screen capture. PNGs are Godot texture readbacks.

The harness supports these optional environment overrides (absolute paths or Godot `res://` paths):

| Variable | Default | Purpose |
| --- | --- | --- |
| `SYSTEMNNN_EXTENSION` | `res://production.gdextension` | Descriptor to load |
| `SYSTEMNNN_FIXTURE` | `res://fixture/日本語 Game` | Authored fixture directory |
| `SYSTEMNNN_WRITABLE` | `res://writable` | Cache and save directory |
| `SYSTEMNNN_OUTPUT` | `res://artifacts` | PNG output directory |
| `SYSTEMNNN_FONT` | Provider default | Optional installed font file |

Use a fresh writable directory to isolate previous saves and settings. The generated descriptor uses an absolute library path so companion dependencies retain their own staging layout. Paths outside this generated project are caller-controlled; preparation does not copy any opaque fixture or search for game data.

The validation host has no physical audio device. Godot's Dummy driver and SystemNNN's graceful unavailable-device behavior permit graphical validation, but do not verify audible playback. The bundle still uses installed distro libraries; passing this test does not establish a self-contained distribution. Keep builds local until the [redistribution license gate](../../doc/systemnnn_redistribution.md) is resolved. No public binary upload is part of this test.
