#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
stage="$repo_root/tools/stage_renpy_android_support.sh"
[[ -f "$stage" ]] || { echo "stager is missing: $stage" >&2; exit 1; }
bash -n "$stage"

# This library is deliberately marked as a contract-only fixture. It checks
# ABI selection and staging ownership; it is never used as a gameplay proof.
abi_work="$(mktemp -d "${TMPDIR:-/tmp}/aetherkiri-renpy-abi-stage.XXXXXX")"
trap 'rm -rf "$abi_work"' EXIT
abi_main="$abi_work/mobile/rapt/prototype/renpyandroid/src/main"
mkdir -p "$abi_main/jniLibs/x86_64" "$abi_main/java/org/renpy/android" \
    "$abi_work/android-build/src/main/jniLibs/x86_64"
cat > "$abi_work/fixture.c" <<'C'
const char aether_contract_fixture[] = "AETHERKIRI_RENPY_LIFECYCLE_STUB";
int renpy_mobile_init(void) { return -3; }
C
"${CC:-cc}" -shared -fPIC "$abi_work/fixture.c" \
    -o "$abi_main/jniLibs/x86_64/librenpython.so"
cp "$abi_main/jniLibs/x86_64/librenpython.so" \
    "$abi_main/jniLibs/x86_64/liblegacy.so"
printf 'class PythonSDLActivity {}\n' \
    > "$abi_main/java/org/renpy/android/PythonSDLActivity.java"
printf 'unrelated host library\n' \
    > "$abi_work/android-build/src/main/jniLibs/x86_64/libhost.so"
bash "$stage" --allow-unsupported --abis x86_64 \
    --mobile-root "$abi_work/mobile" --godot-build "$abi_work/android-build" >/dev/null
abi_manifest="$abi_work/android-build/src/main/assets/renpy_mobile/manifest.properties"
grep -Fx 'native_abis=x86_64' "$abi_manifest"
grep -Fx 'native_library=lib/x86_64/librenpython.so' "$abi_manifest"
cmp "$abi_main/jniLibs/x86_64/librenpython.so" \
    "$abi_work/android-build/src/main/jniLibs/x86_64/librenpython.so"
[[ ! -e "$abi_work/android-build/src/main/jniLibs/arm64-v8a/librenpython.so" ]]

# A repeated staging run updates its own Java helpers and removes obsolete
# Ren'Py native dependencies while preserving files owned by the host.
rm "$abi_main/jniLibs/x86_64/liblegacy.so"
bash "$stage" --allow-unsupported --abis x86_64 \
    --mobile-root "$abi_work/mobile" --godot-build "$abi_work/android-build" >/dev/null
[[ ! -e "$abi_work/android-build/src/main/jniLibs/x86_64/liblegacy.so" ]]
grep -Fx 'unrelated host library' \
    "$abi_work/android-build/src/main/jniLibs/x86_64/libhost.so"
if bash "$stage" --allow-unsupported --abis mips \
        --mobile-root "$abi_work/mobile" --godot-build "$abi_work/android-build" \
        > "$abi_work/stdout" 2> "$abi_work/stderr"; then
    echo 'unsupported packaging ABI unexpectedly accepted' >&2
    exit 1
fi
grep -Fq 'Unsupported Ren' "$abi_work/stderr"
if bash "$stage" --allow-unsupported \
        --mobile-root "$abi_work/mobile" --godot-build "$abi_work/android-build" \
        > "$abi_work/stdout" 2> "$abi_work/stderr"; then
    echo 'default arm64 build silently used an x86_64 payload' >&2
    exit 1
fi
grep -Fq 'RAPT arm64-v8a native library is missing' "$abi_work/stderr"
rm -rf "$abi_work"
trap - EXIT
echo "Ren'Py Android x86_64 staging/ownership checks passed (contract fixture, no mobile app executed)"

mobile_root="${RENPY_MOBILE_STAGE_TEST_ROOT:-/workspace/shared/renpy-mobile-staged}"
if [[ ! -f "$mobile_root/rapt/prototype/renpyandroid/src/main/jniLibs/arm64-v8a/librenpython.so" ]]; then
    echo "Ren'Py mobile stage not present; metadata-only staging test skipped"
    exit 0
fi

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/aetherkiri-renpy-android-stage.XXXXXX")"
conflict_root="$(mktemp -d "${TMPDIR:-/tmp}/aetherkiri-renpy-android-conflict.XXXXXX")"
trap 'rm -rf "$tmp_root" "$conflict_root"' EXIT
mkdir -p "$tmp_root/android-build/src/main" "$tmp_root/private"
printf 'private fixture\n' > "$tmp_root/private/private.mp3"

bash "$stage" \
    --allow-unsupported \
    --mobile-root "$mobile_root" \
    --godot-build "$tmp_root/android-build" \
    --private-assets "$tmp_root/private" >/dev/null

