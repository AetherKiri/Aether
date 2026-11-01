# Selecting runtimes at build time

The default build keeps the existing full runtime selection. Use a fresh build
directory and set `AETHERKIRI_RUNTIMES_DEFAULT=OFF` to select individual runtimes:

```sh
cmake -S . -B out/qlie -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DAETHERKIRI_RUNTIMES_DEFAULT=OFF \
  -DAETHERKIRI_ENABLE_QLIE=ON \
  -DENABLE_TESTS=OFF -DBUILD_TOOLS=OFF
cmake --build out/qlie --target aether_kiri_godot
```

QLIE requires the private `packages/AetherInternal` package. Configuration fails
if QLIE is selected and its package integration is unavailable. The provider is
registered when the Godot extension initializes.

The individual options use the `AETHERKIRI_ENABLE_` prefix with these suffixes:
`KRKR2`, `ARTEMIS_RUNTIME`, `CATSYSTEM2`, `WA2`, `QLIE`, `ONSCRIPTER`, `SYSTEM3`,
`XSYSTEM35`, `XSYSTEM4`, `SIGLUS`, `MAGES`, `MINORI`, `ENTISGLS`, `BGI`, `YURIS`,
`ADVHD`, `FLASH`, `TYRANO`, and `RENPY`. `RFVP` and `SOFTPAL_RUNTIME` remain
experimental options that default to off. Artemis, CatSystem2, and WA2 currently
require `KRKR2=ON`; configuration checks this dependency.

Explicit options already stored in a CMake cache take precedence over the default.
Use a new build directory or set every existing runtime option explicitly when
changing profiles. The configuration summary prints the enabled runtimes.

To reuse an existing compatible vcpkg installation, supply its toolchain/triplet
and installed directory, and disable manifest installation:

```sh
  -DVCPKG_TARGET_TRIPLET=x64-windows-static-md \
  -DVCPKG_INSTALLED_DIR=<existing-build>/vcpkg_installed \
  -DVCPKG_MANIFEST_INSTALL=OFF
```

Windows builds require an initialized MSVC developer environment. Godot app
export is a separate step after building the extension and `engine_api` DLLs.
The frontend skips KiriKiri diagnostics and the built-in KAG demo when that
runtime is disabled.
