# Ren'Py native desktop host experiment

This branch investigates importing ordinary Ren'Py game directories into Aether.
It uses the original engine, Python VM, archive loader, screens, rollback, save
format and renderer. It does not interpret RPY itself.

## Implemented milestone

- Detect `game/`, a directly imported game folder, and macOS `.app` data under
  `Contents/Resources/autorun/game`. Recognize loose RPY, RPC2 compiled scripts,
  and RPA-2/3 signatures without executing Python or unpickling archive indexes
  during library scanning. Read a literal `config.name` from `options.rpy`.
- Launch the supplied Ren'Py 8 SDK in its own process and native window from
  the normal visual-novel library. This prototype enables macOS and Linux;
  the real-engine integration test currently covers **macOS only**.
- Keep the engine's GPU renderer and event loop in the child process. There is
  no per-frame transfer of rendered pixels into Godot. The first implementation
  is a **separate native window**, not an embedded Godot viewport or a new
  runtime-dispatcher provider.
- Stage a writable copy of the game in an Aether session directory. APFS
  copy-on-write is used on macOS when available; other filesystems fall back
  to copying, which needs space for another copy of the game. Imported saves
  and caches are excluded. External file symlinks and directory symlinks are
  rejected. This protects ordinary engine writes to game data; it is not a
  sandbox for arbitrary Python supplied by a game.
- Place saves, persistent data, save-signing keys, backups and compiled-script
  caches under `user://renpy_saves/<game-identity>/`. Preserve generated RPYC
  statement identities across VM recreation so loose-source games can load
  previous saves without writing compiled files into the imported project.
- Use allowlisted JSON commands and atomic status files. Handle last-played
  and play-time accounting, graceful return to the library, and parent-process
  exit. The child has a bounded fallback if a game stops servicing its loop.
- Add an in-game control menu and optional virtual keys. Keys default to off
  for every new process. Debug builds additionally expose variable inspection
  and a renderer screenshot for the integration runner; there is no general
  Python-evaluation command.

The external SDK is **not bundled or automatically downloaded**. Launch a
development build with a complete SDK:

```sh
export AETHER_RENPY_SDK=/absolute/path/to/renpy-8.5.3-sdk
```

The host also looks for `renpy-runtime` next to the application executable,
`Contents/Resources/renpy-runtime` in a macOS bundle, or `user://RenPy/runtime`.
Those directories must contain the SDK's matching `renpy.py`, `renpy/`, Python
standard library and platform binary files, with the SDK's required notices.
The current build scripts do not stage a runtime into release artifacts.

The SDK used for validation is the official **8.5.3.26051504** release, with
Python 3.12. Its downloaded SDK ZIP SHA-256 is
`ff57648f9c04f27e381c48af6d8e3ee3cdec296bed4d3831f47f09b0a71b505e`,
verified against the [official checksums](https://www.renpy.org/dl/8.5.3/checksums.txt).
No upstream engine binaries, fonts or example-game assets are added to this
repository. The test scenario is original; its test font comes from the SDK
only in ignored local output.

## Validation

```sh
python3 -m unittest discover -s tests/python -p test_renpy_host.py
python3 tools/renpy_smoke.py --sdk /path/to/renpy-8.5.3-sdk
python3 tools/renpy_smoke.py --sdk /path/to/renpy-8.5.3-sdk --packed
```

The runner creates an isolated Godot project and user-data namespace. It checks
normal library launch, the native GPU renderer, Chinese text and choices,
optional keys, real saves and thumbnails, loading after full Python-process
recreation, both exit paths, play-time tracking, and byte-for-byte preservation
of the original game directory. The packed case compiles the original fixture
and runs it from an RPA-only data directory. Existing media-library regressions
also run. No third-party title, Linux device, or mobile app is claimed verified.

## Native embedding and mobile work still required

The inspected sources are [renpy/renpy](https://github.com/renpy/renpy) at
`80edccb125734ec9851b60b2f2b14d3f1f24eca6` and
[renpy/renpy-build](https://github.com/renpy/renpy-build) at
`612173094583e6fc2c5a92df438849757e0d3656`. These master snapshots are research
references, not the runtime paired with the 8.5.3 binaries.

`renpy-build/runtime/librenpython.c` initializes Python and calls `Py_RunMain`.
The mobile launchers similarly own application startup: Renios enters SDL's
application lifecycle, and RAPT uses a Python SDL Activity. The renderer owns
its SDL window and GL context. These are application entry points, rather than
a ready-made `create/tick/render/destroy` provider API.

Mobile integration therefore needs a separate in-process host: a cooperative
engine loop, an application-owned UIView/Android rendering surface, input and
lifecycle routing, SDL/dependency symbol isolation, and a repeatable game/VM
shutdown strategy. The desktop child-process path cannot supply iOS support.
Ren'Py 7/Python 2, native game plugins, and Windows hosting are outside this
milestone. Godot's translation, frame-enhancement and audio-bus controls also
do not automatically apply to the separate engine process.

The official [WebAssembly port](https://www.renpy.org/doc/html/web.html) is a
possible alternative host, but it changes the supported game environment:
threading/network APIs and some video behavior differ. It should be treated
as a separate compatibility target rather than assumed equivalent to desktop
game imports. `renpy-build` documents an Ubuntu build environment and at least
64 GB of disk; its system-wide setup is not part of this desktop experiment.
