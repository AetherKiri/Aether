#!/usr/bin/env bash
# Validate the real native lifecycle fork source and the Ren'Py demo gate.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
native="$repo_root/bridge/renpy_runtime/mobile_launcher/patches/native/renpy_mobile_lifecycle.c"
[[ -s "$native" ]] || { echo "missing native lifecycle fork: $native" >&2; exit 1; }
for symbol in \
    renpy_mobile_init renpy_mobile_tick renpy_mobile_frame renpy_mobile_input \
    renpy_mobile_pause renpy_mobile_resume renpy_mobile_shutdown; do
    grep -Fq "$symbol" "$native" || { echo "native fork missing $symbol" >&2; exit 1; }
done
for forbidden in \
    'SDL_main(' 'launcher_main(' 'Py_RunMain(' 'SDL_RunApp(' \
    'SDL_UIKitRunApp(' 'UIApplicationMain(' 'System.exit(' 'exit('; do
    if grep -Fq "$forbidden" "$native"; then
        echo "native lifecycle fork contains forbidden process entrypoint: $forbidden" >&2
        exit 1
    fi
done
for patch in \
    "$repo_root/bridge/renpy_runtime/mobile_launcher/patches/native/0001-renpy-build-link.patch" \
    "$repo_root/bridge/renpy_runtime/mobile_launcher/patches/native/0002-android-host-bootstrap.patch" \
    "$repo_root/bridge/renpy_runtime/mobile_launcher/patches/native/0003-ios-host-bootstrap.patch"; do
    [[ -s "$patch" ]] || { echo "missing native build patch: $patch" >&2; exit 1; }
    if [[ "$patch" != *0001-renpy-build-link.patch ]]; then
        grep -Fq 'renpy_mobile_bootstrap' "$patch" || {
            echo "native build patch does not expose renpy_mobile_bootstrap: $patch" >&2
            exit 1
        }
    fi
done

if [[ -n "${RENPY_BUILD_TEST_ROOT:-}" && -d "${RENPY_BUILD_TEST_ROOT}/.git" ]]; then
    for patch in \
        "$repo_root/bridge/renpy_runtime/mobile_launcher/patches/native/0001-renpy-build-link.patch" \
        "$repo_root/bridge/renpy_runtime/mobile_launcher/patches/native/0002-android-host-bootstrap.patch" \
        "$repo_root/bridge/renpy_runtime/mobile_launcher/patches/native/0003-ios-host-bootstrap.patch"; do
        git -C "$RENPY_BUILD_TEST_ROOT" apply --check "$patch"
    done
fi
bash "$repo_root/tools/test_renpy_demo_fixture.sh"
printf '%s\n' 'RenPy native lifecycle fork and demo gate passed'
