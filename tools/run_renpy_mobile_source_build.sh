#!/usr/bin/env bash
# Build a coherent Ren'Py 8.5.3 mobile fork, never an unpatched RAPT launcher.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
launcher="$repo_root/bridge/renpy_runtime/mobile_launcher/build.sh"
patch_root="$repo_root/bridge/renpy_runtime/mobile_launcher/patches"
mode="${AETHERKIRI_RENPY_SOURCE_BUILD_MODE:-auto}"
renpy_build="${AETHERKIRI_RENPY_BUILD_ROOT:-$repo_root/.aetherkiri-cache/renpy-build}"
platform="${AETHERKIRI_RENPY_SOURCE_BUILD_PLATFORM:-android}"
output_dir="${AETHERKIRI_RENPY_SOURCE_OUTPUT:-$repo_root/out/renpy-mobile-source}"
source_url="${AETHERKIRI_RENPY_BUILD_URL:-https://github.com/renpy/renpy-build.git}"
build_sha=7bfab40c1174f622f644b24669afd5fb167fbb79
renpy_sha=39895c1e017f0b36ffea2447d97eccd69d76ee1c
greenlet_sha=65f8da82b13a1273e55a6bfcbd1f9da09fc4eb7a
fetch=false
usage() {
    cat <<'USAGE'
Usage: tools/run_renpy_mobile_source_build.sh [options]
  --mode MODE          auto, skip, prepare, check, or build
  --renpy-build PATH   coherent official Ren'Py 8.5.3 build checkout
  --fetch              fetch pinned official GitHub sources when absent
  --platform PLATFORM  android (default), ios, or all
  --output-dir PATH    real native payload and provenance destination
  --url URL            renpy-build source mirror (revision remains pinned)
  --ref REF            compatibility option; must be the pinned build SHA
Prepare clones the pinned source and greenlet dependency and applies all Python
and native patches. It does not install host packages or licensed SDKs.
Build runs the actual cross compilation and gates every lifecycle export.
Auto builds when a checkout exists; it never substitutes check for compilation.
Neither a successful build nor export checks assert device gameplay.
USAGE
}
while (($#)); do
    case "$1" in
        --mode|--renpy-build|--platform|--output-dir|--url|--ref)
            (($# >= 2)) || { echo "$1 requires a value" >&2; exit 2; }
            case "$1" in
                --mode) mode="$2" ;;
                --renpy-build) renpy_build="$2" ;;
                --platform) platform="$2" ;;
                --output-dir) output_dir="$2" ;;
                --url) source_url="$2" ;;
                --ref) [[ "$2" == "$build_sha" ]] || { echo "unsupported build revision: $2; expected $build_sha" >&2; exit 2; } ;;
            esac
            shift 2 ;;
        --fetch) fetch=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done
case "$mode" in auto|skip|prepare|check|build) ;; *) echo "invalid mode: $mode" >&2; exit 2 ;; esac
case "$platform" in android|ios|all) ;; *) echo "invalid platform: $platform" >&2; exit 2 ;; esac
if [[ "$mode" == skip ]]; then
    echo "Ren'Py mobile source build skipped by request (no payload built)"
    exit 0
fi
clone_pin() {
    local url="$1" destination="$2" revision="$3"
    if [[ ! -d "$destination" ]]; then
        [[ "$fetch" == true ]] || { echo "missing official source: $destination (use --fetch)" >&2; return 1; }
        mkdir -p "$(dirname "$destination")"
        git clone --filter=blob:none --no-checkout "$url" "$destination"
        git -C "$destination" fetch --depth 1 origin "$revision"
        git -C "$destination" checkout --detach "$revision"
    fi
    local actual
    actual="$(git -C "$destination" rev-parse HEAD)"
    [[ "$actual" == "$revision" ]] || {
        echo "unsupported source revision in $destination: $actual; expected $revision" >&2
        return 1
    }
}
if [[ ! -d "$renpy_build" && "$fetch" != true && "$mode" == auto &&
      "${AETHERKIRI_RENPY_SOURCE_BUILD_REQUIRED:-0}" != 1 ]]; then
    echo "Ren'Py mobile source build skipped: official renpy-build checkout is absent"
    exit 0
fi
if [[ ! -d "$renpy_build" && "$fetch" != true ]]; then
    echo "Ren'Py mobile source build requires an official renpy-build checkout: $renpy_build" >&2
    exit 1
