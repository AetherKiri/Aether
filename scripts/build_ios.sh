#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BUILD_TYPE="debug"
SIMULATOR=false
SIMULATOR_ARCH="${IOS_SIMULATOR_ARCH:-$(uname -m)}"
PACKAGE_IPA=false
for arg in "$@"; do
    case "$arg" in
        debug|release|Debug|Release) BUILD_TYPE="$arg" ;;
        --simulator) SIMULATOR=true ;;
        --simulator-arch=*) SIMULATOR_ARCH="${arg#*=}" ;;
        --package-ipa|--unsigned-ipa|--ipa) PACKAGE_IPA=true ;;
        *) echo "[WARN] Unknown iOS build argument ignored: $arg" ;;
    esac
done

BUILD_TYPE_LOWER="$(echo "$BUILD_TYPE" | tr '[:upper:]' '[:lower:]')"
BUILD_TYPE_CAP="$(echo "${BUILD_TYPE_LOWER:0:1}" | tr '[:lower:]' '[:upper:]')${BUILD_TYPE_LOWER:1}"
if [[ "$BUILD_TYPE_LOWER" != debug && "$BUILD_TYPE_LOWER" != release ]]; then
    echo "Error: Use debug or release for the iOS app build." >&2
    exit 1
fi
if [[ "$SIMULATOR" == true && "$BUILD_TYPE_LOWER" != debug ]]; then
    echo "Error: The iOS Simulator app currently uses the Debug CMake/export templates; select debug." >&2
    exit 1
fi

if [[ "$SIMULATOR" == true ]]; then
    if [[ "$SIMULATOR_ARCH" == "x86_64" || "$SIMULATOR_ARCH" == "x64" ]]; then
        SIMULATOR_ARCH="x86_64"
        CMAKE_CONFIG_PRESET="iOS Simulator x64 Debug Config"
        CMAKE_BUILD_PRESET="iOS Simulator x64 Debug Build"
        CMAKE_BUILD_DIR="$PROJECT_ROOT/out/ios-simulator-x64/debug"
        GODOT_TRIPLET_DIR="ios-simulator-x64/debug"
        VCPKG_TRIPLET_DIR="x64-ios-simulator"
    elif [[ "$SIMULATOR_ARCH" == "arm64" ]]; then
        CMAKE_CONFIG_PRESET="iOS Simulator Debug Config"
        CMAKE_BUILD_PRESET="iOS Simulator Debug Build"
        CMAKE_BUILD_DIR="$PROJECT_ROOT/out/ios-simulator/debug"
        GODOT_TRIPLET_DIR="ios-simulator/debug"
        VCPKG_TRIPLET_DIR="arm64-ios-simulator"
    else
        echo "Error: Invalid simulator arch '$SIMULATOR_ARCH'. Use x86_64 or arm64." >&2
        exit 1
    fi
else
    CMAKE_CONFIG_PRESET="iOS ${BUILD_TYPE_CAP} Config"
    CMAKE_BUILD_PRESET="iOS ${BUILD_TYPE_CAP} Build"
    CMAKE_BUILD_DIR="$PROJECT_ROOT/out/ios/$BUILD_TYPE_LOWER"
    GODOT_TRIPLET_DIR="ios/$BUILD_TYPE_LOWER"
    VCPKG_TRIPLET_DIR="arm64-ios"
fi

GODOT_BIN="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
GODOT_EXPORT_TEMPLATE="${GODOT_EXPORT_TEMPLATE:-$HOME/Library/Application Support/Godot/export_templates/4.7.2.stable/ios.zip}"
GODOT_APP_DIR="$PROJECT_ROOT/apps/godot_app"
GODOT_BIN_DIR="$GODOT_APP_DIR/bin/$GODOT_TRIPLET_DIR"
RUNTIME_CJK_FONT_SOURCE="$GODOT_APP_DIR/assets/fonts/aetherkiri-runtime-cjk.otf"
RUNTIME_SYMBOL_FONT_SOURCE="$GODOT_APP_DIR/assets/fonts/aetherkiri-runtime-symbols.ttf"
# When Ren'Py is enabled, isolate the rebuilt Renios native closure in its own
# framework and copy its Python resources into the app. It must never
# copy or compile Renios' prototype main.c: Godot already owns the process and
# the UIKit/SDL application entrypoint.
RENPY_MOBILE_ROOT="${AETHERKIRI_RENPY_MOBILE_ROOT:-${RENPY_MOBILE_ROOT:-$PROJECT_ROOT/out/renpy-mobile-source/payload}}"
RENPY_RENIOS_BASE="${AETHERKIRI_RENPY_RENIOS_BASE:-$RENPY_MOBILE_ROOT/renios/prototype/base}"
PARALLEL_JOBS="${JOBS:-8}"
IOS_EXPORT_DIR="$PROJECT_ROOT/out/godot/ios/$BUILD_TYPE_LOWER"
if [[ "$SIMULATOR" == true ]]; then
    IOS_EXPORT_DIR="$PROJECT_ROOT/out/godot/ios-simulator-$SIMULATOR_ARCH/$BUILD_TYPE_LOWER"
fi
RENPY_FRAMEWORK_NAME=AetherRenPyRuntime
RENPY_FRAMEWORK_OUTPUT="$CMAKE_BUILD_DIR/renpy-native/$RENPY_FRAMEWORK_NAME.framework"
if [[ "$(uname -s)" != Darwin ]] || ! command -v xcrun >/dev/null 2>&1 || ! command -v xcodebuild >/dev/null 2>&1; then
    echo "Error: iOS app packaging requires a cloud macOS host with Xcode and its licensed iPhoneOS/iPhoneSimulator SDK; this host has no Apple build tools." >&2
    exit 1
fi
IOS_SDK=iphoneos
[[ "$SIMULATOR" == true ]] && IOS_SDK=iphonesimulator
xcrun --sdk "$IOS_SDK" --show-sdk-path >/dev/null || {
    echo "Error: Xcode lacks the $IOS_SDK SDK required for this iOS target." >&2
    exit 1
}
FORCE_LOAD_PLUGIN_ARCHIVES=(
    "libSDL2.a"
    "libkrkr2plugin.a"
    "libextkagparser.a"
    "libkagparserex.a"
    "liblayerExDraw.a"
    "libmotionplayer.a"
    "libpsbfile.a"
    "libpsdfile.a"
    "libpsdparse.a"
)
FORCE_LOAD_PLUGIN_SOURCES=(
    "vcpkg_installed/$VCPKG_TRIPLET_DIR/lib/libSDL2.a"
    "packages/AetherKrkr/plugins/libkrkr2plugin.a"
    "packages/AetherKrkr/plugins/extkagparser/libextkagparser.a"
    "packages/AetherKrkr/plugins/kagparserex/libkagparserex.a"
    "packages/AetherKrkr/plugins/layerex_draw/liblayerExDraw.a"
    "packages/AetherKrkr/plugins/motionplayer/libmotionplayer.a"
    "packages/AetherKrkr/plugins/psbfile/libpsbfile.a"
    "packages/AetherKrkr/plugins/psdfile/libpsdfile.a"
    "packages/AetherKrkr/plugins/psdfile/psdparse/psdparse/libpsdparse.a"
)
PRIVATE_RUNTIME_ARCHIVE_LISTER="$PROJECT_ROOT/packages/AetherInternal/tools/list_ios_runtime_archives.sh"
if [[ -x "$PRIVATE_RUNTIME_ARCHIVE_LISTER" ]]; then
    private_runtime_target="device"
    if [[ "${SIMULATOR:-false}" == true ]]; then
        private_runtime_target="simulator-$SIMULATOR_ARCH"
    fi
    while IFS=$'\t' read -r archive source; do
        if [[ -z "$archive" || -z "$source" ]]; then
            continue
        fi
        FORCE_LOAD_PLUGIN_ARCHIVES+=("$archive")
        FORCE_LOAD_PLUGIN_SOURCES+=("$source")
    done < <("$PRIVATE_RUNTIME_ARCHIVE_LISTER" "$private_runtime_target")
fi
IOS_SDK_COMPAT_ARCHIVE="libios_sdk_compat_symbols.a"

ensure_vcpkg() {
    if [[ -f "$PROJECT_ROOT/.devtools/vcpkg/.vcpkg-root" ]]; then
        export VCPKG_ROOT="$PROJECT_ROOT/.devtools/vcpkg"
    elif [[ -n "${VCPKG_ROOT:-}" && -f "$VCPKG_ROOT/.vcpkg-root" ]]; then
        export VCPKG_ROOT
    else
        echo "[INFO] vcpkg not found. Automatically setting up vcpkg in .devtools/vcpkg..."
        mkdir -p "$PROJECT_ROOT/.devtools"
        rm -rf "$PROJECT_ROOT/.devtools/vcpkg"
        git clone https://github.com/microsoft/vcpkg.git "$PROJECT_ROOT/.devtools/vcpkg"
        (cd "$PROJECT_ROOT/.devtools/vcpkg" && ./bootstrap-vcpkg.sh -disableMetrics)
        export VCPKG_ROOT="$PROJECT_ROOT/.devtools/vcpkg"
    fi

    if [[ ! -x "$VCPKG_ROOT/vcpkg" ]]; then
        if [[ -x "$VCPKG_ROOT/bootstrap-vcpkg.sh" ]]; then
            echo "[INFO] vcpkg binary missing. Bootstrapping existing vcpkg tree..."
            (cd "$VCPKG_ROOT" && ./bootstrap-vcpkg.sh -disableMetrics)
        else
            echo "[INFO] vcpkg tree is incomplete. Recreating .devtools/vcpkg..."
            mkdir -p "$PROJECT_ROOT/.devtools"
            rm -rf "$PROJECT_ROOT/.devtools/vcpkg"
            git clone https://github.com/microsoft/vcpkg.git "$PROJECT_ROOT/.devtools/vcpkg"
            (cd "$PROJECT_ROOT/.devtools/vcpkg" && ./bootstrap-vcpkg.sh -disableMetrics)
            export VCPKG_ROOT="$PROJECT_ROOT/.devtools/vcpkg"
        fi
    fi
}

