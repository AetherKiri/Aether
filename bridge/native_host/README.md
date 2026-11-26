# Native runtime host

`aether_native_host` is a C++ library for frontend adapters. It owns one native
engine session handle at a time and registers ONScripterYuri when that provider
is built.

Create a `RuntimeSession` with an `engine_create_desc_t`, configure and open the
game through the existing engine API, then call `Close()` to release the handle
before starting another session. The handle returned by `handle()` is borrowed.
The caller serializes session operations on its host thread. This stage moves
session creation and teardown. The Godot adapter still drives ticks, input,
frame reads, audio, and platform services.

## Shared launch routing

`aether_launch_router` builds without a UI SDK. Call `ResolveLaunch` with
the game path, source, selected entry, startup script, host preference, and
release channel. Pass the capabilities of the running build. Standalone
frontends using `RuntimeSession` can call `RegisterProviders()` before
collecting registered IDs with `RegisteredLaunchProviders()`.

The result includes the detected and launch runtime IDs, target player,
game root, final entry, engine option, startup script, provider status and
host decision. Dedicated TyranoScript and Ren’Py entries are relative to the
returned root. The Flash entry is a full SWF path. The `deferred` Provider
status leaves engine-level `auto` dispatch to the ABI as before. A missing
explicit Provider blocks the launch. A missing native session selects the
same runtime’s existing host and records `native_session_unavailable`.

Godot supplies virtual filesystem access and passes its legacy detector as
an override when the user selects it. It handles file access authorization,
save sync, and actual player startup. The independent route tests run in
the game detection CTest suite. macOS and Linux Godot CI also launch ONS in
both hosts, open a manually selected XP3, and launch a synthetic System3 game
through the existing Godot host.

## macOS arm64 contract test

From the repository root, set `VCPKG_ROOT` to a vcpkg checkout and run:

```sh
git submodule update --init packages/AetherONScripterYuri
cmake -S . -B out/native-host -G Ninja \
  -DCMAKE_BUILD_TYPE=Debug -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DVCPKG_TARGET_TRIPLET=arm64-osx \
  -DAETHERKIRI_RUNTIMES_DEFAULT=OFF -DAETHERKIRI_ENABLE_ONSCRIPTER=ON \
  -DAETHERKIRI_ENABLE_INTERNAL=OFF -DBUILD_TOOLS=OFF \
  -DBUILD_GODOT_EXTENSION=OFF -DBUILD_NATIVE_HOST=ON
cmake --build out/native-host --target aether-native-host-onscripter
ctest --test-dir out/native-host -R '^Native host plays and reopens' \
  --output-on-failure --no-tests=error
```

This test exercises asynchronous startup, RGBA frame delivery, pause and resume,
keyboard input, and reopening within the same process. ONS script movies use
media services installed by the Godot adapter via the KiriKiri integration.
Script movie playback on the preview path still needs validation.

## ONScripter in Godot

The existing **Settings → Graphics & Rendering → Render Pipeline** selector
temporarily also selects the session host. The choices below all use the Godot
Native renderer and the same ONS provider and save locations. Changes apply
on the next game launch.

| Selection | Session host |
| --- | --- |
| **Automatic Host** | Prerelease builds use the native session preview for ONS when the implementation is available. Stable builds and games without a supported native host use the existing Godot session. |
| **Native Host (Preview)** | Explicitly opts into the ONS preview. Falls back to the existing Godot session if native support is unavailable. |
| **Godot Host** | Always uses the existing Godot session. |

Existing `Godot Native` settings select **Automatic Host**. Local probes can
force **Native Host (Preview)** with `Native Session` and **Godot Host** with
`Godot`. Launch logs report the session host separately from the renderer.
Regression probes report the host as `host.engine_host`. A future dedicated
**Execution Host** setting can leave Render Pipeline to renderer selection.

| Platform | Playback verification in this change |
| --- | --- |
| macOS arm64 | Local Godot playback and reopening with both hosts. CI also runs the ONS smoke fixture with both selections. |
| Linux x86_64 / arm64 | CI runs the headless ONS smoke fixture with both selections. |
| iOS / iPadOS | CI checks the native session implementation and builds the IPA. Playback on a physical device is pending. |
| Android | CI checks the native session implementation and packages the Godot extension in the APK. Playback on a physical device is pending. |
