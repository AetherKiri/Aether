# SystemNNN mobile compile and link gate

This standalone project compiles the production ABI, SystemNNN adapter, and Emberfall scene/core closure without the root product manifest or Godot. The final target links every adapter object using CMake's WHOLE_ARCHIVE feature. Android produces a shared library with undefined symbols rejected; iOS produces an unsigned arm64 executable. These are link probes, not an APK, IPA, GDExtension, or device acceptance result.

The focused manifest pins the same builtin baseline as the product and enables the adapter's FFmpeg avcodec/avformat/avutil/swresample/swscale dependencies. It does not duplicate all product FFmpeg features or establish game codec support. The mobile triplets include the product triplets; Android selects shared libc++ for a single runtime across both DSOs. Build-tree and package outputs stay under the selected binary directory.

## Android arm64 on Linux

Install Android NDK 28.1.13356709 (r28b), CMake >=3.28, Ninja, pkg-config, autoconf, automake, libtool, and nasm. Use a separate vcpkg checkout at the manifest builtin baseline, bootstrap it, and set ANDROID_NDK_HOME to the NDK root. From the repository root:

```sh
cmake -S tests/systemnnn_mobile -B build/systemnnn-mobile-android -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_TOOLCHAIN_FILE="$VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake" \
  -DVCPKG_TARGET_TRIPLET=arm64-android \
  -DVCPKG_OVERLAY_TRIPLETS="$PWD/tests/systemnnn_mobile/triplets" \
  -DVCPKG_INSTALLED_DIR="$PWD/build/systemnnn-mobile-android/vcpkg_installed" \
  -DCMAKE_SYSTEM_NAME=Android \
  -DVCPKG_CHAINLOAD_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-24 -DANDROID_STL=c++_shared
cmake --build build/systemnnn-mobile-android --parallel 2
cmake --install build/systemnnn-mobile-android --prefix build/systemnnn-mobile-android/package
```

The package contains the linked probe DSO, ABI DSO, adapter archive, shared libc++, and SystemNNN notices. It is a developer validation package, not a redistributable complete SDK or application. Inspect both DSOs with NDK llvm-readelf to confirm AArch64, DT_NEEDED, exported registration/probe symbols, and LOAD alignment. Never execute Android binaries directly on the Linux host.

## iOS arm64 on macOS

Use an Xcode iPhoneOS SDK and the same pinned vcpkg checkout:

```sh
cmake -S tests/systemnnn_mobile -B build/systemnnn-mobile-ios -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_TOOLCHAIN_FILE="$VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake" \
  -DVCPKG_TARGET_TRIPLET=arm64-ios \
  -DVCPKG_OVERLAY_TRIPLETS="$PWD/tests/systemnnn_mobile/triplets" \
  -DVCPKG_INSTALLED_DIR="$PWD/build/systemnnn-mobile-ios/vcpkg_installed" \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO
cmake --build build/systemnnn-mobile-ios --parallel 3
cmake --install build/systemnnn-mobile-ios --prefix build/systemnnn-mobile-ios/package
```

Inspect the executable with file, lipo, otool, and nm. No signing secrets are required. The existing product iOS workflow remains responsible for Godot static archive merging, export, signing, and IPA packaging; this focused link gate does not replace that acceptance work. No simulator or device run is implied.

The separate SystemNNN mobile link workflow runs both configurations, verifies the root/manifest baseline relationship, and retains compile commands, CMake cache, vcpkg status, and textual binary inspection output for review. Combined native binaries remain in the runner workspace and are excluded from artifact uploads while license compatibility is unresolved.