ensure_host_rust() {
    # Cargo resolves rustc by bare command name from PATH at build time, so a
    # Homebrew rust shadowing the rustup proxies links Minori against a
    # different std than Siglus (which pins its own toolchain) and the final
    # extension link fails with duplicate _rust_eh_personality symbols. Pin
    # the whole build to one toolchain by prepending the rustup-resolved bin
    # directory (same normalization build_android.sh applies).
    if [[ -n "${CARGO:-}" ]]; then
        local cargo_dir
        cargo_dir="$(dirname "$CARGO")"
        case ":$PATH:" in
            *":$cargo_dir:"*) ;;
            *) export PATH="$cargo_dir:$PATH" ;;
        esac
        return 0
    fi
    command -v rustup >/dev/null || return 0
    local rustc_bin
    rustc_bin="$(rustup which rustc 2>/dev/null || true)"
    [[ -n "$rustc_bin" && -x "$rustc_bin" ]] || return 0
    local toolchain_bin
    toolchain_bin="$(dirname "$rustc_bin")"
    [[ -x "$toolchain_bin/cargo" ]] || return 0
    case ":$PATH:" in
        *":$toolchain_bin:"*) ;;
        *) export PATH="$toolchain_bin:$PATH" ;;
    esac
}

ensure_vcpkg
ensure_host_rust

command -v cmake >/dev/null
NINJA_BIN="${CMAKE_MAKE_PROGRAM:-$(command -v ninja || command -v ninja-build || true)}"
if [[ -z "$NINJA_BIN" ]]; then
    echo "Error: Ninja build tool not found. Install ninja and ensure it is available in PATH." >&2
    exit 1
fi
export CMAKE_MAKE_PROGRAM="$NINJA_BIN"

preflight_simulator_template_arch() {
    local arch="$1"
    local template="$2"

    if [[ ! -f "$template" ]]; then
        return
    fi
    # Check real objects in both engine/camera archives, not only the plist's
    # advertised CPU list. Device arm64 objects cannot satisfy this check.
    python3 "$PROJECT_ROOT/tools/build_godot_ios_simulator_template.py" verify \
        --template "$template" --arch "$arch"
}

if [[ "$SIMULATOR" == true ]]; then
    preflight_simulator_template_arch "$SIMULATOR_ARCH" "$GODOT_EXPORT_TEMPLATE"
fi

resolve_ios_godot_cpp_lib() {
    local triplet_root="$1"
    local arch="$2"
    local build_type="$3"
    local config_name="release"
    local config_upper="RELEASE"
    if [[ "$build_type" == "debug" ]]; then
        config_name="debug"
        config_upper="DEBUG"
    fi

    local config_file="$triplet_root/share/unofficial-godot-cpp/unofficial-godot-cpp-config-$config_name.cmake"
    local location=""
    if [[ -f "$config_file" ]]; then
        location="$(sed -n "s|.*IMPORTED_LOCATION_${config_upper} \"\\(.*\\)\".*|\\1|p" "$config_file" | head -n 1)"
        location="${location//\$\{_IMPORT_PREFIX\}/$triplet_root}"
        if [[ -n "$location" && -f "$location" ]]; then
            printf '%s\n' "$location"
            return 0
        fi
    fi

    local search_dirs=()
    if [[ "$build_type" == "debug" ]]; then
        search_dirs+=("$triplet_root/debug/lib" "$triplet_root/lib")
    else
        search_dirs+=("$triplet_root/lib" "$triplet_root/debug/lib")
    fi

    local dir
    local found
    for dir in "${search_dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        found="$(find "$dir" -maxdepth 1 -name "libgodot-cpp.ios.*.$arch.a" -print -quit 2>/dev/null || true)"
        if [[ -n "$found" ]]; then
            printf '%s\n' "$found"
            return 0
        fi
    done

    return 1
}

build_ios_sdk_compat_archive() {
    local output="$1"
    local triplet="$2"
    local arch="arm64"
    local sdk="iphoneos"
    local min_flag="-mios-version-min=${IOS_MIN_VERSION:-16.0}"
    local work_dir="$CMAKE_BUILD_DIR/ios_sdk_compat"
    local source="$work_dir/ios_sdk_compat_symbols.mm"
    local object="$work_dir/ios_sdk_compat_symbols.o"

    if [[ "$triplet" == "x64-ios-simulator" ]]; then
        arch="x86_64"
        sdk="iphonesimulator"
        min_flag="-mios-simulator-version-min=${IOS_MIN_VERSION:-16.0}"
    elif [[ "$triplet" == "arm64-ios-simulator" ]]; then
        sdk="iphonesimulator"
        min_flag="-mios-simulator-version-min=${IOS_MIN_VERSION:-16.0}"
    fi

    mkdir -p "$work_dir"
    cat > "$source" <<'EOF'
#import <Foundation/Foundation.h>
#include <stddef.h>

extern "C" {
struct hid_device_;
struct hid_device_info;

extern "C" __attribute__((weak, visibility("default"))) NSString * const CADynamicRangeAutomatic = @"CADynamicRangeAutomatic";
extern "C" __attribute__((weak, visibility("default"))) NSString * const CADynamicRangeConstrainedHigh = @"CADynamicRangeConstrainedHigh";
extern "C" __attribute__((weak, visibility("default"))) NSString * const CADynamicRangeHigh = @"CADynamicRangeHigh";
extern "C" __attribute__((weak, visibility("default"))) NSString * const CADynamicRangeStandard = @"CADynamicRangeStandard";
extern "C" __attribute__((weak, visibility("default"))) NSString * const MTLLogStateErrorDomain = @"MTLLogStateErrorDomain";
extern "C" __attribute__((weak, visibility("default"))) NSString * const MTLTensorDomain = @"MTLTensorDomain";
extern "C" __attribute__((weak, visibility("default"))) NSString * const NSDeviceCertificationiPhonePerformanceGaming = @"NSDeviceCertificationiPhonePerformanceGaming";
extern "C" __attribute__((weak, visibility("default"))) NSString * const NSProcessInfoPerformanceProfileDidChangeNotification = @"NSProcessInfoPerformanceProfileDidChangeNotification";
extern "C" __attribute__((weak, visibility("default"))) NSString * const NSProcessPerformanceProfileDefault = @"NSProcessPerformanceProfileDefault";
extern "C" __attribute__((weak, visibility("default"))) NSString * const NSProcessPerformanceProfileSustained = @"NSProcessPerformanceProfileSustained";

// Godot 4.7's SDL HID wrapper references APIs newer than the iOS SDL backend
// bundled by this branch. Keep the unsupported queries as weak fallbacks so a
// future SDL implementation can replace them without creating duplicate symbols.
extern "C" __attribute__((weak, visibility("default"))) struct hid_device_info *PLATFORM_hid_get_device_info(struct hid_device_ *) {
    return nullptr;
}
extern "C" __attribute__((weak, visibility("default"))) int PLATFORM_hid_get_input_report(struct hid_device_ *, unsigned char *, size_t) {
    return -1;
}
extern "C" __attribute__((weak, visibility("default"))) int PLATFORM_hid_get_report_descriptor(struct hid_device_ *, unsigned char *, size_t) {
    return -1;
}
}
EOF

    xcrun --sdk "$sdk" clang++ -arch "$arch" "$min_flag" -fobjc-arc -c "$source" -o "$object"
    libtool -static -o "$output" "$object"
}

renios_enabled() {
    case "${AETHERKIRI_ENABLE_RENPY:-OFF}" in
        ON|TRUE|YES|1|on|true|yes) return 0 ;;
        *) return 1 ;;
    esac
}

renpy_device_gles_enabled() {
    case "${AETHERKIRI_RENPY_IOS_DEVICE_GLES:-OFF}" in
        ON|TRUE|YES|1|on|true|yes) return 0 ;;
        *) return 1 ;;
    esac
}

if renpy_device_gles_enabled; then
    if [[ "$SIMULATOR" == true || "$BUILD_TYPE_LOWER" != debug ]] || ! renios_enabled; then
        echo "Error: AETHERKIRI_RENPY_IOS_DEVICE_GLES requires a Debug device build with Ren'Py enabled." >&2
        exit 1
    fi
    python3 "$PROJECT_ROOT/tools/build_godot_ios_device_template.py" verify \
        --template "$GODOT_EXPORT_TEMPLATE"
