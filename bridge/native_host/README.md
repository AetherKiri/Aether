# Native runtime host

`aether_native_host` is a C++ library for frontend adapters. It owns one native
host session at a time and registers ONScripterYuri when that provider is built.

Create a `RuntimeSession` with an `engine_create_desc_t`, configure and open the
game through the existing engine API, then call `Close()` to release the handle
before starting another session. The handle returned by `handle()` is borrowed.
The caller serializes session operations on its host thread. Frame presentation
is implemented by the frontend adapter.

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
keyboard input, and reopening within the same process. ONS script movies still
require the media services currently installed by the Godot host via the
KiriKiri integration. Movie playback needs its own native-host validation
before the new host is enabled for normal ONS playback.

## ONScripter in the macOS Godot app

The arm64 macOS Godot build opens ONS sessions through `RuntimeSession` by
default when ONS is built. Godot continues to drive the session through
`engine_*`, present frames, and provide its platform services. Both session
paths use the same ONS provider and game save locations.

In **Settings → Compatibility**, **Use Legacy ONS Host** switches ONS games to
the original session path on the next launch. For local regression runs, set
`AETHERKIRI_ONS_LEGACY_HOST=1` to force the legacy path or `0` to force the
native path. Renderer diagnostics report `session_host=native` or
`session_host=legacy`. Regression probes expose the same value as
`host.engine_host`.
