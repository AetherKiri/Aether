#!/usr/bin/env bash
# Check or install a host-owned Ren'Py mobile launcher fork.
#
# This script never transforms the official blocking launcher by itself.  It
# checks the upstream source locations, prints the exact renpy-build hooks, and
# optionally installs already-built artifacts only when they export the
# versioned host lifecycle ABI from include/renpy_mobile_launcher.h.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
contract_header="$repo_root/bridge/renpy_runtime/mobile_launcher/include/renpy_mobile_launcher.h"

usage() {
    cat <<'USAGE'
Usage:
  build.sh --check --renpy-build PATH
  build.sh --compile-contract --renpy-build PATH [--output-dir PATH]
  build.sh --check-python-patch --renpy-src PATH
  build.sh --apply-python-patch --renpy-src PATH
  build.sh --print-plan --renpy-build PATH
  build.sh --install --renpy-build PATH --stage PATH \
      [--android-so-arm64 PATH] [--android-so-armv7 PATH]
      [--android-so-x86_64 PATH] [--ios-debug-a PATH] [--ios-release-a PATH]

--check validates the official source layout and confirms that the current
launcher is still the blocking SDL_main/launcher_main implementation.
--source-build-plan prints the official renpy-build source-build commands,
required Ubuntu/toolchain inputs, and the exact RAPT/Renios artifact paths.
--check-renpy-build performs a strict, read-only preflight for those inputs; it
checks platform-specific Ubuntu/disk/toolchain prerequisites, pinned source checkout, SDK archives,
and cooperative-loop patch applicability. It never runs the heavy build.
--compile-contract compiles the Android/iOS templates as contract-only objects;
those objects deliberately return NOT_IMPLEMENTED and are never packaged.
--check-python-patch validates the Ren'Py Python cooperative-loop patch against
an official Ren'Py source checkout. --apply-python-patch applies it in place
only after `git apply --check`; it refuses a dirty checkout. The patch is an
opt-in cooperative loop and does not make the native runtime playable by itself.
--print-plan prints the upstream renpy-build commands and replacement paths.
--install copies caller-supplied, already-built lifecycle artifacts into the
staged RAPT/Renios tree after checking the required exported symbol names.
This script does not build Ren'Py and does not claim the resulting artifacts
are playable; the fork implementation and device/simulator tests remain
required.
USAGE
}

