# TyranoScript browser-project host (prototype)

TyranoScript projects are HTML/JavaScript applications. Aether runs the game's
own engine in a system WKWebView (Apple) or Android WebView rather than
interpreting KS tags again or passing HTML to the KiriKiri provider. Upstream TyranoScript source and example
assets are not bundled with Aether. This module contains only Aether's host
adapter. See [upstream](https://github.com/ShikemokuMK/tyranoscript) for the engine
and its distribution terms.

## Current support

The prototype is enabled on **macOS, iOS/iPadOS, and Android**. Linux, Windows,
and Web builds recognize the project and report that this prototype is unavailable.
The UIKit host has iPhone and iPad Simulator integration tests. Android has SDK/NDK
compilation and resource/staging tests; physical mobile devices and arbitrary
third-party games still need validation.

Import the game directory into the visual-novel library. Detection requires
`index.html`, `tyrano/tyrano.js`, `tyrano/plugins/kag/kag.js`, and
`data/system/Config.tjs`. An unpacked Electron project's `resources/app/` or
`app/` directory is also detected. The game title comes from `System.title`.
An ordinary HTML page is not claimed as a TyranoScript game.

Packed Electron exports with `resources/app.asar` or `app.asar` are recognized by the same engine files inside the archive. On launch, Aether streams the archive and any declared `app.asar.unpacked` resources into its own cache on a worker thread, leaving the original game unchanged. The cache is reused when the archive and external resource contents match; incomplete caches are rebuilt. Returning to the library cancels preparation. Unsafe paths, archive links, invalid offsets, missing external resources, and archives exceeding the index or extraction limits are rejected. Saves retain the original game identity across cache rebuilds.

On iOS, put the complete project in `Games/<game>/` in Aether's Documents folder;
the normal visual-novel library scan discovers it. Android uses the existing
folder importer and storage-permission flow. Build Android through
`./build.sh android debug` (or `release`): the build script stages Aether's Java
host, JavaScript asset, and reflection keep rules into the generated Godot Gradle
template. The asset uses a separate Gradle source directory so Godot's normal
APK/AAB asset cleanup cannot remove it. A plain editor export without staging
the host cannot run TyranoScript.

The host supports browser-compatible projects, their DOM/CSS rendering, direct
mouse/keyboard input, on-screen keys, standard browser media, and Tyrano's own
menus and save/load logic. The toolbar returns to the library, recreates the
player, or toggles virtual keys, which start disabled on all platforms. The system
browser owns the game surface; Godot owns the surrounding library and toolbar.

Encrypted resources, Node/Electron/NW.js APIs, native plugins,
external page navigation, and games that require desktop file-based saves are
not supported by this prototype. Import a browser-compatible export. Godot's
frame-enhancement, runtime-translation, audio-bus and screenshot APIs do not
automatically apply to the native WebView.

## Resources, persistence and lifecycle

Apple's `aether-tyrano://game/` and Android's per-game synthetic HTTPS origin
resolve files only within the imported project. Resolved
symlinks cannot escape that root. The resource handler provides MIME types,
HEAD requests, and byte ranges for browser media; it does not run a local HTTP
server or expose the project over the network. Android disables file/content
URL access and intercepts HTTPS resource reads. Its HTML response inserts the
host before game scripts without modifying the original `index.html` on disk.
Remote resources are unavailable in the Android prototype.

Each game has a separate Storage adapter under
`user://tyrano_saves/<game-identity>/local_storage.json`. Original game files
are not changed. Storage writes cross a private native prompt boundary
(WKUIDelegate or WebChromeClient) without showing UI, finish atomically before JavaScript returns, and propagate
failures as exceptions. Document creation reads the latest snapshot, including
when the game calls `location.reload()`. Corrupt existing storage is preserved
and reported. `sessionStorage` is per document; browser cookies and IndexedDB
use an ephemeral WebKit data store on Apple. Android disables DOM storage and
uses a separate origin per game. Cookies and IndexedDB are outside the save adapter.

The normal TyranoScript browser save format is supported. Existing Windows
file-based saves are not converted. Desktop save configuration is switched to browser storage before the engine's first system-variable read. Application focus loss pauses host-managed
JS timers, animation frames, CSS animations, HTML media and tracked Web Audio
contexts, and releases virtual keys. Native application lifecycle callbacks also
apply while Godot is suspended. Browser work stays on the OS UI thread; normalized
viewport rectangles account for the Godot surface and its safe area. Closing
removes the native view, listeners, lifecycle observers and message handlers.

Tyrano's legacy mobile adapter binds `tap` while keyboard actions emit `click`.
The host translates clicks on legacy tap targets during virtual-key dispatch
only. Normal game taps retain their original handling. The virtual-key overlay
also stops touch/mouse gestures from reaching the game's document listeners.

## Validation

Build the normal macOS Debug app. No additional SDK or downloaded browser is
required. The isolated test runner takes a separate upstream checkout:

```sh
python3 tools/tyrano_smoke.py --engine-root /path/to/tyranoscript
```

Add `--asar` to run the same player checks through a generated Electron archive, including cancellation during preparation and reopening the cached project.

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

Mobile host checks:

```sh
# SDK compilation, real Java resource handler and Gradle staging (also in CI).
ANDROID_HOME=/path/to/android-sdk python3 tools/test_tyrano_android.py

# Run the UIKit host against the prepared original fixture on a booted simulator.
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  python3 tools/tyrano_ios_smoke.py --game /path/to/prepared/game --device <simulator-udid>
```

The iOS runner creates a disposable app with its own user data and uninstalls it
after testing Chinese text/choices, virtual Enter, tap isolation, UIKit touch
targeting, save thumbnails, reload/recreation, background/resume, byte ranges,
resource-root isolation and viewport sizing. This validates the UIKit host, not
a complete Godot iOS export or a physical device. Upstream test assets remain
only in ignored local test output and are never included in the Aether product.