main="$tmp_root/android-build/src/main"
[[ -s "$main/jniLibs/arm64-v8a/librenpython.so" ]]
[[ "$(dd if="$main/jniLibs/arm64-v8a/librenpython.so" bs=4 count=1 2>/dev/null | od -An -tx1 | tr -d ' \\n')" == "7f454c46" ]]
[[ -s "$main/assets/renpy_mobile/rapt/java/org/renpy/android/PythonSDLActivity.java" ]]
[[ -s "$main/assets/renpy_mobile/rapt/templates/app-AndroidManifest.xml" ]]
[[ -s "$main/assets/renpy_mobile/rapt/build.gradle" ]]
[[ -s "$main/assets/renpy_mobile/private/private.mp3" ]]
[[ -s "$main/assets/renpy_mobile/rapt/private.mp3" ]]
# Keep the loader preflight tied to the official payload's real ABI. GNU nm
# understands the staged arm64 ELF even when no Android runtime is available.
if command -v nm >/dev/null 2>&1; then
    for symbol in \
        SDL_main \
        JNI_OnLoad \
        SDL_AndroidGetJNIEnv \
        SDL_AndroidGetActivity \
        Java_org_libsdl_app_SDLActivity_nativeSetupJNI \
        Java_org_libsdl_app_SDLActivity_nativeRunMain \
        Java_org_libsdl_app_SDLActivity_onNativeSurfaceCreated \
        Java_org_libsdl_app_SDLActivity_onNativeSurfaceChanged \
        Java_org_libsdl_app_SDLActivity_onNativeSurfaceDestroyed \
        Java_org_libsdl_app_SDLActivity_nativeSetScreenResolution \
        Java_org_libsdl_app_SDLActivity_onNativeResize \
        Java_org_libsdl_app_SDLActivity_onNativeKeyDown \
        Java_org_libsdl_app_SDLActivity_onNativeKeyUp \
        Java_org_libsdl_app_SDLActivity_onNativeTouch \
        Java_org_libsdl_app_SDLActivity_nativePause \
        Java_org_libsdl_app_SDLActivity_nativeResume \
        Java_org_libsdl_app_SDLActivity_nativeQuit \
        Java_org_renpy_android_PythonSDLActivity_nativeSetEnv; do
        nm -D --defined-only "$main/jniLibs/arm64-v8a/librenpython.so" \
            | awk '{ print $3 }' | grep -Fx "$symbol" >/dev/null
    done
fi
grep -Fq 'Java_org_libsdl_app_SDLActivity_*' "$repo_root/cmake/engine_api_elf.map"
[[ -s "$main/java/org/github/krkr2/aetherkiri/RenPyMobileBridge.java" ]]
[[ -s "$main/java/org/libsdl/app/SDLActivity.java" ]]
[[ -s "$main/java/org/renpy/android/PythonSDLActivity.java" ]]
grep -Fq 'renpy-sdl-host-shim-v1' "$main/java/org/libsdl/app/SDLActivity.java"
grep -Fq 'renpy-python-host-shim-v1' "$main/java/org/renpy/android/PythonSDLActivity.java"
for callback in \
    nativeSetupJNI nativeRunMain nativeSetScreenResolution onNativeResize \
    onNativeKeyDown onNativeKeyUp onNativeTouch nativePause nativeResume \
    nativeQuit getNativeSurface getContext; do
    grep -Fq "$callback" "$main/java/org/libsdl/app/SDLActivity.java"
done
grep -Fq 'nativeSetEnv' "$main/java/org/renpy/android/PythonSDLActivity.java"
grep -Fx 'playable=unverified' "$main/assets/renpy_mobile/manifest.properties"
grep -Fx 'inspection_only=true' "$main/assets/renpy_mobile/manifest.properties"
grep -Fx 'native_lifecycle_validated=false' "$main/assets/renpy_mobile/manifest.properties"
grep -Fx 'manifest_merged=false' "$main/assets/renpy_mobile/manifest.properties"
grep -Fx 'java_host_shims=org/libsdl/app/SDLActivity.java,org/renpy/android/PythonSDLActivity.java' \
    "$main/assets/renpy_mobile/manifest.properties"
# The RAPT manifest is an asset only; no second Activity is added to the host
# source tree.
[[ ! -f "$main/AndroidManifest.xml" ]]
# The official PythonSDLActivity remains assets-only; the compiled source is
# the explicit host shim above.
grep -Fq 'AETHERKIRI_HOST_SHIM' "$main/java/org/renpy/android/PythonSDLActivity.java"
grep -Fq 'PythonSDLActivity' "$main/assets/renpy_mobile/rapt/java/org/renpy/android/PythonSDLActivity.java"

# A Godot template that already owns either SDL class must fail closed rather
# than silently replacing its singleton with the RAPT shim.
mkdir -p "$conflict_root/android-build/src/main/java/org/libsdl/app"
printf 'package org.libsdl.app; public final class SDLActivity {}\n' \
    > "$conflict_root/android-build/src/main/java/org/libsdl/app/SDLActivity.java"
if bash "$stage" --allow-unsupported --mobile-root "$mobile_root" \
        --godot-build "$conflict_root/android-build" \
        >"$conflict_root/stdout" 2>"$conflict_root/stderr"; then
    echo "stager overwrote an unrelated SDLActivity shim" >&2
    exit 1
fi
grep -Fq 'Refusing to overwrite unrelated Android Java class' "$conflict_root/stderr"

# The same official RAPT archive and dummy private.mp3 must be rejected by the
# real app staging path, rather than producing a silently unsupported build.
if bash "$stage" --mobile-root "$mobile_root" \
        --godot-build "$tmp_root/android-build" --private-assets "$tmp_root/private" \
        >"$tmp_root/strict-stdout" 2>"$tmp_root/strict-stderr"; then
    echo "enabled app stager accepted an official blocking archive and incomplete Python payload" >&2
    exit 1
fi
grep -Fq "Ren'Py mobile packaging input rejected" "$tmp_root/strict-stderr"

echo "Ren'Py Android archive staging and unsupported-runtime rejection ok (gameplay untested)"