mode=""
platform="android"
renpy_build=""
renpy_src=""
stage=""
android_so_arm64=""
android_so_armv7=""
android_so_x86_64=""
ios_debug_a=""
ios_release_a=""
output_dir=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check|--source-build-plan|--check-renpy-build|--compile-contract|--check-python-patch|--apply-python-patch|--print-plan|--install)
            [[ -z "$mode" ]] || { echo "choose one mode" >&2; exit 2; }
            mode="${1#--}"
            ;;
        --platform)
            [[ $# -ge 2 ]] || { echo "--platform requires a value" >&2; exit 2; }
            platform="$2"; shift
            ;;
        --renpy-build)
            [[ $# -ge 2 ]] || { echo "--renpy-build requires a path" >&2; exit 2; }
            renpy_build="$2"; shift
            ;;
        --renpy-src)
            [[ $# -ge 2 ]] || { echo "--renpy-src requires a path" >&2; exit 2; }
            renpy_src="$2"; shift
            ;;
        --stage)
            [[ $# -ge 2 ]] || { echo "--stage requires a path" >&2; exit 2; }
            stage="$2"; shift
            ;;
        --output-dir)
            [[ $# -ge 2 ]] || { echo "--output-dir requires a path" >&2; exit 2; }
            output_dir="$2"; shift
            ;;
        --android-so|--android-so-arm64)
            [[ $# -ge 2 ]] || { echo "--android-so-arm64 requires a path" >&2; exit 2; }
            android_so_arm64="$2"; shift
            ;;
        --android-so-armv7)
            [[ $# -ge 2 ]] || { echo "--android-so-armv7 requires a path" >&2; exit 2; }
            android_so_armv7="$2"; shift
            ;;
        --android-so-x86_64)
            [[ $# -ge 2 ]] || { echo "--android-so-x86_64 requires a path" >&2; exit 2; }
            android_so_x86_64="$2"; shift
            ;;
        --ios-debug-a)
            [[ $# -ge 2 ]] || { echo "--ios-debug-a requires a path" >&2; exit 2; }
            ios_debug_a="$2"; shift
            ;;
        --ios-release-a)
            [[ $# -ge 2 ]] || { echo "--ios-release-a requires a path" >&2; exit 2; }
            ios_release_a="$2"; shift
            ;;
        -h|--help)
            usage; exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2; usage >&2; exit 2
            ;;
    esac
    shift
done

[[ -n "$mode" ]] || { usage >&2; exit 2; }
[[ -f "$contract_header" ]] || { echo "missing lifecycle contract: $contract_header" >&2; exit 1; }

# The source-build modes are deliberately separate from --install. They make
# the official renpy-build workflow reproducible and auditable without hiding a
# many-hour native rebuild inside the regular AetherKiri CI jobs.
renpy_build_source_preflight() {
    local strict="$1" failures=0 required source_root="${renpy_src:-$renpy_build/renpy}"
    case "$platform" in android|ios|all) ;; *) echo "invalid platform: $platform" >&2; return 2 ;; esac
    for required in build.sh prepare.sh tasks/renpython.py tasks/librenpy.py tasks/rapt.py tasks/renios.py runtime/librenpython3_android.c runtime/librenpython3.c; do
        if [[ ! -f "$renpy_build/$required" ]]; then
            echo "missing renpy-build input: $renpy_build/$required" >&2
            failures=$((failures + 1))
        fi
    done
    if ! git -C "$renpy_build" rev-parse HEAD >/dev/null 2>&1 ||
       [[ "$(git -C "$renpy_build" rev-parse HEAD 2>/dev/null)" != 7bfab40c1174f622f644b24669afd5fb167fbb79 ]]; then
        echo "renpy-build must be pinned to Ren'Py 8.5.3 build SHA 7bfab40c1174f622f644b24669afd5fb167fbb79" >&2
        failures=$((failures + 1))
    fi
    if ! git -C "$source_root" rev-parse HEAD >/dev/null 2>&1; then
        echo "Ren'Py source checkout missing: $source_root" >&2
        failures=$((failures + 1))
    elif [[ "$(git -C "$source_root" rev-parse HEAD)" != 39895c1e017f0b36ffea2447d97eccd69d76ee1c ]]; then
        echo "Ren'Py source must be pinned to 8.5.3 SHA 39895c1e017f0b36ffea2447d97eccd69d76ee1c" >&2
        failures=$((failures + 1))
    elif git -C "$source_root" apply --check "$python_patch" >/dev/null 2>&1; then
        echo "cooperative-loop patch: applies cleanly (prepare required before build)"
    elif git -C "$source_root" apply --reverse --check "$python_patch" >/dev/null 2>&1; then
        echo "cooperative-loop patch: already applied to the actual build source"
    else
        echo "cooperative-loop patch does not match $source_root" >&2
        failures=$((failures + 1))
    fi
    local host_system="$(uname -s)" archives=() host_tools=()
    [[ "$platform" == ios ]] || archives+=(android-ndk-r29-linux.zip)
    if [[ "$platform" != android && "$host_system" != Darwin ]]; then
        archives+=(iPhoneOS14.0.sdk.tar.gz iPhoneSimulator14.0.sdk.tar.gz)
    fi
    # Bash 3.2 treats an empty array as unset under nounset (the macOS default).
    for required in ${archives[@]+"${archives[@]}"}; do
        if [[ ! -f "$renpy_build/tars/$required" ]]; then
            echo "missing toolchain archive: $renpy_build/tars/$required" >&2
            failures=$((failures + 1))
        fi
    done
    host_tools=(bash git python3 curl tar unzip make cmake ninja pkg-config ccache autoconf automake uv)
    if [[ "$host_system" == Darwin ]]; then
        host_tools+=(brew xcrun glibtoolize realpath)
    else
        host_tools+=(clang-18 clang++-18 llvm-ar-18 llvm-nm-18)
    fi
    for required in "${host_tools[@]}"; do
        if ! command -v "$required" >/dev/null 2>&1; then
            echo "missing host tool: $required" >&2
            failures=$((failures + 1))
        fi
    done
    local ubuntu_id="" ubuntu_version=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        ubuntu_id="${ID:-}"; ubuntu_version="${VERSION_ID:-}"
    fi
    if [[ "$host_system" == Darwin ]]; then
        if [[ "$platform" != ios ]]; then
            echo "native macOS source builds support --platform ios only" >&2
            failures=$((failures + 1))
        fi
        local sdk sdk_path sdk_tool
        for sdk in macosx iphoneos iphonesimulator; do
            sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path 2>/dev/null || true)"
            if [[ ! -d "$sdk_path" ]]; then
                echo "selected Xcode is missing its $sdk SDK" >&2
                failures=$((failures + 1))
            else
                echo "local Xcode $sdk SDK: $sdk_path"
            fi
        done
        for sdk_tool in clang clang++ ar ranlib nm lipo otool; do
            if ! xcrun --find "$sdk_tool" >/dev/null 2>&1; then
                echo "selected Xcode is missing $sdk_tool" >&2
                failures=$((failures + 1))
            fi
        done
        for required in openssl@3 xz bzip2 libffi; do
            local dependency_prefix
            dependency_prefix="$(brew --prefix "$required" 2>/dev/null || true)"
            if [[ ! -d "$dependency_prefix/include" || ! -d "$dependency_prefix/lib" ]]; then
                echo "missing native host dependency: $required" >&2
                failures=$((failures + 1))
            fi
        done
        if [[ ! -f "${AETHERKIRI_RENPY_CONFIG_SUB:-}" ]]; then
            echo "missing Homebrew automake config.sub (use the source runner build mode)" >&2
            failures=$((failures + 1))
        fi
    elif [[ "$host_system" != Linux || "$ubuntu_id" != ubuntu || "$ubuntu_version" != 24.04 ]]; then
        echo "renpy-build officially requires Ubuntu 24.04 (detected ${ubuntu_id:-unknown} ${ubuntu_version:-unknown})" >&2
        failures=$((failures + 1))
    fi
    local available_kib
    available_kib="$(df -Pk "$renpy_build" | awk 'NR==2 {print $4}')"
    if [[ ! "$available_kib" =~ ^[0-9]+$ ]] || (( available_kib < 64 * 1024 * 1024 )); then
        echo "insufficient free disk for renpy-build (official minimum: 64 GiB; available ${available_kib:-unknown} KiB)" >&2
        failures=$((failures + 1))
    fi
    if [[ "$strict" == 1 && "$failures" != 0 ]]; then
        echo "Ren'Py source-build preflight failed with $failures issue(s)" >&2
        return 1
    fi
}

renpy_build_source_plan() {
    cat <<PLAN
Ren'Py 8.5.3 source build (Ubuntu 24.04, LLVM18, at least 64 GiB)
  Native iOS alternative: macOS/Xcode with local SDKs, at least 64 GiB free disk
  Build SHA: 7bfab40c1174f622f644b24669afd5fb167fbb79
  Ren'Py SHA: 39895c1e017f0b36ffea2447d97eccd69d76ee1c
  Greenlet SHA: 65f8da82b13a1273e55a6bfcbd1f9da09fc4eb7a
  Android: (cd $renpy_build && ./build.sh --platform android --python 3 rebuild librenpy pythonlib renpython rapt sdl2)
  iOS: (cd $renpy_build && ./build.sh --platform ios --python 3 rebuild librenpy pythonlib renpython renios)
  macOS iOS: source runner --platform ios builds --arch arm64,sim-arm64 with xcrun
  Android archive: tars/android-ndk-r29-linux.zip
  iOS licensed archives: tars/iPhoneOS14.0.sdk.tar.gz, tars/iPhoneSimulator14.0.sdk.tar.gz
  Android libraries: renpy/rapt3/prototype/renpyandroid/src/main/jniLibs/{arm64-v8a,armeabi-v7a,x86_64}/librenpython.so
  iOS libraries: renpy/renios3/prototype/prebuilt/{release,debug}/librenpython.a
  Prepare: $repo_root/tools/run_renpy_mobile_source_build.sh --mode prepare --fetch --renpy-build $renpy_build --platform $platform
This plan does not assert mobile playability. Compilation and real device gameplay are separate gates.
PLAN
}


python_patch="$repo_root/bridge/renpy_runtime/mobile_launcher/patches/python/0001-cooperative-loop-skeleton.patch"
if [[ "$mode" == "source-build-plan" || "$mode" == "check-renpy-build" ]]; then
    [[ -n "$renpy_build" ]] || { echo "--renpy-build is required" >&2; exit 2; }
    [[ -d "$renpy_build" ]] || { echo "renpy-build directory not found: $renpy_build" >&2; exit 1; }
    renpy_build_source_plan
    if [[ "$mode" == "check-renpy-build" ]]; then
        renpy_build_source_preflight 1
    fi
    exit 0
fi

if [[ "$mode" == "check-python-patch" || "$mode" == "apply-python-patch" ]]; then
    [[ -n "$renpy_src" ]] || { echo "--renpy-src is required" >&2; exit 2; }
    [[ -d "$renpy_src" ]] || { echo "Ren'Py source checkout not found: $renpy_src" >&2; exit 1; }
    [[ -f "$python_patch" ]] || { echo "missing cooperative-loop patch: $python_patch" >&2; exit 1; }
    git -C "$renpy_src" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
        echo "--renpy-src must be a git checkout" >&2; exit 1;
    }
    if git -C "$renpy_src" apply --reverse --check "$python_patch" >/dev/null 2>&1; then
        echo "Ren'Py Python cooperative-loop patch applies cleanly (already applied)"
        exit 0
    fi
    git -C "$renpy_src" apply --check "$python_patch"
    if [[ "$mode" == "check-python-patch" ]]; then
        echo "Ren'Py Python cooperative-loop patch applies cleanly"
        echo "  cooperative Python loop validated; native ABI/frame/input integration remains required"
        exit 0
    fi
    if [[ -n "$(git -C "$renpy_src" status --porcelain --untracked-files=no)" ]]; then
        echo "refusing to apply cooperative-loop patch to a dirty Ren'Py checkout" >&2
        exit 1
    fi
    git -C "$renpy_src" apply "$python_patch"
    python3 -m py_compile "$renpy_src/renpy/aether_mobile.py" \
        "$renpy_src/renpy/bootstrap.py" "$renpy_src/renpy/execution.py" "$renpy_src/renpy/display/core.py"
    echo "applied and syntax-checked Ren'Py Python cooperative loop"
    echo "  native ABI/frame/input integration and device E2E remain required"
    exit 0
fi

[[ -n "$renpy_build" ]] || { echo "--renpy-build is required" >&2; exit 2; }
[[ -d "$renpy_build" ]] || { echo "renpy-build directory not found: $renpy_build" >&2; exit 1; }

runtime="$renpy_build/runtime"
tasks="$renpy_build/tasks/renpython.py"
renios_main="$renpy_build/renios/prototype/main.c"
for required in \
    "$runtime/librenpython3_android.c" \
    "$runtime/librenpython3.c" \
    "$runtime/jniwrapperstuff.h" \
    "$tasks" \
    "$renios_main"; do
    [[ -f "$required" ]] || { echo "missing official Ren'Py build input: $required" >&2; exit 1; }
done

# Keep this check source-based: it works on a checkout without requiring a
# host compiler or an Apple/Android SDK.
grep -Eq 'int[[:space:]]+SDL_main[[:space:]]*\(' "$runtime/librenpython3_android.c" || {
    echo "official Android launcher no longer contains SDL_main; inspect before using this scaffold" >&2
    exit 1
}
grep -Eq 'Py_RunMain[[:space:]]*\(' "$runtime/librenpython3_android.c" || {
    echo "official Android launcher no longer contains Py_RunMain; inspect before using this scaffold" >&2
    exit 1
}
grep -Eq 'launcher_main[[:space:]]*\(' "$runtime/librenpython3.c" || {
    echo "official desktop/iOS launcher no longer contains launcher_main; inspect before using this scaffold" >&2
    exit 1
}
grep -Eq 'Py_RunMain[[:space:]]*\(' "$runtime/librenpython3.c" || {
    echo "official desktop/iOS launcher no longer contains Py_RunMain; inspect before using this scaffold" >&2
    exit 1
}
grep -Eq 'SDL_RunApp|SDL_UIKitRunApp' "$renios_main" || {
    echo "Renios prototype entrypoint changed; inspect before using this scaffold" >&2
    exit 1
}

print_plan() {
    cat <<PLAN
Official inputs
  Android source: $runtime/librenpython3_android.c
  iOS/desktop source: $runtime/librenpython3.c
  JNI helper: $runtime/jniwrapperstuff.h
  Ren'Py build task: $tasks
  Renios prototype entrypoint: $renios_main

Required fork work (outside this scaffold)
  Add the symbols in $contract_header to the launcher source.
  Move Python/SDL setup out of SDL_main/launcher_main into init.
  Make tick/frame/input/pause/resume/shutdown return promptly; do not call
  Py_RunMain, SDL_main, SDL_RunApp, SDL_UIKitRunApp, or UIApplicationMain.

Official renpy-build hooks
  Android: (cd $renpy_build && ./build.sh --platform android --python 3 rebuild librenpy pythonlib renpython rapt sdl2)
  iOS:     (cd $renpy_build && ./build.sh --platform ios --python 3 rebuild librenpy pythonlib renpython renios)
  Android output (per ABI): tmp/install.android-*/lib/librenpython.so
  iOS output (per ABI):     tmp/install.ios-*/lib/librenpython.a

Replacement destinations
  Android arm64-v8a: $stage/rapt/prototype/renpyandroid/src/main/jniLibs/arm64-v8a/librenpython.so
  Android armeabi-v7a: $stage/rapt/prototype/renpyandroid/src/main/jniLibs/armeabi-v7a/librenpython.so
  Android x86_64:      $stage/rapt/prototype/renpyandroid/src/main/jniLibs/x86_64/librenpython.so
  iOS release:         $stage/renios/prototype/prebuilt/release/librenpython.a
  iOS debug:           $stage/renios/prototype/prebuilt/debug/librenpython.a
PLAN
}

if [[ "$mode" == "check" ]]; then
    echo "Ren'Py mobile launcher scaffold source check ok"
    echo "  official Android launcher remains blocking (SDL_main -> Py_RunMain)"
    echo "  official iOS/desktop launcher remains blocking (launcher_main -> Py_RunMain)"
    echo "  no artifact was built or installed"
    exit 0
fi

if [[ "$mode" == "compile-contract" ]]; then
    compiler="${CC:-cc}"
    output_dir="${output_dir:-$repo_root/out/renpy-mobile-contract}"
    mkdir -p "$output_dir"
    common=(-std=c11 -Wall -Wextra -Werror -fPIC -I"$repo_root/bridge/renpy_runtime/mobile_launcher/include" -DAETHERKIRI_RENPY_LIFECYCLE_CONTRACT_ONLY=1)
    "$compiler" "${common[@]}" -x c -c \
        "$repo_root/bridge/renpy_runtime/mobile_launcher/patches/android/librenpython_android_host.c.template" \
        -o "$output_dir/librenpython_android_host.o"
    "$compiler" "${common[@]}" -x c -c \
        "$repo_root/bridge/renpy_runtime/mobile_launcher/patches/ios/librenpython_ios_host.c.template" \
        -o "$output_dir/librenpython_ios_host.o"
    echo "compiled contract-only launcher objects in $output_dir"
    echo "these objects intentionally return RENPY_MOBILE_NOT_IMPLEMENTED and are not runtime artifacts"
    exit 0
fi

print_plan
[[ "$mode" == "print-plan" ]] && exit 0

[[ -n "$stage" ]] || { echo "--stage is required for --install" >&2; exit 2; }
[[ -n "$android_so_arm64" || -n "$android_so_armv7" || -n "$android_so_x86_64" ||
   -n "$ios_debug_a" || -n "$ios_release_a" ]] || {
    echo "--install requires at least one artifact path" >&2
    exit 2
}

required_symbols=(
    renpy_mobile_bootstrap
    renpy_mobile_bind_window
    renpy_mobile_init
    renpy_mobile_tick
    renpy_mobile_frame
    renpy_mobile_input
    renpy_mobile_pause
    renpy_mobile_resume
    renpy_mobile_shutdown
    renpy_mobile_text_input_state
    renpy_mobile_set_surface_size
)

nm_symbols() {
    local artifact="$1" kind="$2"
    case "$kind" in
        android)
            nm -D --defined-only "$artifact"
            ;;
        ios)
            if command -v xcrun >/dev/null 2>&1; then
                xcrun nm -gU "$artifact"
            else
                nm -g "$artifact"
            fi
            ;;
        *) echo "unknown lifecycle artifact kind: $kind" >&2; return 2 ;;
    esac
}

check_symbols() {
    local artifact="$1" kind="$2" expected_machine="${3:-}"
    [[ -f "$artifact" ]] || { echo "artifact not found: $artifact" >&2; exit 1; }
    if LC_ALL=C grep -aFq 'AETHERKIRI_RENPY_LIFECYCLE_STUB' "$artifact"; then
        echo "refusing contract-only lifecycle stub as runtime artifact: $artifact" >&2
        exit 1
    fi

    local format
    format="$(file -b "$artifact" 2>/dev/null || true)"
    case "$kind" in
        android)
            [[ "$format" == *ELF* && "$format" == *shared\ object* ]] || {
                echo "Android lifecycle artifact is not an ELF shared object: $artifact ($format)" >&2
                exit 1
            }
            if [[ -n "$expected_machine" ]]; then
                command -v readelf >/dev/null 2>&1 || {
                    echo "readelf is required to validate Android ABI: $artifact" >&2
                    exit 1
                }
                local machine
                machine="$(readelf -h "$artifact" | sed -n 's/^ *Machine: *//p')"
                [[ "$machine" == "$expected_machine" ]] || {
                    echo "Android lifecycle artifact ABI mismatch: expected $expected_machine, got $machine" >&2
                    exit 1
                }
            fi
            ;;
        ios)
            [[ "$format" == *archive* || "$format" == *Mach-O* ]] || {
                echo "iOS lifecycle artifact is not a static archive: $artifact ($format)" >&2
                exit 1
            }
            ;;
        *) echo "unknown lifecycle artifact kind: $kind" >&2; exit 2 ;;
    esac

    local symbols
    symbols="$(mktemp)"
    if ! nm_symbols "$artifact" "$kind" >"$symbols" 2>/dev/null; then
        echo "could not inspect lifecycle symbols in $artifact; install the native nm/xcrun toolchain" >&2
        rm -f "$symbols"
        exit 1
    fi
    local symbol
    for symbol in "${required_symbols[@]}"; do
        if ! awk -v symbol="$symbol" '{ name=$NF; sub(/^_/, "", name); if (name==symbol) found=1 } END { exit !found }' "$symbols"; then
            echo "artifact lacks required lifecycle export $symbol: $artifact" >&2
            rm -f "$symbols"
            exit 1
        fi
    done
    rm -f "$symbols"
}

