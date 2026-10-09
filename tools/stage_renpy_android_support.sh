#!/usr/bin/env bash
# Stage a rebuilt Ren'Py RAPT runtime into a Godot Android export.
#
# RAPT is an SDLActivity application template. It must not be merged as the
# exported app's manifest or launched as a second Activity: Godot owns the
# process, window, and SDL lifecycle. This script therefore packages the
# official Java/resources as inspectable assets, stages the selected native
# payload in jniLibs, and installs the host-owned JNI bridge. Enabled app
# builds require a lifecycle library and complete cooperative Python payload.
# --allow-unsupported is an explicit archive inspection mode, never gameplay.
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: tools/stage_renpy_android_support.sh --mobile-root PATH --godot-build PATH

Stage the pinned official RAPT Android support package into an existing Godot
Android build template. The RAPT PythonSDLActivity is stored under APK assets
and is never added to the manifest, so this command cannot create a second
Activity. An optional game-specific private/assets directory can be supplied
with --private-assets.

Options:
  --mobile-root PATH       Root containing rapt/prototype/renpyandroid
  --godot-build PATH       Extracted Godot Android build template directory
  --abis LIST              Comma-separated arm64-v8a,x86_64 (default: arm64-v8a)
  --private-assets PATH    Unpacked runtime directory (main.py, renpy/, lib/)
  --allow-unsupported     Inspect an official archive without a lifecycle fork;
                           this mode is never used by enabled app builds
  -h, --help               Show this help
USAGE
}

mobile_root=""
godot_build=""
private_assets=""
abis="arm64-v8a"
allow_unsupported=false
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

