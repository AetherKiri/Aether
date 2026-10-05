# SoftPal engine-only build

`SOFTPAL_ENGINE_ONLY=ON` builds the existing `engine_api` ABI with the native
SoftPal provider in the DLL. It skips KiriKiri, Onscripter, Siglus, Minori,
RFVP, AetherInternal, tools, tests and the Godot extension. Only
`packages/AetherSoftPal` needs to be initialized. Normal product presets
retain their existing behavior.

The mode reuses `abi/CMakeLists.txt` and the SoftPal package hook instead of
maintaining a second interpreter or ABI. Provider registration happens on
first use, so clients can enumerate/probe SoftPal and use the standard
`engine_create`, `engine_open_game`, `engine_tick` and frame APIs directly.
The legacy KiriKiri metadata entry remains enumerable under the existing
registry contract; its engine cannot run without the KiriKiri host.

## Dependencies and build

Use an existing vcpkg checkout, or provide system packages via
`CMAKE_PREFIX_PATH`. This mode disables vcpkg manifest installation before
`project()` and does not read the root product dependency list. With vcpkg,
explicitly install only the following packages and their required transitive
dependencies. FreeType and SDL2_mixer default features are disabled; the
provider uses Ogg/Vorbis and WAV audio. No FFmpeg, OpenCV, llama-cpp or Rust
runtime is requested.

From the repository root in a VS 2022 x64 developer PowerShell:

```powershell
# Set this to your existing vcpkg checkout; no bootstrap is needed.
$env:VCPKG_ROOT = "D:\imopara1\vcpkg-sdk"
$repo = (Get-Location).Path
$installed = "$repo\out\windows\softpal-engine\vcpkg_installed"
git submodule update --init packages/AetherSoftPal
& "$env:VCPKG_ROOT\vcpkg.exe" install --classic `
  boost-locale zlib 'bzip2[core]' libpng 'freetype[core]' `
  'sdl2[core]' 'sdl2-mixer[core]' spdlog `
  --triplet x64-windows-static-md --x-install-root=$installed
cmake --preset "Windows SoftPal Engine Config" `
  "-DCMAKE_TOOLCHAIN_FILE=$env:VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake" `
  "-DVCPKG_INSTALLED_DIR=$installed"
cmake --build --preset "Windows SoftPal Engine Build" --parallel 8
```

The output is `out/windows/softpal-engine/abi/engine_api.dll`. It exports
the standard engine ABI plus `engine_softpal_*`; private implementation
sources stay in the SoftPal package. Provider ticks use significant stack
space; smoke tests were run on a host thread with an 8 MiB stack. Start with a
fresh build directory when switching toolchains or between this mode and the
normal product build. Features requiring other engines or AetherInternal
remain unavailable.