install_one() {
    local source="$1" destination="$2" kind="$3" expected_machine="${4:-}"
    check_symbols "$source" "$kind" "$expected_machine"
    mkdir -p "$(dirname "$destination")"
    install -m 0755 "$source" "$destination"
    echo "installed host lifecycle artifact: $destination"
}

# Each Android ABI is explicit so an arm64 binary cannot silently be copied
# into an armv7/x86_64 slot. The expected machine is checked from ELF headers.
if [[ -n "$android_so_arm64" ]]; then
    install_one "$android_so_arm64" "$stage/rapt/prototype/renpyandroid/src/main/jniLibs/arm64-v8a/librenpython.so" android "AArch64"
fi
if [[ -n "$android_so_armv7" ]]; then
    install_one "$android_so_armv7" "$stage/rapt/prototype/renpyandroid/src/main/jniLibs/armeabi-v7a/librenpython.so" android "ARM"
fi
if [[ -n "$android_so_x86_64" ]]; then
    install_one "$android_so_x86_64" "$stage/rapt/prototype/renpyandroid/src/main/jniLibs/x86_64/librenpython.so" android "Advanced Micro Devices X86-64"
fi
if [[ -n "$ios_release_a" ]]; then
    install_one "$ios_release_a" "$stage/renios/prototype/prebuilt/release/librenpython.a" ios
fi
if [[ -n "$ios_debug_a" ]]; then
    install_one "$ios_debug_a" "$stage/renios/prototype/prebuilt/debug/librenpython.a" ios
fi

echo "Artifacts installed, but playable mobile support is not asserted by this scaffold"