fi

renios_link_enabled() {
    case "${AETHERKIRI_RENPY_RENIOS_LINK:-ON}" in
        ON|TRUE|YES|1|on|true|yes) return 0 ;;
        *) return 1 ;;
    esac
}

renios_prototype_root() {
    [[ -n "$RENPY_MOBILE_ROOT" ]] || return 1
    local root="$RENPY_MOBILE_ROOT/renios/prototype"
    [[ -d "$root" ]] || return 1
    [[ -d "$root/prebuilt" ]] || return 1
    printf '%s\n' "$root"
}

renios_configuration() {
    if [[ "${SIMULATOR:-false}" == true ]]; then
        printf 'debug\n'
    else
        # Upstream Renios debug archives contain simulator slices only;
        # release archives contain the device arm64 slice for either app mode.
        printf 'release\n'
    fi
}

renios_prebuilt_root() {
    local prototype
    prototype="$(renios_prototype_root 2>/dev/null || true)"
    [[ -n "$prototype" ]] || return 1
    # Renios release archives are device arm64 only.  The debug archive is a
    # universal simulator/device slice, so use it for every simulator export
    # even when the surrounding Godot export is a release configuration.
    local configuration
    configuration="$(renios_configuration)"
    local prebuilt="$prototype/prebuilt/$configuration"
    if [[ ! -d "$prebuilt" ]]; then
        echo "Error: Renios prebuilt directory is missing: $prebuilt" >&2
        return 1
    fi
    printf '%s\n' "$prebuilt"
}

renios_archive_is_excluded() {
    case "$(basename "$1")" in
        # SDL2main owns the UIKit/SDL application entrypoint in the official
        # prototype.  Godot's application must supply the only entrypoint.
        libSDL2main.a|libSDL2_test.a|libSDL3main.a|libSDL3_test.a|libmockrt.a) return 0 ;;
        *) return 1 ;;
    esac
}

collect_renios_archives() {
    local prebuilt="$1"
    local archive
    [[ -d "$prebuilt" ]] || return 1
    # Keep the runtime roots first for deterministic archive inspection, then
    # append every transitive archive shipped by Renios.  The latter is the
    # complete native dependency closure for the selected SDK/configuration.
    local root_name
    for root_name in librenpython.a librenpy.a libpython3.12.a libSDL2.a libSDL2_image.a; do
        archive="$prebuilt/$root_name"
        [[ -f "$archive" ]] || {
            echo "Error: Renios runtime archive is missing: $archive" >&2
            return 1
        }
        renios_archive_is_excluded "$archive" || printf '%s\n' "$archive"
    done
    while IFS= read -r archive; do
        [[ -f "$archive" ]] || continue
        renios_archive_is_excluded "$archive" && continue
        case "$(basename "$archive")" in
            librenpython.a|librenpy.a|libpython3.12.a|libSDL2.a|libSDL2_image.a) ;;
            *) printf '%s\n' "$archive" ;;
        esac
    done < <(find "$prebuilt" -maxdepth 1 -type f -name 'lib*.a' | sort)
}

renios_archive_names() {
    local prebuilt="$1"
    collect_renios_archives "$prebuilt" | xargs -n1 basename | paste -sd, -
}

renios_launcher_probe() {
    renios_enabled || return 0
    renios_link_enabled || {
        echo "Error: Ren'Py enabled app builds require AETHERKIRI_RENPY_RENIOS_LINK=ON; disabling native linking cannot produce a runnable game." >&2
        return 1
    }
    local prebuilt arch=arm64
    [[ "$SIMULATOR" == true ]] && arch="$SIMULATOR_ARCH"
    prebuilt="$(renios_prebuilt_root)"
    collect_renios_archives "$prebuilt" >/dev/null
    [[ -d "$RENPY_MOBILE_ROOT/renios/prototype/Frameworks/MetalANGLE.xcframework" ]] || {
        echo "Error: Renios MetalANGLE.xcframework is missing." >&2
        return 1
    }
    python3 "$PROJECT_ROOT/tools/validate_renpy_mobile_payload.py" \
        --platform ios --arch "$arch" --sdk "$IOS_SDK" \
        --library "$prebuilt/librenpython.a" --private-root "$RENPY_RENIOS_BASE"
}

renios_metalangle_framework() {
    local arch=arm64 framework_source
    [[ "$SIMULATOR" == true ]] && arch="$SIMULATOR_ARCH"
    framework_source="$RENPY_MOBILE_ROOT/renios/prototype/Frameworks/MetalANGLE.xcframework"
    python3 - "$framework_source" "$IOS_SDK" "$arch" <<'PY'
import pathlib, plistlib, sys
root=pathlib.Path(sys.argv[1]); simulator=sys.argv[2]=='iphonesimulator'; arch=sys.argv[3]
info=plistlib.loads((root/'Info.plist').read_bytes())
for library in info['AvailableLibraries']:
    if (library.get('SupportedPlatform') == 'ios' and
        (library.get('SupportedPlatformVariant') == 'simulator') == simulator and
        arch in library['SupportedArchitectures']):
        print(root/library['LibraryIdentifier']/library['LibraryPath'])
        break
else:
    raise SystemExit('MetalANGLE has no matching iOS SDK/architecture slice')
PY
}

build_renios_runtime_framework() {
    renios_enabled || return 0
    local prebuilt arch=arm64 metalangle prototype sdk_path
    [[ "$SIMULATOR" == true ]] && arch="$SIMULATOR_ARCH"
    prebuilt="$(renios_prebuilt_root)"
    metalangle="$(renios_metalangle_framework)"
    [[ -f "$metalangle/MetalANGLE" ]] || { echo "Error: Missing MetalANGLE framework slice." >&2; return 1; }
    mkdir -p "$RENPY_FRAMEWORK_OUTPUT"
    local export_list="$CMAKE_BUILD_DIR/renpy-native/exports.txt" symbol
    : > "$export_list"
    for symbol in bootstrap bind_window init tick frame input pause resume shutdown text_input_state set_surface_size; do
        printf '_renpy_mobile_%s\n' "$symbol" >> "$export_list"
    done
    local force_load_args=() archive
    while IFS= read -r archive; do
        force_load_args+=(-Xlinker -force_load -Xlinker "$archive")
    done < <(collect_renios_archives "$prebuilt")
    local minimum_flag="-miphoneos-version-min=${IOS_MIN_VERSION:-16.0}"
    [[ "$SIMULATOR" == true ]] && minimum_flag="-mios-simulator-version-min=${IOS_MIN_VERSION:-16.0}"
    prototype="$(renios_prototype_root)"
    sdk_path="$(xcrun --sdk "$IOS_SDK" --show-sdk-path)"
    local support_objects=() support_name support_source support_object
    # Ren'Py's iOS init code discovers these original Renios classes through
    # pyobjus. They are app sources upstream, so the prebuilt archives omit
    # them. Keep them in the runtime framework without its main.c entrypoint.
    for support_name in Log IAPHelper; do
        support_source="$prototype/$support_name.m"
        support_object="$CMAKE_BUILD_DIR/renpy-native/$support_name.o"
        [[ -f "$support_source" ]] || {
            echo "Error: Required Renios support source is missing: $support_source" >&2
            return 1
        }
        xcrun --sdk "$IOS_SDK" clang -arch "$arch" -isysroot "$sdk_path" \
            "$minimum_flag" -fobjc-arc -fmodules -include UIKit/UIKit.h \
            -c "$support_source" -o "$support_object"
        support_objects+=("$support_object")
    done
    # Keep Ren'Py's Python/SDL/FFmpeg symbols inside a separate two-level
    # namespace. They must not replace the host's vcpkg library definitions.
    # The builtin Python extension table requires its archive objects to stay.
    # Load each archive explicitly: modern Apple ld rejects -noall_load, and
    # a global -all_load switch also affects unrelated libraries on this link.
    xcrun --sdk "$IOS_SDK" clang++ -arch "$arch" -isysroot "$sdk_path" "$minimum_flag" -dynamiclib \
        "${support_objects[@]}" \
        "${force_load_args[@]}" \
        -Wl,-exported_symbols_list,"$export_list" \
        -Wl,-install_name,"@rpath/$RENPY_FRAMEWORK_NAME.framework/$RENPY_FRAMEWORK_NAME" \
        -Wl,-rpath,@loader_path/.. \
        -F"$(dirname "$metalangle")" -framework MetalANGLE \
        -framework Foundation -framework UIKit -framework QuartzCore \
        -framework CoreAudio -framework AudioToolbox -framework AVFoundation \
        -framework CoreVideo -framework CoreMedia -framework VideoToolbox \
        -framework CoreGraphics -framework CoreFoundation -framework GameController \
        -framework CoreMotion -framework Security -framework SystemConfiguration \
        -framework Metal -framework StoreKit -liconv -lz -lbz2 \
        -o "$RENPY_FRAMEWORK_OUTPUT/$RENPY_FRAMEWORK_NAME"
    local class_symbols="$CMAKE_BUILD_DIR/renpy-native/support-class-symbols.txt" class_symbol
    xcrun nm -U -arch "$arch" "$RENPY_FRAMEWORK_OUTPUT/$RENPY_FRAMEWORK_NAME" > "$class_symbols"
    for support_name in Log IAPHelper; do
        class_symbol='_OBJC_CLASS_$_'"$support_name"
        awk -v symbol="$class_symbol" '$NF == symbol { found=1 } END { exit !found }' "$class_symbols" || {
            echo "Error: Ren'Py runtime framework lacks required Objective-C class $support_name." >&2
            return 1
        }
    done
    python3 - "$RENPY_FRAMEWORK_OUTPUT/Info.plist" "$RENPY_FRAMEWORK_NAME" "$IOS_SDK" <<'PY'
import pathlib, plistlib, sys
plist={'CFBundleIdentifier':'org.aetherkiri.renpy-runtime', 'CFBundleExecutable':sys.argv[2],
       'CFBundleName':sys.argv[2], 'CFBundlePackageType':'FMWK', 'CFBundleVersion':'1',
       'CFBundleShortVersionString':'8.5.3', 'MinimumOSVersion':'16.0',
       'CFBundleSupportedPlatforms':['iPhoneSimulator' if sys.argv[3]=='iphonesimulator' else 'iPhoneOS']}
pathlib.Path(sys.argv[1]).write_bytes(plistlib.dumps(plist))
PY
    codesign --force --sign - "$RENPY_FRAMEWORK_OUTPUT"
    python3 "$PROJECT_ROOT/tools/validate_renpy_mobile_payload.py" \
        --platform ios --arch "$arch" --sdk "$IOS_SDK" --executable \
        --library "$RENPY_FRAMEWORK_OUTPUT/$RENPY_FRAMEWORK_NAME"
    xcrun otool -L "$RENPY_FRAMEWORK_OUTPUT/$RENPY_FRAMEWORK_NAME" \
        > "$CMAKE_BUILD_DIR/renpy-native/linked-libraries.txt"
}