fi
clone_pin "$source_url" "$renpy_build" "$build_sha"
if [[ "$(uname -s)" == Darwin && "$mode" != prepare ]]; then
    [[ "$platform" == ios ]] || { echo "native macOS builds currently support --platform ios only" >&2; exit 1; }
    command -v brew >/dev/null || { echo "Homebrew is required for the native macOS source build" >&2; exit 1; }
    host_deps=()
    for dependency in openssl@3 xz bzip2 libffi; do
        host_deps+=("$(brew --prefix "$dependency")")
    done
    AETHERKIRI_RENPY_HOST_DEPS="$(IFS=:; echo "${host_deps[*]}")"
    export AETHERKIRI_RENPY_HOST_DEPS
    export LIBTOOLIZE=glibtoolize
    config_sub_candidates=("$(brew --prefix automake)"/share/automake-*/config.sub)
    [[ -f "${config_sub_candidates[0]}" ]] || { echo "Homebrew automake config.sub is missing" >&2; exit 1; }
    export AETHERKIRI_RENPY_CONFIG_SUB="${config_sub_candidates[0]}"
fi

if [[ "$mode" == check ]]; then
    bash "$launcher" --check-renpy-build --renpy-build "$renpy_build" --platform "$platform"
    echo "Ren'Py source preflight passed; no compilation requested"
    exit 0
fi
clone_pin https://github.com/renpy/renpy.git "$renpy_build/renpy" "$renpy_sha"
clone_pin https://github.com/python-greenlet/greenlet.git "$renpy_build/aether-greenlet" "$greenlet_sha"
python3 "$repo_root/tools/apply_renpy_mobile_patch_series.py" \
    --checkout "$renpy_build/renpy" --pin "$renpy_sha" \
    "$patch_root/python/0001-cooperative-loop-skeleton.patch"
python3 "$repo_root/tools/apply_renpy_mobile_patch_series.py" \
    --checkout "$renpy_build" --pin "$build_sha" \
    "$patch_root/native"/000[0-9]-*.patch
cp "$patch_root/native/renpy_mobile_lifecycle.c" "$renpy_build/runtime/renpy_mobile_lifecycle.c"
cp "$repo_root/bridge/renpy_runtime/mobile_launcher/include/renpy_mobile_launcher.h" "$renpy_build/runtime/renpy_mobile_launcher.h"
mkdir -p "$renpy_build/runtime/greenlet"
cp -a "$renpy_build/aether-greenlet/src/greenlet/." "$renpy_build/runtime/greenlet/"
cp "$renpy_build/aether-greenlet/LICENSE" "$renpy_build/runtime/greenlet/LICENSE"
cp "$renpy_build/aether-greenlet/LICENSE.PSF" "$renpy_build/runtime/greenlet/LICENSE.PSF"
# Detached release sources otherwise fall back to development 8.6 metadata.
cat > "$renpy_build/renpy/renpy/vc_version.py" <<'VERSION'
version = "8.5.3.26051504"
version_name = "AetherKiri mobile fork"
branch = "fix"
official = False
nightly = False
VERSION
python3 -m py_compile "$renpy_build/renpy/renpy/aether_mobile.py" \
    "$renpy_build/renpy/renpy/bootstrap.py" "$renpy_build/renpy/renpy/execution.py" \
    "$renpy_build/renpy/renpy/display/core.py" "$renpy_build/tasks/renpython.py"
if [[ "$mode" == prepare ]]; then
    echo "Pinned Ren'Py mobile sources prepared; no native payload was compiled"
    exit 0
fi
bash "$launcher" --check-renpy-build --renpy-build "$renpy_build" --platform "$platform"
# All prerequisite tasks must run: selecting only renpython would link stale
# librenpy and would omit the new Surface method and target standard library.
if [[ "$platform" == android || "$platform" == all ]]; then
    (cd "$renpy_build"; ./build.sh --platform android --python 3 rebuild librenpy pythonlib renpython rapt sdl2)
fi
if [[ "$platform" == ios || "$platform" == all ]]; then
    ios_arch_args=()
    if [[ "$(uname -s)" == Darwin ]]; then
        ios_arch_args=(--arch arm64,sim-arm64)
    fi
    (cd "$renpy_build"; ./build.sh --platform ios --python 3 "${ios_arch_args[@]}" rebuild librenpy pythonlib renpython renios)
