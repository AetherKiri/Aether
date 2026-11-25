# Aether ONS Preview

A macOS arm64 Flutter player for validating the Aether native host. The native
adapter sends the existing ONScripter RGBA frame to a Flutter texture and handles
session timing, input forwarding, and resource cleanup. The window shows the
game at its original aspect ratio.

With Flutter, Xcode, CMake, Ninja and vcpkg installed, run from the repository
root:

```sh
git submodule update --init packages/AetherONScripterYuri
apps/flutter_app/build_macos.sh
open 'apps/flutter_app/build/macos/Build/Products/Debug/Aether ONS Preview.app'
```

The helper accepts `FLUTTER_BIN` and `VCPKG_ROOT`. An existing macOS vcpkg
installation can be reused by setting `VCPKG_INSTALLED_DIR`.

Choose an ONS game directory using **Open Game**. The synthetic fixture in
`tests/fixtures/onscripter_smoke` can be copied to a temporary directory for a
quick startup check. For interaction and save verification, use a local game
copy. ONS script movie support requires the standalone media work tracked in
the native-host migration.

This is a separate development application with its own sandbox and bundle
identifier. The Godot application retains its existing launch path.
