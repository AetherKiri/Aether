#!/usr/bin/env bash
# Optional Ren'Py native mobile source build orchestration.
#
# The official renpy-build checkout and iOS SDK archives are external/licensed
# inputs. Default "auto" mode is therefore a clear skip when no checkout is
# supplied; it never turns staged RAPT/Renios archives into playable payloads.
# Use --mode check for strict CI preflight or --mode build after provisioning
# Ubuntu 24.04, Android NDK, and the licensed iOS SDK archives.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
launcher="$repo_root/bridge/renpy_runtime/mobile_launcher/build.sh"
mode="${AETHERKIRI_RENPY_SOURCE_BUILD_MODE:-auto}"
renpy_build="${AETHERKIRI_RENPY_BUILD_ROOT:-}"
fetch=false
source_url="${AETHERKIRI_RENPY_BUILD_URL:-https://github.com/renpy/renpy-build.git}"
source_ref="${AETHERKIRI_RENPY_BUILD_REF:-}"

usage() {
    cat <<'USAGE'
Usage: tools/run_renpy_mobile_source_build.sh [options]

Options:
  --mode MODE          auto (default), skip, check, or build
  --renpy-build PATH   existing official renpy-build checkout
  --fetch              clone the official checkout when PATH is absent
  --url URL            source URL used with --fetch
  --ref REF            branch/tag/commit used with --fetch
  -h, --help           show this help

Environment:
  AETHERKIRI_RENPY_SOURCE_BUILD_MODE
  AETHERKIRI_RENPY_BUILD_ROOT
  AETHERKIRI_RENPY_BUILD_URL
  AETHERKIRI_RENPY_BUILD_REF
  AETHERKIRI_RENPY_SOURCE_BUILD_REQUIRED=1
  AETHERKIRI_RENPY_BUILD_IOS=1  # build iOS after Android in --mode build

The build mode runs renpy-build's Android lifecycle-fork hooks and, when
explicitly enabled, its iOS hooks. It validates canonical outputs and the
seven host lifecycle exports before any staged install. It does not claim
device/simulator playability.
USAGE
}

while (($#)); do
    case "$1" in
        --mode)
            (($# >= 2)) || { echo "--mode requires a value" >&2; exit 2; }
            mode="$2"; shift 2 ;;
        --renpy-build)
            (($# >= 2)) || { echo "--renpy-build requires a path" >&2; exit 2; }
            renpy_build="$2"; shift 2 ;;
        --fetch) fetch=true; shift ;;
        --url)
            (($# >= 2)) || { echo "--url requires a value" >&2; exit 2; }
            source_url="$2"; shift 2 ;;
        --ref)
            (($# >= 2)) || { echo "--ref requires a value" >&2; exit 2; }
            source_ref="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

case "$mode" in
    auto|skip|check|build) ;;
    *) echo "--mode must be auto, skip, check, or build (got '$mode')" >&2; exit 2 ;;
esac
[[ -x "$launcher" ]] || { echo "missing launcher scaffold: $launcher" >&2; exit 1; }

if [[ "$mode" == "skip" ]]; then
    echo "Ren'Py mobile source build skipped by request (no payload built)"
    exit 0
fi

if [[ -z "$renpy_build" ]]; then
    renpy_build="$repo_root/.aetherkiri-cache/renpy-build"
fi

if [[ ! -d "$renpy_build" && "$fetch" == true ]]; then
    command -v git >/dev/null 2>&1 || { echo "git is required for --fetch" >&2; exit 1; }
    mkdir -p "$(dirname "$renpy_build")"
    clone_args=(clone --filter=blob:none)
    [[ -n "$source_ref" ]] && clone_args+=(--branch "$source_ref")
    clone_args+=("$source_url" "$renpy_build")
    echo "Fetching official renpy-build source: $source_url"
    git "${clone_args[@]}"
fi

if [[ ! -d "$renpy_build" ]]; then
    if [[ "$mode" == "auto" && "${AETHERKIRI_RENPY_SOURCE_BUILD_REQUIRED:-0}" != "1" ]]; then
        echo "Ren'Py mobile source build skipped: official renpy-build checkout is absent"
        echo "  provide --renpy-build PATH or set AETHERKIRI_RENPY_SOURCE_BUILD_REQUIRED=1"
        exit 0
    fi
    echo "Ren'Py mobile source build requires an official renpy-build checkout: $renpy_build" >&2
    echo "  clone: git clone $source_url $renpy_build" >&2
    exit 1
fi

echo "Running strict Ren'Py mobile source preflight: $renpy_build"
if ! preflight_output="$("$launcher" --check-renpy-build --renpy-build "$renpy_build" 2>&1)"; then
    printf '%s\n' "$preflight_output" >&2
    echo "Ren'Py mobile source preflight failed; no payload was built" >&2
    exit 1
fi
printf '%s\n' "$preflight_output"

if [[ "$mode" == "check" || "$mode" == "auto" ]]; then
    echo "Ren'Py mobile source preflight passed; build not requested"
    exit 0
fi

build_script="$renpy_build/build.sh"
[[ -x "$build_script" ]] || { echo "renpy-build/build.sh is not executable: $build_script" >&2; exit 1; }

echo "Building Android lifecycle payload (opt-in, potentially multi-hour)"
(
    cd "$renpy_build"
    ./build.sh --platform android rebuild renpython rapt rapt-sdl2
)

artifact_root="$renpy_build/renpy"
android_arm64="$artifact_root/rapt/prototype/renpyandroid/src/main/jniLibs/arm64-v8a/librenpython.so"
android_armv7="$artifact_root/rapt/prototype/renpyandroid/src/main/jniLibs/armeabi-v7a/librenpython.so"
android_x86_64="$artifact_root/rapt/prototype/renpyandroid/src/main/jniLibs/x86_64/librenpython.so"
for artifact in "$android_arm64" "$android_armv7" "$android_x86_64"; do
    [[ -f "$artifact" ]] || { echo "Android lifecycle artifact missing: $artifact" >&2; exit 1; }
done

RENPY_MOBILE_ANDROID_SO="$android_arm64"     bash "$repo_root/tools/test_renpy_mobile_symbol_gate.sh"

if [[ "${AETHERKIRI_RENPY_BUILD_IOS:-0}" == "1" ]]; then
    echo "Building iOS lifecycle payload (licensed SDK archives required)"
    (
        cd "$renpy_build"
        ./build.sh --platform ios rebuild renpython renios
    )
    ios_release="$artifact_root/renios/prototype/prebuilt/release/librenpython.a"
    ios_debug="$artifact_root/renios/prototype/prebuilt/debug/librenpython.a"
    for artifact in "$ios_release" "$ios_debug"; do
        [[ -f "$artifact" ]] || { echo "iOS lifecycle artifact missing: $artifact" >&2; exit 1; }
    done
    if command -v xcrun >/dev/null 2>&1; then
        RENPY_MOBILE_IOS_A="$ios_release"             bash "$repo_root/tools/test_renpy_mobile_symbol_gate.sh"
    else
        echo "iOS payload built but xcrun is unavailable; export check deferred to macOS" >&2
        exit 1
    fi
fi

echo "Native lifecycle payload built and export-gated; device/simulator gameplay is still unverified"
