# TyranoScript browser-project host (prototype)

TyranoScript projects are HTML/JavaScript applications. Aether runs the game's
own engine in a system WKWebView rather than interpreting KS tags again or
passing HTML to the KiriKiri provider. Upstream TyranoScript source and example
assets are not bundled with Aether. This module contains only Aether's host
adapter. See [upstream](https://github.com/ShikemokuMK/tyranoscript) for the engine
and its distribution terms.

## Current support

The playable prototype is enabled on **macOS**. The UIKit bridge and export
framework dependency compile against the iOS SDK, but mobile hosting remains
disabled pending device validation. Android, Linux, Windows, and Web builds
recognize the project and report that this prototype is unavailable.

Import the game directory into the visual-novel library. Detection requires
`index.html`, `tyrano/tyrano.js`, `tyrano/plugins/kag/kag.js`, and
`data/system/Config.tjs`. An unpacked Electron project's `resources/app/` or
`app/` directory is also detected. The game title comes from `System.title`.
An ordinary HTML page is not claimed as a TyranoScript game.

The host supports browser-compatible projects, their DOM/CSS rendering, direct
mouse/keyboard input, on-screen keys, standard browser media, and Tyrano's own
menus and save/load logic. The toolbar returns to the library, recreates the
player, or toggles virtual keys. WebKit owns the game surface; Godot owns the
surrounding library and toolbar.

Packed `app.asar`, encrypted resources, Node/Electron/NW.js APIs, native plugins,
external page navigation, and games that require desktop file-based saves are
not supported by this prototype. Import an unpacked browser export. Godot's
frame-enhancement, runtime-translation, audio-bus and screenshot APIs do not
automatically apply to the native WebView.

## Resources, persistence and lifecycle

`aether-tyrano://game/` resolves files only within the imported project. Resolved
symlinks cannot escape that root. The resource handler provides MIME types,
HEAD requests, and byte ranges for browser media; it does not run a local HTTP
server or expose the project over the network.

Each game has a separate Storage adapter under
`user://tyrano_saves/<game-identity>/local_storage.json`. Original game files
are not changed. Storage writes cross a private WKUIDelegate prompt boundary
without showing UI, finish atomically before JavaScript returns, and propagate
failures as exceptions. Document creation reads the latest snapshot, including
when the game calls `location.reload()`. Corrupt existing storage is preserved
and reported. `sessionStorage` is per document; browser cookies and IndexedDB
use an ephemeral WebKit data store and are not persisted by this adapter.

The normal TyranoScript browser save format is supported. Existing Windows
file-based saves are not converted. Application focus loss pauses host-managed
JS timers, animation frames, CSS animations and WebKit media playback, and
releases virtual keys. Closing removes the native view and message handlers.

## Validation

Build the normal macOS Debug app. No additional SDK or downloaded browser is
required. The isolated test runner takes a separate upstream checkout:

```sh
python3 tools/tyrano_smoke.py --engine-root /path/to/tyranoscript
```

The runner copies the external engine only into ignored local test output,
installs Aether's original Chinese scenario, and creates a Godot project with
separate user data. It verifies metadata, normal library launch routing,
Chinese text and choices, virtual Enter and pointer advancement, browser save
thumbnails, persistent save/load across page reload and player recreation,
pause/resume, resource-root isolation, byte ranges, resizing, return to the
library, and play-time accounting. It also runs the existing video and Flash
library regressions. This is a fixture-based integration check, not a claim
that arbitrary third-party titles or mobile devices have been verified.

Use `--prepare-only` to keep a prepared project for interactive inspection.
`AETHERKIRI_TYRANO_SMOKE_HOLD=90` keeps the test window visible before teardown.
Debug builds expose `AetherTyranoPlayer.evaluate_script()` for the test runner;
it is not bound in Release builds.