stage_renios_ios_resources() {
    local export_root="$1"
    if ! renios_enabled; then
        return 0
    fi
    local prototype
    prototype="$(renios_prototype_root 2>/dev/null || true)"
    if [[ -z "$prototype" ]]; then
        echo "Error: Ren'Py enabled iOS build is missing the rebuilt Renios support root." >&2
        return 1
    fi

    local app_root="$export_root/Aether"
    local resource_root="$app_root/renios"
    local resource_source="$prototype"
    mkdir -p "$resource_root"
    # These are the official Renios app resources.  Do not copy main.c,
    # prototype.xcodeproj, or any source file: this export remains a Godot
    # application and has one host-owned lifecycle.
    local item
    for item in "Launch Screen.storyboard" LaunchImage-background.png LaunchImage-foreground.png Info.plist Media.xcassets; do
        if [[ -e "$resource_source/$item" ]]; then
            rm -rf "$resource_root/$item"
            cp -R "$resource_source/$item" "$resource_root/"
        fi
    done
    if [[ -d "$RENPY_RENIOS_BASE" ]]; then
        rm -rf "$resource_root/base"
        cp -R "$RENPY_RENIOS_BASE" "$resource_root/base"
    elif [[ -d "$resource_source/base" ]]; then
        rm -rf "$resource_root/base"
        cp -R "$resource_source/base" "$resource_root/base"
    fi

    # Embed the selected real framework slice. Only the isolated runtime links
    # MetalANGLE; Godot's own GL imports must resolve to Apple's OpenGLES.
    local metalangle
    metalangle="$(renios_metalangle_framework)"
    [[ -f "$metalangle/MetalANGLE" ]] || { echo "Error: Missing MetalANGLE framework slice." >&2; return 1; }
    mkdir -p "$app_root/Frameworks"
    rm -rf "$app_root/Frameworks/MetalANGLE.xcframework" "$app_root/Frameworks/MetalANGLE.framework"
    cp -R "$metalangle" "$app_root/Frameworks/MetalANGLE.framework"
    [[ -d "$RENPY_FRAMEWORK_OUTPUT" ]] || { echo "Error: Ren'Py runtime framework was not built." >&2; return 1; }
    mkdir -p "$app_root/Frameworks"
    rm -rf "$app_root/Frameworks/$RENPY_FRAMEWORK_NAME.framework"
    cp -R "$RENPY_FRAMEWORK_OUTPUT" "$app_root/Frameworks/"

    local prebuilt
    prebuilt="$(renios_prebuilt_root 2>/dev/null || true)"
    if [[ -z "$prebuilt" ]]; then
        echo "Error: Renios prebuilt closure is unavailable." >&2
        return 1
    fi
    {
        printf 'Renios archive: %s\n' "$RENPY_MOBILE_ROOT"
        if [[ -f "$RENPY_MOBILE_ROOT/renios/.aetherkiri-sha256" ]]; then
            printf 'Renios archive SHA-256: %s\n' "$(cat "$RENPY_MOBILE_ROOT/renios/.aetherkiri-sha256")"
        fi
        printf 'Configuration: %s\n' "$(renios_configuration)"
        printf 'Isolated runtime framework: %s.framework\n' "$RENPY_FRAMEWORK_NAME"
        printf 'Framework static inputs: %s\n' "$(renios_archive_names "$prebuilt")"
        printf 'Excluded archives: libSDL2main.a,libSDL2_test.a,libSDL3main.a,libSDL3_test.a,libmockrt.a (host entrypoint/test/Linux SDK shim)\n'
        if [[ -d "$resource_root/base" ]]; then
            printf 'Base resources: bundled\n'
        else
            printf 'Base resources: none (Renios archive is game-agnostic)\n'
        fi
        printf 'Host entrypoint: Godot (Renios main.c intentionally omitted)\n'
        printf 'Native lifecycle: framework linked and export validated\n'
        printf 'Gameplay verification: requires device/simulator execution\n'
    } > "$resource_root/renios-manifest.txt"
}

