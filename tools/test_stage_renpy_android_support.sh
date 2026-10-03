#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
stage="$repo_root/tools/stage_renpy_android_support.sh"
[[ -x "$stage" ]] || { echo "stager is not executable: $stage" >&2; exit 1; }
bash -n "$stage"

mobile_root="${RENPY_MOBILE_STAGE_TEST_ROOT:-/workspace/shared/renpy-mobile-staged}"
if [[ ! -f "$mobile_root/rapt/prototype/renpyandroid/src/main/jniLibs/arm64-v8a/librenpython.so" ]]; then
    echo "Ren'Py mobile stage not present; metadata-only staging test skipped"
    exit 0
fi

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/aetherkiri-renpy-android-stage.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT
mkdir -p "$tmp_root/android-build/src/main" "$tmp_root/private"
printf 'private fixture\n' > "$tmp_root/private/private.mp3"

"$stage" \
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
[[ -s "$main/java/org/github/krkr2/aetherkiri/RenPyMobileBridge.java" ]]
grep -Fx 'playable=false' "$main/assets/renpy_mobile/manifest.properties"
grep -Fx 'manifest_merged=false' "$main/assets/renpy_mobile/manifest.properties"
# The RAPT manifest is an asset only; no second Activity is added to the host
# source tree.
[[ ! -f "$main/AndroidManifest.xml" ]]
! find "$main/java" -path '*/org/renpy/android/PythonSDLActivity.java' -print -quit | grep -q .

echo "Ren'Py Android staging/package smoke ok"