fi
symbols=(renpy_mobile_bootstrap renpy_mobile_bind_window renpy_mobile_init renpy_mobile_tick
         renpy_mobile_frame renpy_mobile_input renpy_mobile_pause renpy_mobile_resume renpy_mobile_shutdown
         renpy_mobile_text_input_state renpy_mobile_set_surface_size)
check_exports() {
    local artifact="$1" kind="$2" output symbol
    [[ -f "$artifact" ]] || { echo "missing compiled artifact: $artifact" >&2; exit 1; }
    if [[ "$kind" == android ]]; then
        output="$(nm -D --defined-only "$artifact")"
    elif [[ "$(uname -s)" == Darwin ]]; then
        output="$(xcrun nm -gU "$artifact")"
    else
        output="$(llvm-nm-18 --defined-only --extern-only "$artifact")"
    fi
    for symbol in "${symbols[@]}"; do
        awk -v symbol="$symbol" '{ name=$NF; sub(/^_/, "", name); if (name==symbol) found=1 } END { exit !found }' <<<"$output" || {
            echo "compiled artifact lacks $symbol: $artifact" >&2; exit 1;
        }
    done
}
artifact_root="$renpy_build/renpy"
if [[ "$platform" == android || "$platform" == all ]]; then
    for abi in arm64-v8a armeabi-v7a x86_64; do
        check_exports "$artifact_root/rapt3/prototype/renpyandroid/src/main/jniLibs/$abi/librenpython.so" android
    done
fi
if [[ "$platform" == ios || "$platform" == all ]]; then
    for kind in release debug; do
        check_exports "$artifact_root/renios3/prototype/prebuilt/$kind/librenpython.a" ios
    done
fi
# Only create the distributable payload after actual builds/export checks pass.
mkdir -p "$output_dir/payload"
if [[ "$platform" == android || "$platform" == all ]]; then
    mkdir -p "$output_dir/payload/rapt"
    cp -a "$artifact_root/rapt3/." "$output_dir/payload/rapt/"
fi
if [[ "$platform" == ios || "$platform" == all ]]; then
    mkdir -p "$output_dir/payload/renios"
    cp -a "$artifact_root/renios3/." "$output_dir/payload/renios/"
fi
python3 - "$artifact_root" "$output_dir" "$platform" "$build_sha" "$renpy_sha" "$greenlet_sha" "$patch_root" <<'PY'
import hashlib, json, pathlib, shutil, sys
source, output = map(pathlib.Path, sys.argv[1:3]); platform = sys.argv[3]
for target in (["rapt"] if platform == "android" else ["renios"] if platform == "ios" else ["rapt", "renios"]):
    private = output / "payload" / target / ("runtime/private" if target == "rapt" else "prototype/base")
    private.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source / "renpy.py", private / ("main.py" if target == "rapt" else "renpy.py"))
    shutil.copytree(source / "renpy", private / "renpy", dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns("__pycache__", "*.pyx", "*.pxd", "*.pxi"))
    shutil.copytree(source / "lib/python3.12", private / "lib/python3.12", dirs_exist_ok=True)
    (private / "game").mkdir(exist_ok=True)
    licenses = private / "licenses" / "greenlet"
    licenses.mkdir(parents=True, exist_ok=True)
    for name in ("LICENSE", "LICENSE.PSF"):
        shutil.copy2(source.parent / "aether-greenlet" / name, licenses / name)
manifest = {"schema_version": 1, "renpy_version": "8.5.3.26051504+unofficial", "distribution": "8.5.3-rebuilt", "abi_version": 2,
            "build_source_sha": sys.argv[4], "renpy_source_sha": sys.argv[5],
            "greenlet_source_sha": sys.argv[6], "platform": platform,
            "native_compilation": "passed", "device_gameplay": "unverified",
            "patches": {str(p.relative_to(sys.argv[7])): hashlib.sha256(p.read_bytes()).hexdigest()
                        for p in pathlib.Path(sys.argv[7]).rglob("*.patch")}}
(output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
for target in (output / "payload").iterdir():
    if target.name in ("rapt", "renios"):
        (target / "aether-runtime.json").write_text(json.dumps(manifest, indent=2) + "\n")
PY
echo "Native mobile fork compiled and export-gated: $output_dir/payload"
echo "Device/simulator rendering, input and lifecycle gameplay remain unverified"