combine_ios_static_extension() {
    local output="$1"
    local triplet="$2"
    # Validate the lifecycle fork and its Python resources before staging the
    # host extension. Never invoke the process-owning launcher_main entrypoint.
    renios_launcher_probe
    local vcpkg_triplet_root="$CMAKE_BUILD_DIR/vcpkg_installed/$triplet"
    local vcpkg_lib_dir="$vcpkg_triplet_root/lib"
    if [[ "$BUILD_TYPE_LOWER" == debug && -d "$vcpkg_triplet_root/debug/lib" ]]; then
        vcpkg_lib_dir="$vcpkg_triplet_root/debug/lib"
    fi
    local cubism_package_root="${AETHERKIRI_INTERNAL_DIR:-$PROJECT_ROOT/packages/AetherInternal}"
    local cubism_core_lib="$cubism_package_root/third_party/cubism/Core/lib/ios/Release-iphoneos/libLive2DCubismCore.a"
    local godot_cpp_arch="arm64"
    local godot_cpp_lib=""
    local rfvp_rust_target="aarch64-apple-ios"
    local libs=(
        "$CMAKE_BUILD_DIR/bridge/godot_extension/libaether_kiri_godot.a"
        "$CMAKE_BUILD_DIR/bridge/onscripter_runtime/libaether_onscripter_runtime.a"
        "$CMAKE_BUILD_DIR/abi/libengine_api.a"
        "$CMAKE_BUILD_DIR/bridge/krkr2_runtime/libaether_krkr2_runtime.a"
        "$CMAKE_BUILD_DIR/packages/AetherKrkr/core/base/libcore_base_module.a"
        "$CMAKE_BUILD_DIR/packages/AetherKrkr/core/environ/libcore_environ_module.a"
        "$CMAKE_BUILD_DIR/packages/AetherKrkr/core/extension/libcore_extension_module.a"
        "$CMAKE_BUILD_DIR/packages/AetherKrkr/core/movie/libcore_movie_module.a"
        "$CMAKE_BUILD_DIR/packages/AetherKrkr/core/plugin/libcore_plugin_module.a"
        "$CMAKE_BUILD_DIR/packages/AetherKrkr/core/sound/libcore_sound_module.a"
        "$CMAKE_BUILD_DIR/packages/AetherKrkr/core/tjs2/libtjs2.a"
        "$CMAKE_BUILD_DIR/packages/AetherKrkr/core/utils/libcore_utils_module.a"
        "$CMAKE_BUILD_DIR/packages/AetherKrkr/core/visual/libcore_visual_module.a"
        "$CMAKE_BUILD_DIR/packages/AetherKrkr/core/visual/simd/libtvpgl_simd.a"
        "$CMAKE_BUILD_DIR/packages/AetherKrkr/plugins/libkrkr2plugin.a"
        # krkr2plugin links the Hxv4 provider as a static dependency, but
        # static archives do not contain their dependent archive members.
        # Merge it explicitly so pluginAnchors.cpp's registration symbol is
        # present in the archive consumed by Godot's iOS exporter.
        "$CMAKE_BUILD_DIR/packages/AetherKrkr/plugins/Crypt/hxv4/libhxv4_decoder.a"
        "$CMAKE_BUILD_DIR/packages/AetherKrkr/plugins/extkagparser/libextkagparser.a"
        "$CMAKE_BUILD_DIR/packages/AetherKrkr/plugins/kagparserex/libkagparserex.a"
        "$CMAKE_BUILD_DIR/packages/AetherKrkr/plugins/layerex_draw/liblayerExDraw.a"
        "$CMAKE_BUILD_DIR/packages/AetherKrkr/plugins/motionplayer/libmotionplayer.a"
        "$CMAKE_BUILD_DIR/packages/AetherKrkr/plugins/psbfile/libpsbfile.a"
        "$CMAKE_BUILD_DIR/packages/AetherKrkr/plugins/psdfile/libpsdfile.a"
        "$CMAKE_BUILD_DIR/packages/AetherKrkr/plugins/psdfile/psdparse/psdparse/libpsdparse.a"
        "$CMAKE_BUILD_DIR/packages/AetherKrkr/plugins/libCubismFramework.a"
        "$CMAKE_BUILD_DIR/packages/AetherKrkr/external/libbpg/liblibbpg.a"
    )

    local siglus_runtime_lib="$CMAKE_BUILD_DIR/bridge/siglus_runtime/libaether_siglus_runtime.a"
    if [[ -f "$siglus_runtime_lib" ]]; then
        libs+=("$siglus_runtime_lib")
    fi
    local renpy_runtime_lib="$CMAKE_BUILD_DIR/bridge/renpy_runtime/libaether_renpy_runtime.a"
    if [[ -f "$renpy_runtime_lib" ]]; then
        # CMake's private archive dependency is not propagated by Godot's
        # static iOS exporter; merge the provider registration object here so
        # the guarded adapter boundary is present in the final app.
        libs+=("$renpy_runtime_lib")
    fi
    while IFS= read -r siglus_vm_lib; do
        if [[ -n "$siglus_vm_lib" && -f "$siglus_vm_lib" ]]; then
            libs+=("$siglus_vm_lib")
        fi
    done < <(find "$CMAKE_BUILD_DIR/siglus-rs-target" -name 'libsiglus_scene_vm.a' 2>/dev/null || true)

    if [[ "$triplet" == "x64-ios-simulator" ]]; then
        godot_cpp_arch="x86_64"
        rfvp_rust_target="x86_64-apple-ios"
        cubism_core_lib="$cubism_package_root/third_party/cubism/Core/lib/ios/Release-iphonesimulator-x86_64/libLive2DCubismCore.a"
    elif [[ "$triplet" == "arm64-ios-simulator" ]]; then
        rfvp_rust_target="aarch64-apple-ios-sim"
        cubism_core_lib="$cubism_package_root/third_party/cubism/Core/lib/ios/Release-iphonesimulator-arm64/libLive2DCubismCore.a"
    fi
    godot_cpp_lib="$(resolve_ios_godot_cpp_lib "$vcpkg_triplet_root" "$godot_cpp_arch" "$BUILD_TYPE_LOWER" || true)"
    if [[ ! -f "$godot_cpp_lib" ]]; then
        echo "Error: missing Godot C++ iOS archive for $BUILD_TYPE_LOWER build ($godot_cpp_arch)." >&2
        echo "       Expected an archive matching: $vcpkg_triplet_root/{lib,debug/lib}/libgodot-cpp.ios.*.$godot_cpp_arch.a" >&2
        exit 1
    fi
    libs=("$godot_cpp_lib" "${libs[@]}")
    libs+=("$cubism_core_lib")
    if [[ -f "$CMAKE_BUILD_DIR/bridge/rfvp_runtime/libaether_rfvp_runtime.a" ]]; then
        libs+=(
            "$CMAKE_BUILD_DIR/bridge/rfvp_runtime/libaether_rfvp_runtime.a"
            "$CMAKE_BUILD_DIR/bridge/rfvp_runtime/prepared/target/$rfvp_rust_target/$BUILD_TYPE_LOWER/librfvp.a"
        )
    fi

    while IFS= read -r lib; do
        libs+=("$lib")
    done < <(find "$vcpkg_lib_dir" -maxdepth 1 -name 'lib*.a' \
        ! -name 'libgodot-cpp*.a' \
        ! -name 'libSDL2main.a' | sort)

    # Some vcpkg ports (e.g. tiff on iOS) install static libraries as
    # <name>.framework bundles instead of lib<name>.a. Merge their archive
    # binaries too, otherwise consumers of those ports fail to link.
    while IFS= read -r framework; do
        fw_name="$(basename "$framework" .framework)"
        fw_binary="$framework/Versions/Current/$fw_name"
        if [[ ! -e "$fw_binary" ]]; then
            fw_binary="$framework/$fw_name"
        fi
        if [[ -f "$fw_binary" && "$(head -c 8 "$fw_binary" 2>/dev/null)" == '!<arch>'* ]]; then
            libs+=("$fw_binary")
        else
            echo "warning: skipping non-static framework: $framework" >&2
        fi
    done < <(find "$vcpkg_lib_dir" -maxdepth 1 -name '*.framework' | sort)

    local existing_libs=()
    local lib
    for lib in "${libs[@]}"; do
        if [[ -f "$lib" ]]; then
            existing_libs+=("$lib")
        else
            echo "warning: skipping missing optional static library: $lib" >&2
        fi
    done

    local tmp
    tmp="$(mktemp /tmp/aetherkiri-ios-static.XXXXXX).a"
    libtool -static -o "$tmp" "${existing_libs[@]}"
    mv "$tmp" "$output"
}