while (($#)); do
    case "$1" in
        --mobile-root)
            (($# >= 2)) || { echo "--mobile-root requires a value" >&2; exit 2; }
            mobile_root="$2"
            shift 2
            ;;
        --godot-build)
            (($# >= 2)) || { echo "--godot-build requires a value" >&2; exit 2; }
            godot_build="$2"
            shift 2
            ;;
        --private-assets)
            (($# >= 2)) || { echo "--private-assets requires a value" >&2; exit 2; }
            private_assets="$2"
            shift 2
            ;;
        --abis)
            (($# >= 2)) || { echo "--abis requires a value" >&2; exit 2; }
            abis="$2"
            shift 2
            ;;
        --allow-unsupported)
            allow_unsupported=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ -z "$mobile_root" || -z "$godot_build" ]]; then
    echo "--mobile-root and --godot-build are required" >&2
    usage >&2
    exit 2
fi

rapt_root="$mobile_root/rapt"
rapt_main="$rapt_root/prototype/renpyandroid/src/main"
IFS=',' read -r -a abi_list <<< "$abis"
[[ -n "$abis" && "$abis" != *, && "$abis" != ,* ]] || {
    echo "--abis must contain arm64-v8a and/or x86_64" >&2
    exit 2
}
for abi in "${abi_list[@]}"; do
    case "$abi" in
        arm64-v8a|x86_64) ;;
        *) echo "Unsupported Ren'Py Android packaging ABI: $abi" >&2; exit 2 ;;
    esac
done

[[ -d "$rapt_main" ]] || {
    echo "RAPT Android module is missing: $rapt_main" >&2
    exit 1
}
[[ -d "$godot_build" ]] || {
    echo "Godot Android build template is missing: $godot_build" >&2
    exit 1
}
[[ -f "$godot_build/build.gradle" ]] || {
    echo "Godot Android Gradle application template is missing: $godot_build/build.gradle" >&2
    exit 1
}
if [[ -n "$private_assets" && ! -e "$private_assets" ]]; then
    echo "private assets path is missing: $private_assets" >&2
    exit 1
fi

is_elf_file() {
    local path="$1"
    [[ -f "$path" ]] || return 1
    [[ "$(dd if="$path" bs=4 count=1 2>/dev/null | LC_ALL=C od -An -tx1 | tr -d ' \\n')" == "7f454c46" ]]
}

if [[ "$allow_unsupported" == false ]]; then
    if [[ -z "$private_assets" ]]; then
        private_assets="$rapt_root/runtime/private"
    fi
    python3 "$repo_root/tools/validate_renpy_mobile_payload.py" \
        --platform android --private-root "$private_assets"
fi
for abi in "${abi_list[@]}"; do
    rapt_native="$rapt_main/jniLibs/$abi/librenpython.so"
    [[ -f "$rapt_native" ]] || {
        echo "RAPT $abi native library is missing: $rapt_native" >&2
        exit 1
    }
    is_elf_file "$rapt_native" || {
        echo "RAPT $abi native library is not an ELF file: $rapt_native" >&2
        exit 1
    }
    if [[ "$allow_unsupported" == false ]]; then
        python3 "$repo_root/tools/validate_renpy_mobile_payload.py" \
            --platform android --abi "$abi" --library "$rapt_native"
    fi
done

main_src="$godot_build/src/main"
# Godot recursively clears src/main/assets before every Gradle export. Keep
# the native Python payload in a separate Android asset source directory;
# Gradle merges it into the APK as real AssetManager files, outside game PCKs.
asset_root="$godot_build/renpy_assets/renpy_mobile"
asset_rapt="$asset_root/rapt"
asset_private="$asset_root/private"
private_archive="$asset_rapt/private.mp3"
jni_root="$main_src/jniLibs"
java_root="$main_src/java/org/github/krkr2/aetherkiri"
java_sdl_root="$main_src/java/org/libsdl/app"
java_renpy_root="$main_src/java/org/renpy/android"

mkdir -p "$asset_rapt" "$asset_private" "$jni_root" "$java_root"
cat > "$godot_build/aether-renpy.gradle" <<'GRADLE'
// Aether's persistent Ren'Py assets survive Godot's exported-game cleanup.
// Keep Godot's normal asset source set and merge these raw files into it.
android.sourceSets.main.assets.srcDir(file('renpy_assets'))
GRADLE
if ! grep -Fxq "apply from: 'aether-renpy.gradle'" "$godot_build/build.gradle"; then
    printf "\napply from: 'aether-renpy.gradle'\n" >> "$godot_build/build.gradle"
fi

# This source is part of AetherKiri, not an official RAPT Activity. It binds
# the existing Godot Activity to engine_api without creating a second owner.
cp -f "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bridge/renpy_runtime/android/RenPyMobileBridge.java" \
    "$java_root/RenPyMobileBridge.java"

# Compile only the host-owned callback signatures. The official RAPT Java
# sources remain assets and its PythonSDLActivity manifest is never merged;
# compiling the full Activity would create a second SDL singleton. Refuse to
# overwrite an unrelated class if a Godot template starts shipping one.
install_host_shim() {
    local source="$1" destination="$2" marker="$3"
    mkdir -p "$(dirname "$destination")"
    if [[ -f "$destination" ]] && ! grep -Fq "$marker" "$destination"; then
        echo "Refusing to overwrite unrelated Android Java class: $destination" >&2
        exit 1
    fi
    cp -f "$source" "$destination"
    # Vendored SDL helper classes may not contain our marker in the upstream
    # source. Mark the staged copy so another build can safely update it.
    printf '\n// %s: staged host-owned callback source.\n' "$marker" >> "$destination"
}
while IFS= read -r -d '' shim; do
    relative="${shim#"$repo_root/bridge/renpy_runtime/android/"}"
    case "$relative" in
        org/libsdl/*) marker='renpy-sdl-host-shim-v1' ;;
        org/renpy/*) marker='renpy-python-host-shim-v1' ;;
        *) continue ;;
    esac
    install_host_shim "$shim" "$main_src/java/$relative" "$marker"
done < <(find "$repo_root/bridge/renpy_runtime/android/org" -type f -name '*.java' -print0)

# The source tree is deliberately copied below assets rather than src/main/java
# or src/main/res. RAPT's manifest names PythonSDLActivity as its launcher;
# merging it into Godot would create a second Activity and two SDL owners.
rm -rf "$asset_rapt/java" "$asset_rapt/res" "$asset_rapt/templates"
mkdir -p "$asset_rapt/java" "$asset_rapt/res"
cp -a "$rapt_main/java/." "$asset_rapt/java/"
if [[ -d "$rapt_main/res" ]]; then
    cp -a "$rapt_main/res/." "$asset_rapt/res/"
fi
# Keep Kotlin templates too if a future official RAPT package adds them. The
# current 8.5.3 package is Java-only, but the asset boundary is language
# neutral and does not risk compiling a second Activity.
if find "$rapt_main" -type f -name '*.kt' -print -quit | grep -q .; then
    mkdir -p "$asset_rapt/kotlin"
    while IFS= read -r -d '' kotlin_file; do
        relative="${kotlin_file#"$rapt_main/"}"
        mkdir -p "$asset_rapt/kotlin/$(dirname "$relative")"
        cp -f "$kotlin_file" "$asset_rapt/kotlin/$relative"
    done < <(find "$rapt_main" -type f -name '*.kt' -print0)
fi
if [[ -f "$rapt_main/AndroidManifest.xml" ]]; then
    cp -f "$rapt_main/AndroidManifest.xml" "$asset_rapt/AndroidManifest.xml"
fi
if [[ -f "$rapt_root/prototype/renpyandroid/build.gradle" ]]; then
    cp -f "$rapt_root/prototype/renpyandroid/build.gradle" "$asset_rapt/build.gradle"
fi
if [[ -d "$rapt_root/templates" ]]; then
    cp -a "$rapt_root/templates" "$asset_rapt/templates"
fi

# Keep any official RAPT app assets and any optional game-specific private
# payload visible to the eventual extractor. RAPT does not ship a game
# private.mp3 in its support archive, so emit a deterministic marker instead
# of pretending that the provider can launch a game without one.
if [[ -d "$rapt_root/prototype/app/src/main/assets" ]]; then
    rm -rf "$asset_rapt/app-assets"
    mkdir -p "$asset_rapt/app-assets"
    cp -a "$rapt_root/prototype/app/src/main/assets/." "$asset_rapt/app-assets/"
fi
find "$asset_private" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
rm -f "$private_archive"
if [[ -d "$rapt_main/private" ]]; then
    cp -a "$rapt_main/private/." "$asset_private/"
fi
if [[ -d "$private_assets" ]]; then
    cp -a "$private_assets/." "$asset_private/"
elif [[ -n "$private_assets" ]]; then
    cp -f "$private_assets" "$asset_private/$(basename "$private_assets")"
fi
if [[ -f "$asset_private/private.mp3" ]]; then
    # PythonSDLActivity's ResourceManager looks up private.mp3 at the asset
    # root. Keep the auditable private/ copy too, but expose this canonical
    # RAPT filename for the future host-owned extractor.
    cp -f "$asset_private/private.mp3" "$private_archive"
fi
if [[ -z "$(find "$asset_private" -mindepth 1 -print -quit)" ]]; then
    cat > "$asset_private/README.txt" <<'PRIVATE_EOF'
This directory is reserved for the Ren'Py game's RAPT private payload.
The official RAPT support archive does not contain game-specific private.mp3
data. Supply --private-assets when staging a built Ren'Py game. AetherKiri
keeps runtime=renpy NOT_SUPPORTED until extraction, lifecycle, input, and
rendering are wired to the existing Godot Activity.
PRIVATE_EOF
fi

# Clear only files registered by a previous Ren'Py staging run. This keeps
# other Godot template libraries intact when switching emulator/device ABIs.
previous_manifest="$asset_root/manifest.properties"
if [[ -f "$previous_manifest" ]]; then
    previous_files="$(sed -n 's/^staged_native_files=//p' "$previous_manifest")"
    if [[ -z "$previous_files" ]]; then
        previous_files="$(sed -n 's/^native_library=lib\///p' "$previous_manifest")"
    fi
    IFS=',' read -r -a previous_file_list <<< "$previous_files"
    for previous_file in "${previous_file_list[@]}"; do
        [[ "$previous_file" != *..* ]] || continue
        case "$previous_file" in
            arm64-v8a/lib*.so|x86_64/lib*.so)
                rm -f "$jni_root/$previous_file"
                ;;
        esac
    done
fi
native_paths=()
staged_native_files=()
for abi in "${abi_list[@]}"; do
    mkdir -p "$jni_root/$abi"
    native_paths+=("lib/$abi/librenpython.so")
    for native_library in "$rapt_main/jniLibs/$abi/"*.so; do
        [[ -f "$native_library" ]] || continue
        native_file="$abi/$(basename "$native_library")"
        cp -f "$native_library" "$jni_root/$native_file"
        chmod 755 "$jni_root/$native_file"
        staged_native_files+=("$native_file")
    done
done

# Retain the compiled Ren'Py dependency bytes in the APK. AGP otherwise strips
# them again, obscuring which validated native input the app actually shipped.
# This does not change the host libraries' normal release stripping policy.
{
    printf '\nandroid.packagingOptions.jniLibs.keepDebugSymbols += [\n'
    for native_file in "${staged_native_files[@]}"; do
        printf "    'lib/%s',\n" "$native_file"
    done
    printf ']\n'
} >> "$godot_build/aether-renpy.gradle"

# Record the exact staged paths and the archive metadata when available. This
# is consumed by package smoke tests and makes an APK inspection auditable.
rapt_checksum=""
if [[ -f "$rapt_root/.aetherkiri-sha256" ]]; then
    rapt_checksum="$(awk 'NR == 1 { print $1; exit }' "$rapt_root/.aetherkiri-sha256")"
elif [[ -f "$rapt_root/hash.txt" ]]; then
    rapt_checksum="$(tr -d '[:space:]' < "$rapt_root/hash.txt")"
fi
{
    printf 'renpy_version=8.5.3\n'
    printf 'runtime_sdl=SDL2\n'
    printf 'rapt_checksum=%s\n' "$rapt_checksum"
    printf 'playable=unverified\n'
    printf 'inspection_only=%s\n' "$allow_unsupported"
    printf 'native_lifecycle_validated=%s\n' "$( [[ "$allow_unsupported" == false ]] && printf true || printf false )"
    printf 'activity_template=assets/renpy_mobile/rapt/java/org/renpy/android/PythonSDLActivity.java\n'
    printf 'gradle_template=assets/renpy_mobile/rapt/build.gradle\n'
    printf 'native_abis=%s\n' "$abis"
    printf 'native_library=%s\n' "$(IFS=','; printf '%s' "${native_paths[*]}")"
    printf 'staged_native_files=%s\n' "$(IFS=','; printf '%s' "${staged_native_files[*]}")"
    printf 'private_assets=assets/renpy_mobile/private\n'
    printf 'gradle_asset_source=renpy_assets\n'
    printf 'private_archive=%s\n' "$( [[ -f "$private_archive" ]] && printf 'assets/renpy_mobile/rapt/private.mp3' || true )"
    printf 'manifest_merged=false\n'
    printf 'java_host_shims=org/libsdl/app/SDLActivity.java,org/renpy/android/PythonSDLActivity.java\n'
} > "$asset_root/manifest.properties"

echo "Ren'Py Android support staged into $godot_build"
echo "  official Java/resources: $asset_rapt"
echo "  private assets:          $asset_private"
echo "  native library ABIs:     $abis"
echo "  gameplay:                unverified (requires device execution)"
