#!/usr/bin/env bash
# Controlled JNI/provider test. The JNI declarations are genuine JDK/NDK
# headers; callback behavior and the launcher are fixtures, not device startup.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/aether-renpy-host.XXXXXX")"
trap 'rm -rf "$work"' EXIT
if [[ -n "${JNI_INCLUDE_DIR:-}" ]]; then
    jni_header="$JNI_INCLUDE_DIR/jni.h"
elif [[ -n "${ANDROID_NDK_HOME:-}" ]]; then
    jni_header="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/jni.h"
else
    echo 'Set JNI_INCLUDE_DIR (genuine JNI header directory) or ANDROID_NDK_HOME' >&2
    exit 1
fi
[[ -f "$jni_header" ]] || { echo "JNI header missing: $jni_header" >&2; exit 1; }
mkdir -p "$work/include/android"
cp "$jni_header" "$work/include/jni.h"
if [[ -f "$(dirname "$jni_header")/jni_md.h" ]]; then
    cp "$(dirname "$jni_header")/jni_md.h" "$work/include/"
elif [[ -f "$(dirname "$jni_header")/linux/jni_md.h" ]]; then
    cp "$(dirname "$jni_header")/linux/jni_md.h" "$work/include/"
fi
# Only the host-executable fixture needs these three unused native-window
# declarations. True Android compilation must separately use the NDK sysroot.
cat > "$work/include/android/native_window.h" <<'HEADER'
#pragma once
#include <stdint.h>
struct ANativeWindow;
extern "C" int32_t ANativeWindow_getWidth(ANativeWindow*);
extern "C" int32_t ANativeWindow_getHeight(ANativeWindow*);
extern "C" void ANativeWindow_release(ANativeWindow*);
HEADER
"${CXX:-c++}" -std=c++17 -Wall -Wextra -Werror -D__ANDROID__ \
    -I"$work/include" -I"$repo_root/bridge/renpy_runtime/include" \
    -I"$repo_root/bridge/renpy_runtime/mobile_launcher/include" -I"$repo_root/abi/include" \
    "$repo_root/bridge/renpy_runtime/tests/android_host_binding.cpp" \
    "$repo_root/bridge/renpy_runtime/src/renpy_mobile_adapter.cpp" \
    "$repo_root/bridge/renpy_runtime/src/renpy_runtime_mobile_provider.cpp" \
    -ldl -pthread -o "$work/host-test"
"$work/host-test"
printf '%s\n' 'RenPy Android JNI/provider binding and project detection protocol passed (not device startup)'
