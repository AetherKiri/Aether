#!/usr/bin/env bash
set -euo pipefail

app_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$app_dir/../.." && pwd)"
flutter_bin="${FLUTTER_BIN:-flutter}"
build_dir="$root/out/flutter-native/macos/debug"
stage_dir="$app_dir/build/aether_native"

export VCPKG_ROOT="${VCPKG_ROOT:-$root/.devtools/vcpkg}"
cmake_args=()
if [[ -n "${VCPKG_INSTALLED_DIR:-}" ]]; then
    cmake_args+=("-DVCPKG_INSTALLED_DIR=$VCPKG_INSTALLED_DIR" -DVCPKG_MANIFEST_INSTALL=OFF)
fi

cmake -S "$root" -B "$build_dir" -G Ninja \
    -DCMAKE_BUILD_TYPE=Debug -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
    -DVCPKG_TARGET_TRIPLET=arm64-osx -DENABLE_TESTS=OFF -DBUILD_TOOLS=OFF \
    -DAETHERKIRI_RUNTIMES_DEFAULT=OFF -DAETHERKIRI_ENABLE_ONSCRIPTER=ON \
    "-DAETHERKIRI_ONSCRIPTERYURI_DIR=${AETHERKIRI_ONSCRIPTERYURI_DIR:-$root/packages/AetherONScripterYuri}" \
    -DAETHERKIRI_ENABLE_INTERNAL=OFF -DBUILD_GODOT_EXTENSION=OFF \
    -DBUILD_NATIVE_HOST=ON -DBUILD_NATIVE_HOST_SHARED=ON \
    ${cmake_args[@]+"${cmake_args[@]}"}
cmake --build "$build_dir" --target aether_native_host --parallel "${JOBS:-4}"

mkdir -p "$stage_dir"
cp "$build_dir/bridge/native_host/libaether_native_host.dylib" "$stage_dir/"
cp "$build_dir/abi/libengine_api.dylib" "$stage_dir/"

cd "$app_dir"
"$flutter_bin" build macos --debug "$@"