stage_force_load_plugin_archives() {
    local destination="$1"
    local source
    local resolved
    mkdir -p "$destination"
    for source in "${FORCE_LOAD_PLUGIN_SOURCES[@]}"; do
        resolved="$source"
        if [[ ! -f "$resolved" ]]; then
            resolved="$CMAKE_BUILD_DIR/$source"
        fi
        if [[ ! -f "$resolved" ]]; then
            resolved="$PROJECT_ROOT/$source"
        fi
        if [[ ! -f "$resolved" && "$source" == vcpkg_installed/*/lib/libSDL2.a ]]; then
            resolved="$CMAKE_BUILD_DIR/vcpkg_installed/$VCPKG_TRIPLET_DIR/debug/lib/libSDL2d.a"
            [[ -f "$resolved" ]] || resolved="$CMAKE_BUILD_DIR/vcpkg_installed/$VCPKG_TRIPLET_DIR/debug/lib/libSDL2.a"
        fi
        if [[ ! -f "$resolved" ]]; then
            echo "Error: Required force-loaded iOS archive is missing: $source" >&2
            return 1
        fi
        cp -f "$resolved" "$destination/$(basename "$source")"
    done
}

verify_exported_simulator_template_arch() {
    local export_root="$1"
    local arch="$2"
    python3 "$PROJECT_ROOT/tools/build_godot_ios_simulator_template.py" verify \
        --template "$GODOT_EXPORT_TEMPLATE" --arch "$arch" --exported-dir "$export_root" \
        > "$export_root/godot-simulator-template-evidence.json"
}

verify_exported_renpy_device_template() {
    local export_root="$1"
    python3 "$PROJECT_ROOT/tools/build_godot_ios_device_template.py" verify \
        --template "$GODOT_EXPORT_TEMPLATE" --exported-dir "$export_root" \
        > "$export_root/godot-device-template-evidence.json"
}

stage_ios_runtime_fonts() {
    local export_root="$1"
    local app_source_dir="$export_root/Aether"
    local font_dir="$app_source_dir/fonts"

    mkdir -p "$font_dir"
    if [[ -f "$RUNTIME_CJK_FONT_SOURCE" ]]; then
        cp -f "$RUNTIME_CJK_FONT_SOURCE" "$app_source_dir/default.otf"
        cp -f "$RUNTIME_CJK_FONT_SOURCE" "$font_dir/default.otf"
    else
        echo "Warning: runtime CJK font missing: $RUNTIME_CJK_FONT_SOURCE" >&2
    fi
    if [[ -f "$RUNTIME_SYMBOL_FONT_SOURCE" ]]; then
        cp -f "$RUNTIME_SYMBOL_FONT_SOURCE" "$font_dir/symbols.ttf"
    else
        echo "Warning: runtime symbol font missing: $RUNTIME_SYMBOL_FONT_SOURCE" >&2
    fi
}

patch_ios_runtime_font_resources() {
    local project_file="$1"
    if [[ ! -f "$project_file" ]]; then
        return
    fi
    if grep -Fq 'A3F001000000000000000002 /* default.otf */' "$project_file"; then
        return
    fi

    perl -0pi -e 's@(/\* Begin PBXBuildFile section \*/\n)@$1\t\tA3F001000000000000000001 /* default.otf in Resources */ = {isa = PBXBuildFile; fileRef = A3F001000000000000000002 /* default.otf */; };\n\t\tA3F001000000000000000003 /* fonts in Resources */ = {isa = PBXBuildFile; fileRef = A3F001000000000000000004 /* fonts */; };\n@' "$project_file"
    perl -0pi -e 's@(/\* Begin PBXFileReference section \*/\n)@$1\t\tA3F001000000000000000002 /* default.otf */ = {isa = PBXFileReference; lastKnownFileType = file; path = default.otf; sourceTree = "<group>"; };\n\t\tA3F001000000000000000004 /* fonts */ = {isa = PBXFileReference; lastKnownFileType = folder; path = fonts; sourceTree = "<group>"; };\n@' "$project_file"
    perl -0pi -e 's@(\t\tD0BCFE4118AEBDA2004A7AAE /\* Aether \*/ = \{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = \(\n)@$1\t\t\t\tA3F001000000000000000002 /* default.otf */,\n\t\t\t\tA3F001000000000000000004 /* fonts */,\n@' "$project_file"
    perl -0pi -e 's@(\t\tD0BCFE3218AEBDA2004A7AAE /\* Resources \*/ = \{\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = \(\n)@$1\t\t\t\tA3F001000000000000000001 /* default.otf in Resources */,\n\t\t\t\tA3F001000000000000000003 /* fonts in Resources */,\n@' "$project_file"
}

patch_ios_renios_resources() {
    local project_file="$1"
    local export_root="$2"
    local resource_dir="$export_root/Aether/renios"
    local framework="$export_root/Aether/Frameworks/MetalANGLE.framework"
    [[ -f "$project_file" ]] || return 0
    [[ -d "$resource_dir" ]] || return 0

    # Add the Renios resources as a folder reference.  This keeps the
    # original names/relative paths intact while avoiding the prototype's
    # application-entrypoint source files.
    if ! grep -Fq 'A3F002000000000000000003 /* renios in Resources */' "$project_file"; then
        perl -0pi -e 's@(/\* Begin PBXBuildFile section \*/\n)@$1\t\tA3F002000000000000000003 /* renios in Resources */ = {isa = PBXBuildFile; fileRef = A3F002000000000000000004 /* renios */; };\n@' "$project_file"
        perl -0pi -e 's@(/\* Begin PBXFileReference section \*/\n)@$1\t\tA3F002000000000000000004 /* renios */ = {isa = PBXFileReference; lastKnownFileType = folder; path = renios; sourceTree = "<group>"; };\n@' "$project_file"
        perl -0pi -e 's@(\t\tD0BCFE4118AEBDA2004A7AAE /\* Aether \*/ = \{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = \(\n)@$1\t\t\t\tA3F002000000000000000004 /* renios */,\n@' "$project_file"
        perl -0pi -e 's@(\t\tD0BCFE3218AEBDA2004A7AAE /\* Resources \*/ = \{\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = \(\n)@$1\t\t\t\tA3F002000000000000000003 /* renios in Resources */,\n@' "$project_file"
        if ! grep -Fq 'A3F002000000000000000004 /* renios */,' "$project_file"; then
            # Godot's object IDs are stable in current exports, but retain a
            # semantic fallback for a future exporter that renumbers them.
            perl -0pi -e 's@(\n\t\t[0-9A-F]+ /\* [^*]+ \*/ = \{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = \(\n)@$1\t\t\t\tA3F002000000000000000004 /* renios */,\n@'s "$project_file"
        fi
        if ! grep -Fq 'A3F002000000000000000003 /* renios in Resources */,' "$project_file"; then
            perl -0pi -e 's@(\n\t\t[0-9A-F]+ /\* [^*]+ \*/ = \{\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = \(\n)@$1\t\t\t\tA3F002000000000000000003 /* renios in Resources */,\n@'s "$project_file"
        fi
    fi

    # The native framework records its own MetalANGLE load command. Embed the
    # selected slice without adding MetalANGLE to the host's link inputs.
    python3 "$PROJECT_ROOT/tools/patch_renpy_ios_runtime_project.py" "$project_file" \
        "$export_root/Aether/Frameworks/$RENPY_FRAMEWORK_NAME.framework" \
        --metalangle-framework "$framework"

}

patch_ios_export_project() {
    local project_file="$1/project.pbxproj"
    local export_root
    export_root="$(dirname "$1")"
    local dummy_cpp="$export_root/Aether/dummy.cpp"
    local info_plist="$export_root/Aether/Aether-Info.plist"
    local arch="$2"
    local export_build_type="$3"
    local flags
    flags='$(LD_CLASSIC_$(XCODE_VERSION_ACTUAL)) -Wl,-U,_aether_kiri_library_init'
    flags+=" -Wl,-force_load,Aether/bin/$GODOT_TRIPLET_DIR/$IOS_SDK_COMPAT_ARCHIVE"
    local archive
    for archive in "${FORCE_LOAD_PLUGIN_ARCHIVES[@]}"; do
        flags+=" -Wl,-force_load,Aether/bin/$GODOT_TRIPLET_DIR/$archive"
    done
    flags+=' -liconv -framework Accelerate -framework AudioToolbox -framework AVFoundation -framework CoreAudio -framework CoreBluetooth -framework CoreFoundation -framework CoreHaptics -framework CoreMedia -framework CoreMotion -framework CoreVideo -framework CoreServices -framework GameController -framework ImageIO -framework VideoToolbox -framework CoreGraphics -framework QuartzCore -framework Metal -framework MetalKit -framework OpenGLES -framework Security -framework StoreKit -framework SystemConfiguration -framework MobileCoreServices'
    if renios_enabled; then
        # The resource staging step places this official dynamic framework in
        # Aether/Frameworks and the PBX patch embeds it in the app bundle.
        flags+=" -F Aether/Frameworks -Wl,-needed_framework,$RENPY_FRAMEWORK_NAME -Wl,-rpath,@executable_path/Frameworks"
    fi

    if [[ -f "$project_file" ]]; then
        FLAGS="$flags" perl -0pi -e 's/OTHER_LDFLAGS = "[^"]*";/"OTHER_LDFLAGS = \"" . $ENV{FLAGS} . "\";"/eg' "$project_file"
        # Automatic signing archives with a development identity first, then
        # Xcode re-signs the exported archive for App Store distribution.
        # Godot's explicit Apple Distribution value conflicts with Automatic.
        perl -0pi -e 's/CODE_SIGN_IDENTITY = "Apple Distribution";/CODE_SIGN_IDENTITY = "Apple Development";/g' "$project_file"
        if [[ "$arch" == "x86_64" ]]; then
            perl -0pi -e 's/ARCHS = "arm64";/ARCHS = "x86_64";/g' "$project_file"
            perl -0pi -e 's/VALID_ARCHS = "arm64 x86_64";/VALID_ARCHS = "x86_64";/g' "$project_file"
        else
            perl -0pi -e 's/ARCHS = "x86_64";/ARCHS = "arm64";/g' "$project_file"
            perl -0pi -e 's/VALID_ARCHS = "x86_64";/VALID_ARCHS = "arm64";/g' "$project_file"
        fi
        stage_ios_runtime_fonts "$export_root"
        patch_ios_runtime_font_resources "$project_file"
        patch_ios_renios_resources "$project_file" "$export_root"
    fi
    if [[ -f "$dummy_cpp" ]] && ! grep -Fq '__swift_FORCE_LOAD_$_swift_Builtin_float' "$dummy_cpp"; then
        cat >> "$dummy_cpp" <<'EOF'

extern "C" void aether_kiri_swift_builtin_float_force_load(void) __asm("__swift_FORCE_LOAD_$_swift_Builtin_float");
extern "C" void aether_kiri_swift_builtin_float_force_load(void) {}
EOF
    fi
    if [[ -f "$info_plist" ]]; then
        local bluetooth_purpose
        bluetooth_purpose="Aether uses Bluetooth to connect game controllers that you choose to use."
        /usr/libexec/PlistBuddy -c 'Set :UIFileSharingEnabled true' "$info_plist" 2>/dev/null || \
            /usr/libexec/PlistBuddy -c 'Add :UIFileSharingEnabled bool true' "$info_plist"
        /usr/libexec/PlistBuddy -c 'Set :LSSupportsOpeningDocumentsInPlace true' "$info_plist" 2>/dev/null || \
            /usr/libexec/PlistBuddy -c 'Add :LSSupportsOpeningDocumentsInPlace bool true' "$info_plist"
        /usr/libexec/PlistBuddy -c 'Set :UIStatusBarHidden false' "$info_plist" 2>/dev/null || \
            /usr/libexec/PlistBuddy -c 'Add :UIStatusBarHidden bool false' "$info_plist"
        /usr/libexec/PlistBuddy -c 'Set :UIViewControllerBasedStatusBarAppearance false' "$info_plist" 2>/dev/null || \
            /usr/libexec/PlistBuddy -c 'Add :UIViewControllerBasedStatusBarAppearance bool false' "$info_plist"
        /usr/libexec/PlistBuddy -c 'Set :SKIncludeConsumableInAppPurchaseHistory true' "$info_plist" 2>/dev/null || \
            /usr/libexec/PlistBuddy -c 'Add :SKIncludeConsumableInAppPurchaseHistory bool true' "$info_plist"
        /usr/libexec/PlistBuddy \
            -c "Set :NSBluetoothAlwaysUsageDescription $bluetooth_purpose" \
            "$info_plist" 2>/dev/null || \
            /usr/libexec/PlistBuddy \
                -c "Add :NSBluetoothAlwaysUsageDescription string $bluetooth_purpose" \
                "$info_plist"
    fi
}

validate_renios_app() {
    renios_enabled || return 0
    local app="$1" arch="$2" sdk="$3"
    local framework="$app/Frameworks/$RENPY_FRAMEWORK_NAME.framework/$RENPY_FRAMEWORK_NAME"
    [[ -f "$framework" && -f "$app/Frameworks/MetalANGLE.framework/MetalANGLE" ]] || {
        echo "Error: The packaged app is missing its executable Ren'Py/MetalANGLE frameworks." >&2
        return 1
    }
    python3 "$PROJECT_ROOT/tools/validate_renpy_mobile_payload.py" \
        --platform ios --arch "$arch" --sdk "$sdk" --executable --library "$framework" \
        --private-root "$app/renios/base"
    local host_libraries runtime_libraries host_imports runtime_imports
    host_libraries="$(xcrun otool -L "$app/Aether")"
    runtime_libraries="$(xcrun otool -L "$framework")"
    grep -Fq "@rpath/$RENPY_FRAMEWORK_NAME.framework/$RENPY_FRAMEWORK_NAME" <<< "$host_libraries" || {
        echo "Error: The final app does not load its isolated Ren'Py framework." >&2
        return 1
    }
    if grep -Fq 'MetalANGLE.framework/MetalANGLE' <<< "$host_libraries"; then
        echo "Error: The host app directly links MetalANGLE and can bind Godot GL calls to Ren'Py's graphics context." >&2
        return 1
    fi
    grep -Fq '/OpenGLES.framework/OpenGLES' <<< "$host_libraries" || {
        echo "Error: The host app does not link its Apple OpenGLES backend." >&2
        return 1
    }
    grep -Fq 'MetalANGLE.framework/MetalANGLE' <<< "$runtime_libraries" || {
        echo "Error: The Ren'Py framework does not load its MetalANGLE backend." >&2
        return 1
    }
    if grep -Fq '/OpenGLES.framework/OpenGLES' <<< "$runtime_libraries"; then
        echo "Error: The Ren'Py framework also links Apple's incompatible OpenGLES backend." >&2
        return 1
    fi
    # Preserve the real linked image's undefined symbol bindings as build
    # evidence. The load-command gates above remain valid after stripping.
    host_imports="$(xcrun nm -m -u "$app/Aether")"
    runtime_imports="$(xcrun nm -m -u "$framework")"
    printf '%s\n' "$host_libraries" "$host_imports" > "$CMAKE_BUILD_DIR/renpy-native/host-linkage.txt"
    printf '%s\n' "$runtime_libraries" "$runtime_imports" > "$CMAKE_BUILD_DIR/renpy-native/runtime-linkage.txt"
    if grep -Eq '_gl[A-Za-z0-9_]+ .*\(from MetalANGLE\)' <<< "$host_imports" || \
       grep -Eq '_(egl|gl)[A-Za-z0-9_]+ .*\(from OpenGLES\)' <<< "$runtime_imports"; then
        echo "Error: The final GL/EGL imports bind to the other engine's graphics backend." >&2
        return 1
    fi
    echo "==> Actual host GL imports (Apple OpenGLES) and Ren'Py EGL/GL imports (MetalANGLE):"
    grep -E '_(egl|gl)[A-Za-z0-9_]+ .*\(from (MetalANGLE|OpenGLES)\)' <<< "$host_imports" || true
    grep -E '_(egl|gl)[A-Za-z0-9_]+ .*\(from (MetalANGLE|OpenGLES)\)' <<< "$runtime_imports" || true
    # Objective-C class names are process-global, even with two-level native
    # namespaces. The offscreen SDL build must exclude UIKit classes and prefix
    # its audio listener; otherwise it collides with Godot's host SDL backend.
    local runtime_symbols
    runtime_symbols="$(xcrun nm "$framework")"
    if grep -Eq '_OBJC_CLASS_\$_(SDL_|SDLEAGLContext|SDLInterruptionListener)' <<< "$runtime_symbols"; then
        echo "Error: Ren'Py's framework still contains host SDL Objective-C classes." >&2
        return 1
    fi
}

package_ios_unsigned_ipa() {
    local export_dir="$1"
    local build_type_lower="$2"
    local config_cap="Release"
    if [[ "$build_type_lower" == "debug" ]]; then
        config_cap="Debug"
    fi
    local xcodeproj="$export_dir/Aether.xcodeproj"
    if [[ ! -d "$xcodeproj" ]]; then
        echo "Error: Xcode project not found at $xcodeproj" >&2
        return 1
    fi
    if ! command -v xcodebuild >/dev/null 2>&1; then
        echo "Error: xcodebuild not found. Cannot package unsigned .ipa." >&2
        return 1
    fi
    echo "==> Building unsigned iOS App ($config_cap) for Sideloading..."
    mkdir -p "$export_dir/build"
    local xcodebuild_args=(
        -project "$xcodeproj" \
        -scheme Aether \
        -configuration "$config_cap" \
        -sdk iphoneos \
        CODE_SIGN_IDENTITY="" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO \
        CONFIGURATION_BUILD_DIR="$export_dir/build"
    )
    if [[ "$build_type_lower" == "release" ]]; then
        xcodebuild_args+=(
            DEPLOYMENT_POSTPROCESSING=YES
            STRIP_INSTALLED_PRODUCT=YES
            STRIP_STYLE=all
            COPY_PHASE_STRIP=YES
            GCC_GENERATE_DEBUGGING_SYMBOLS=NO
            STRIP_SWIFT_SYMBOLS=YES
            DEAD_CODE_STRIPPING=YES
            GCC_SYMBOLS_PRIVATE_EXTERN=YES
            UNEXPORTED_SYMBOLS_FILE="$PROJECT_ROOT/cmake/ios_unexported_symbols.txt"
            'OTHER_LDFLAGS=$(inherited) -Wl,-dead_strip'
        )
    else
        xcodebuild_args+=(
            DEPLOYMENT_POSTPROCESSING=NO
            STRIP_INSTALLED_PRODUCT=NO
            COPY_PHASE_STRIP=NO
            GCC_GENERATE_DEBUGGING_SYMBOLS=YES
            DEBUG_INFORMATION_FORMAT=dwarf
        )
    fi
    xcodebuild build "${xcodebuild_args[@]}"

    local app_binary="$export_dir/build/Aether.app/Aether"
    if [[ ! -f "$app_binary" ]]; then
        echo "Error: iOS app executable not found: $app_binary" >&2
        return 1
    fi
    if [[ "$build_type_lower" == "release" ]]; then
        echo "==> Removing non-runtime symbols from iOS Release executable..."
        "$PROJECT_ROOT/tools/strip_runtime_symbols.sh" macho-executable "$app_binary"
    fi
    validate_renios_app "$export_dir/build/Aether.app" arm64 iphoneos

    echo "==> Packaging into unsigned .ipa..."
    mkdir -p "$export_dir/Payload"
    rm -rf "$export_dir/Payload/Aether.app" "$export_dir/Aether-${config_cap}-Unsigned.ipa"
    cp -R "$export_dir/build/Aether.app" "$export_dir/Payload/"
    (cd "$export_dir" && zip -qry "Aether-${config_cap}-Unsigned.ipa" Payload)
    rm -rf "$export_dir/Payload" "$export_dir/build"
    echo "Unsigned IPA created: $export_dir/Aether-${config_cap}-Unsigned.ipa"
}

package_ios_simulator_app() {
    local export_dir="$1" config_cap=Release
    [[ "$BUILD_TYPE_LOWER" == debug ]] && config_cap=Debug
    local output_dir="$export_dir/build-simulator-$SIMULATOR_ARCH"
    xcodebuild build \
        -project "$export_dir/Aether.xcodeproj" -scheme Aether \
        -configuration "$config_cap" -sdk iphonesimulator \
        -destination 'generic/platform=iOS Simulator' \
        "ARCHS=$SIMULATOR_ARCH" ONLY_ACTIVE_ARCH=YES \
        DEVELOPMENT_TEAM="" \
        CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
        "CONFIGURATION_BUILD_DIR=$output_dir"
    [[ -s "$output_dir/Aether.app/Aether" ]] || {
        echo "Error: Xcode did not produce a runnable iOS simulator app." >&2
        return 1
    }
    validate_renios_app "$output_dir/Aether.app" "$SIMULATOR_ARCH" iphonesimulator
    while IFS= read -r framework; do codesign --force --sign - "$framework"; done \
        < <(find "$output_dir/Aether.app/Frameworks" -maxdepth 1 -type d -name '*.framework')
    codesign --force --sign - "$output_dir/Aether.app"
    codesign --verify --deep --strict "$output_dir/Aether.app"
    (cd "$output_dir" && zip -qry "Aether-$SIMULATOR_ARCH-Simulator.zip" Aether.app)
    echo "Runnable simulator app: $output_dir/Aether.app (device gameplay unverified)"
}

with_ios_only_gdextension() (
    local gdextension_file="$GODOT_APP_DIR/aether_kiri.gdextension"
    local presets_file="$GODOT_APP_DIR/export_presets.cfg"
    local project_file="$GODOT_APP_DIR/project.godot"
    local backup_dir
    backup_dir="$(mktemp -d /tmp/aetherkiri-ios-export.XXXXXX)"
    local backup_file="$backup_dir/aether_kiri.gdextension"

    cp -p "$gdextension_file" "$backup_file"
    cp -p "$presets_file" "$backup_dir/export_presets.cfg"
    if renpy_device_gles_enabled; then
        cp -p "$project_file" "$backup_dir/project.godot"
    fi
    restore_ios_export_inputs() {
        cp -p "$backup_file" "$gdextension_file"
        cp -p "$backup_dir/export_presets.cfg" "$presets_file"
        if [[ -f "$backup_dir/project.godot" ]]; then
            cp -p "$backup_dir/project.godot" "$project_file"
        fi
        rm -rf "$backup_dir"
    }
    # This subshell restores all modified inputs on successful export or failure,
    # without changing the caller's traps or committing temporary presets.
    trap restore_ios_export_inputs EXIT

    awk '
        BEGIN { skip = 0 }
        /^\[dependencies\]/ { skip = 1 }
        /^\[/ && $0 != "[dependencies]" { skip = 0 }
        skip && /^macos\./ { while (getline line && line !~ /^}/) {} ; next }
        !skip || !/^macos\./ { print }
    ' "$backup_file" | grep -v '^macos\.' > "$gdextension_file"

    # Godot reads custom_template from this preset, not GODOT_EXPORT_TEMPLATE.
    # Bind the same verified ZIP to the actual export, then restore the preset.
    if renpy_device_gles_enabled; then
        python3 "$PROJECT_ROOT/tools/build_godot_ios_device_template.py" profile \
            --presets-source "$backup_dir/export_presets.cfg" --presets-destination "$presets_file" \
            --project-source "$backup_dir/project.godot" --project-destination "$project_file" \
            --template "$GODOT_EXPORT_TEMPLATE"
    else
        python3 "$PROJECT_ROOT/tools/build_godot_ios_simulator_template.py" preset \
            --source "$backup_dir/export_presets.cfg" --destination "$presets_file" \
            --preset "$EXPORT_PRESET" --template "$GODOT_EXPORT_TEMPLATE" --mode "$BUILD_TYPE_LOWER"
    fi
    "$GODOT_BIN" --headless --path "$GODOT_APP_DIR" \
        "$EXPORT_MODE" "$EXPORT_PRESET" "$IOS_EXPORT_DIR/Aether.xcodeproj"
)

echo "==> Building native engine and Godot extension"
renios_launcher_probe
build_renios_runtime_framework
cmake_config_args=(
    -D "CMAKE_MAKE_PROGRAM=$CMAKE_MAKE_PROGRAM"
    -D "AETHERKIRI_ENABLE_INTERNAL=${AETHERKIRI_ENABLE_INTERNAL:-ON}"
    -D "AETHERKIRI_ENABLE_SOFTPAL_RUNTIME=${AETHERKIRI_ENABLE_SOFTPAL_RUNTIME:-OFF}"
    -D "AETHERKIRI_SOFTPAL_DIR=${AETHERKIRI_SOFTPAL_DIR:-$PROJECT_ROOT/packages/AetherSoftPal}"
    -D "AETHERKIRI_ENABLE_CODE_OBFUSCATION=${AETHERKIRI_ENABLE_CODE_OBFUSCATION:-OFF}"
    -D "AETHERKIRI_OBFUSCATOR_PLUGIN=${AETHERKIRI_OBFUSCATOR_PLUGIN:-}"
    -D "AETHERKIRI_OBFUSCATION_BUILD_ID=${AETHERKIRI_OBFUSCATION_BUILD_ID:-local}"
    -D "AETHERKIRI_ENABLE_RFVP=${AETHERKIRI_ENABLE_RFVP:-OFF}"
    -D "AETHERKIRI_ENABLE_RENPY=${AETHERKIRI_ENABLE_RENPY:-OFF}"
    -D "AETHERKIRI_RENPY_MOBILE_LIBRARY=$RENPY_MOBILE_ROOT/renios/prototype/prebuilt/$(renios_configuration)/librenpython.a"
    -D "AETHERKIRI_RENPY_PRIVATE_ROOT=$RENPY_RENIOS_BASE"
)
if [[ -n "${RFVP_CARGO:-}" ]]; then
    cmake_config_args+=(-D "RFVP_CARGO=$RFVP_CARGO")
fi
if [[ -n "${RFVP_RUSTC:-}" ]]; then
    cmake_config_args+=(-D "RFVP_RUSTC=$RFVP_RUSTC")
fi
if [[ "${SKIP_VCPKG_INSTALL:-}" == "1" ]]; then
    if [[ ! -d "$VCPKG_ROOT/installed/$VCPKG_TRIPLET_DIR" ]]; then
        echo "Error: SKIP_VCPKG_INSTALL=1 but prebuilt vcpkg triplet is missing: $VCPKG_ROOT/installed/$VCPKG_TRIPLET_DIR" >&2
        exit 1
    fi
    mkdir -p "$CMAKE_BUILD_DIR"
    rm -rf "$CMAKE_BUILD_DIR/vcpkg_installed"
    ln -s "$VCPKG_ROOT/installed" "$CMAKE_BUILD_DIR/vcpkg_installed"
    cmake_config_args+=(
        -D "VCPKG_MANIFEST_INSTALL=OFF"
        -D "VCPKG_INSTALLED_DIR=$CMAKE_BUILD_DIR/vcpkg_installed"
    )
fi

cmake --preset "$CMAKE_CONFIG_PRESET" --fresh "${cmake_config_args[@]}"
cmake --build --preset "$CMAKE_BUILD_PRESET" -- -j"$PARALLEL_JOBS"

mkdir -p "$GODOT_BIN_DIR"
cp -f "$CMAKE_BUILD_DIR/abi/libengine_api.a" "$GODOT_BIN_DIR/" 2>/dev/null || true
cp -f "$CMAKE_BUILD_DIR/bridge/godot_extension/libaether_kiri_godot.a" "$GODOT_BIN_DIR/" 2>/dev/null || true
build_ios_sdk_compat_archive "$GODOT_BIN_DIR/$IOS_SDK_COMPAT_ARCHIVE" "$VCPKG_TRIPLET_DIR"
stage_force_load_plugin_archives "$GODOT_BIN_DIR"
if [[ -f "$CMAKE_BUILD_DIR/bridge/godot_extension/libaether_kiri_godot.a" ]]; then
    combine_ios_static_extension "$GODOT_BIN_DIR/libaether_kiri_godot.a" "$VCPKG_TRIPLET_DIR"
fi

if [[ ! -x "$GODOT_BIN" ]]; then
    if [[ "$PACKAGE_IPA" == true || "$SIMULATOR" == true ]]; then
        echo "Error: Godot not found at $GODOT_BIN; cannot package an iOS app." >&2
        exit 1
    fi
    echo "Warning: Godot not found at $GODOT_BIN; native libraries were staged only." >&2
elif [[ ! -f "$GODOT_EXPORT_TEMPLATE" ]]; then
    if [[ "$PACKAGE_IPA" == true || "$SIMULATOR" == true ]]; then
        echo "Error: Godot iOS export template missing at $GODOT_EXPORT_TEMPLATE; cannot package an iOS app." >&2
        exit 1
    fi
    echo "Warning: Godot iOS export template missing at $GODOT_EXPORT_TEMPLATE; native libraries were staged only." >&2
else
    echo "==> Exporting Godot iOS project"
    mkdir -p "$IOS_EXPORT_DIR"
    EXPORT_PRESET="iOS Debug"
    EXPORT_MODE="--export-debug"
    if [[ "$BUILD_TYPE_LOWER" == "release" ]]; then
        EXPORT_PRESET="iOS Release"
        EXPORT_MODE="--export-release"
    fi
    if [[ "$SIMULATOR" == true ]]; then
        EXPORT_PRESET="iOS Simulator Debug"
        [[ "$SIMULATOR_ARCH" == x86_64 ]] && EXPORT_PRESET="iOS Simulator x64 Debug"
    fi
    with_ios_only_gdextension
    if [[ "$SIMULATOR" == true ]]; then
        verify_exported_simulator_template_arch "$IOS_EXPORT_DIR" "$SIMULATOR_ARCH"
    elif renpy_device_gles_enabled; then
        verify_exported_renpy_device_template "$IOS_EXPORT_DIR"
    fi
    stage_renios_ios_resources "$IOS_EXPORT_DIR"
    stage_force_load_plugin_archives "$IOS_EXPORT_DIR/Aether/bin/$GODOT_TRIPLET_DIR"
    cp -f "$GODOT_BIN_DIR/$IOS_SDK_COMPAT_ARCHIVE" "$IOS_EXPORT_DIR/Aether/bin/$GODOT_TRIPLET_DIR/"
    PATCH_ARCH="arm64"
    if [[ "$SIMULATOR" == true ]]; then
        PATCH_ARCH="$SIMULATOR_ARCH"
    fi
    patch_ios_export_project "$IOS_EXPORT_DIR/Aether.xcodeproj" "$PATCH_ARCH" "$BUILD_TYPE_LOWER"
    if [[ "$PACKAGE_IPA" == true && "$SIMULATOR" == false ]]; then
        package_ios_unsigned_ipa "$IOS_EXPORT_DIR" "$BUILD_TYPE_LOWER"
    elif [[ "$SIMULATOR" == true ]]; then
        package_ios_simulator_app "$IOS_EXPORT_DIR"
    fi
fi

echo "iOS build output: $IOS_EXPORT_DIR"
